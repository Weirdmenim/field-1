import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react"
import type { Session, User } from "@supabase/supabase-js"
import { useQueryClient } from "@tanstack/react-query"
import { supabase } from "./supabase"
import { clearOperationalContextSnapshot, loadOperationalContextSnapshot, saveOperationalContextSnapshot } from "./offlineStore"
import { probeBackendReachability } from "./reachability"

export type InventoryPermission =
  | "inventory.read"
  | "inventory.receive"
  | "inventory.dispatch"
  | "inventory.count"
  | "inventory.count.approve"
  | "inventory.adjust"
  | "inventory.reverse"

export type OperationalProfile = {
  id: string
  authUserId: string
  fullName: string
}

export type CompanyAccess = {
  id: string
  name: string
  role: string
}

export type WarehouseAccess = {
  id: string
  companyId: string
  name: string
  code: string
  locationType: string
  isActive: boolean
  allowDirectSales: boolean
  permissions: Record<InventoryPermission, boolean>
}

type OperationalContextPayload = {
  profile: OperationalProfile | null
  companies: CompanyAccess[]
  warehouses: WarehouseAccess[]
}

type AuthContextValue = {
  loading: boolean
  contextLoading: boolean
  session: Session | null
  user: User | null
  profile: OperationalProfile | null
  companies: CompanyAccess[]
  warehouses: WarehouseAccess[]
  activeCompanyId: string | null
  activeLocationId: string | null
  activeCompany: CompanyAccess | null
  activeWarehouse: WarehouseAccess | null
  contextError: string | null
  signIn: (email: string, password: string) => Promise<void>
  signOut: () => Promise<void>
  refreshContext: () => Promise<void>
  setActiveCompanyId: (companyId: string) => void
  setActiveLocationId: (locationId: string) => void
  can: (permission: InventoryPermission) => boolean
}

const AuthContext = createContext<AuthContextValue | null>(null)

const permissionKeys: InventoryPermission[] = [
  "inventory.read",
  "inventory.receive",
  "inventory.dispatch",
  "inventory.count",
  "inventory.count.approve",
  "inventory.adjust",
  "inventory.reverse",
]

function asRecord(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null ? (value as Record<string, unknown>) : null
}

function stringField(record: Record<string, unknown>, key: string): string {
  return typeof record[key] === "string" ? (record[key] as string) : ""
}

function booleanField(record: Record<string, unknown>, key: string): boolean {
  return record[key] === true
}

function parseOperationalContext(value: unknown): OperationalContextPayload {
  const root = asRecord(value)
  if (!root) return { profile: null, companies: [], warehouses: [] }

  let profile: OperationalProfile | null = null
  const profileRecord = asRecord(root.profile)
  if (profileRecord) {
    const id = stringField(profileRecord, "id")
    const authUserId = stringField(profileRecord, "auth_user_id")
    const fullName = stringField(profileRecord, "full_name")
    if (id && authUserId) profile = { id, authUserId, fullName }
  }

  const companies = Array.isArray(root.companies)
    ? root.companies.flatMap((entry): CompanyAccess[] => {
        const record = asRecord(entry)
        if (!record) return []
        const id = stringField(record, "id")
        if (!id) return []
        return [{ id, name: stringField(record, "name"), role: stringField(record, "role") }]
      })
    : []

  const warehouses = Array.isArray(root.warehouses)
    ? root.warehouses.flatMap((entry): WarehouseAccess[] => {
        const record = asRecord(entry)
        if (!record) return []
        const id = stringField(record, "id")
        const companyId = stringField(record, "company_id")
        if (!id || !companyId) return []
        const permissionRecord = asRecord(record.permissions) ?? {}
        const permissions = Object.fromEntries(
          permissionKeys.map((permission) => [permission, booleanField(permissionRecord, permission)]),
        ) as Record<InventoryPermission, boolean>
        return [
          {
            id,
            companyId,
            name: stringField(record, "name"),
            code: stringField(record, "code"),
            locationType: stringField(record, "location_type"),
            isActive: booleanField(record, "is_active"),
            allowDirectSales: booleanField(record, "allow_direct_sales"),
            permissions,
          },
        ]
      })
    : []

  return { profile, companies, warehouses }
}

function selectionStorageKey(userId: string) {
  return `fieldone:operational-context:${userId}`
}

function readStoredSelection(userId: string): { companyId?: string; locationId?: string } {
  try {
    const raw = localStorage.getItem(selectionStorageKey(userId))
    if (!raw) return {}
    const parsed = JSON.parse(raw) as { companyId?: unknown; locationId?: unknown }
    return {
      companyId: typeof parsed.companyId === "string" ? parsed.companyId : undefined,
      locationId: typeof parsed.locationId === "string" ? parsed.locationId : undefined,
    }
  } catch {
    return {}
  }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const queryClient = useQueryClient()
  const contextRequestId = useRef(0)
  const [loading, setLoading] = useState(true)
  const [contextLoading, setContextLoading] = useState(false)
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<OperationalProfile | null>(null)
  const [companies, setCompanies] = useState<CompanyAccess[]>([])
  const [warehouses, setWarehouses] = useState<WarehouseAccess[]>([])
  const [activeCompanyId, setActiveCompanyState] = useState<string | null>(null)
  const [activeLocationId, setActiveLocationState] = useState<string | null>(null)
  const [contextError, setContextError] = useState<string | null>(null)

  const clearTenantQueries = useCallback(() => {
    queryClient.removeQueries({
      predicate: (query) => ["items", "item", "item-bins", "item-movements", "warehouse-work", "transfer-document", "sales-order-document", "count-session-document"].includes(String(query.queryKey[0])),
    })
  }, [queryClient])

  const clearOperationalContext = useCallback(() => {
    // Invalidate any in-flight operational-context request. Without this guard,
    // a slow response from the previous user/company could repopulate state
    // after sign-out or a rapid account switch.
    contextRequestId.current += 1
    setProfile(null)
    setCompanies([])
    setWarehouses([])
    setActiveCompanyState(null)
    setActiveLocationState(null)
    setContextError(null)
    clearTenantQueries()
  }, [clearTenantQueries])

  const loadOperationalContext = useCallback(
    async (nextSession: Session | null) => {
      if (!nextSession?.user) {
        clearOperationalContext()
        return
      }

      const requestId = contextRequestId.current + 1
      contextRequestId.current = requestId
      setContextLoading(true)
      setContextError(null)
      try {
        if (!(await probeBackendReachability())) throw new Error("FieldOne backend is unreachable")
        const { data, error } = await supabase.rpc("get_my_operational_context")
        if (error) throw error
        if (requestId !== contextRequestId.current) return

        const parsed = parseOperationalContext(data)
        if (!parsed.profile || parsed.profile.authUserId !== nextSession.user.id) throw new Error("Operational context does not match authenticated user")
        await saveOperationalContextSnapshot(nextSession.user.id, parsed)
        setProfile(parsed.profile)
        setCompanies(parsed.companies)
        setWarehouses(parsed.warehouses)

        const stored = readStoredSelection(nextSession.user.id)
        const selectedCompany = parsed.companies.some((company) => company.id === stored.companyId)
          ? stored.companyId!
          : parsed.companies[0]?.id ?? null
        const companyWarehouses = parsed.warehouses.filter((warehouse) => warehouse.companyId === selectedCompany)
        const selectedLocation = companyWarehouses.some((warehouse) => warehouse.id === stored.locationId)
          ? stored.locationId!
          : companyWarehouses[0]?.id ?? null

        setActiveCompanyState(selectedCompany)
        setActiveLocationState(selectedLocation)
        clearTenantQueries()
      } catch (error) {
        if (requestId !== contextRequestId.current) return
        try {
          const cached = await loadOperationalContextSnapshot<OperationalContextPayload>(nextSession.user.id)
          if (cached?.value.profile?.authUserId === nextSession.user.id) {
            const parsed = cached.value
            setProfile(parsed.profile)
            setCompanies(parsed.companies)
            setWarehouses(parsed.warehouses)
            const stored = readStoredSelection(nextSession.user.id)
            const selectedCompany = parsed.companies.some((company) => company.id === stored.companyId) ? stored.companyId! : parsed.companies[0]?.id ?? null
            const companyWarehouses = parsed.warehouses.filter((warehouse) => warehouse.companyId === selectedCompany)
            const selectedLocation = companyWarehouses.some((warehouse) => warehouse.id === stored.locationId) ? stored.locationId! : companyWarehouses[0]?.id ?? null
            setActiveCompanyState(selectedCompany)
            setActiveLocationState(selectedLocation)
            setContextError(null)
            clearTenantQueries()
            return
          }
        } catch {
          // If durable context storage is also unavailable, fail closed below.
        }
        clearOperationalContext()
        setContextError(error instanceof Error ? error.message : "Unable to load operational access")
      } finally {
        if (requestId === contextRequestId.current) setContextLoading(false)
      }
    },
    [clearOperationalContext, clearTenantQueries],
  )

  useEffect(() => {
    let mounted = true
    supabase.auth.getSession().then(({ data }) => {
      if (!mounted) return
      setSession(data.session)
      setLoading(false)
      void loadOperationalContext(data.session)
    })

    const { data: subscription } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      setSession(nextSession)
      setLoading(false)
      // Defer Supabase RPC work until after the auth callback returns; this avoids
      // re-entering the client while its auth-state lock is being updated.
      setTimeout(() => {
        if (mounted) void loadOperationalContext(nextSession)
      }, 0)
    })

    return () => {
      mounted = false
      subscription.subscription.unsubscribe()
    }
  }, [loadOperationalContext])

  useEffect(() => {
    if (!session?.user || !activeCompanyId) return
    localStorage.setItem(
      selectionStorageKey(session.user.id),
      JSON.stringify({ companyId: activeCompanyId, locationId: activeLocationId }),
    )
  }, [session?.user, activeCompanyId, activeLocationId])

  const signIn = useCallback(async (email: string, password: string) => {
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    if (error) throw error
  }, [])

  const signOut = useCallback(async () => {
    const userId = session?.user.id
    if (userId) {
      localStorage.removeItem(selectionStorageKey(userId))
      await clearOperationalContextSnapshot(userId)
    }
    clearOperationalContext()
    await queryClient.cancelQueries()
    queryClient.clear()
    const { error } = await supabase.auth.signOut()
    if (error) throw error
  }, [clearOperationalContext, queryClient, session?.user.id])

  const refreshContext = useCallback(async () => {
    await loadOperationalContext(session)
  }, [loadOperationalContext, session])

  const setActiveCompanyId = useCallback(
    (companyId: string) => {
      if (!companies.some((company) => company.id === companyId)) return
      const firstWarehouse = warehouses.find((warehouse) => warehouse.companyId === companyId) ?? null
      clearTenantQueries()
      setActiveCompanyState(companyId)
      setActiveLocationState(firstWarehouse?.id ?? null)
    },
    [clearTenantQueries, companies, warehouses],
  )

  const setActiveLocationId = useCallback(
    (locationId: string) => {
      const warehouse = warehouses.find(
        (candidate) => candidate.id === locationId && candidate.companyId === activeCompanyId,
      )
      if (!warehouse) return
      clearTenantQueries()
      setActiveLocationState(locationId)
    },
    [activeCompanyId, clearTenantQueries, warehouses],
  )

  const activeCompany = useMemo(
    () => companies.find((company) => company.id === activeCompanyId) ?? null,
    [activeCompanyId, companies],
  )
  const activeWarehouse = useMemo(
    () => warehouses.find((warehouse) => warehouse.id === activeLocationId) ?? null,
    [activeLocationId, warehouses],
  )
  const can = useCallback(
    (permission: InventoryPermission) => activeWarehouse?.permissions[permission] === true,
    [activeWarehouse],
  )

  const value = useMemo<AuthContextValue>(
    () => ({
      loading,
      contextLoading,
      session,
      user: session?.user ?? null,
      profile,
      companies,
      warehouses,
      activeCompanyId,
      activeLocationId,
      activeCompany,
      activeWarehouse,
      contextError,
      signIn,
      signOut,
      refreshContext,
      setActiveCompanyId,
      setActiveLocationId,
      can,
    }),
    [
      activeCompany,
      activeCompanyId,
      activeLocationId,
      activeWarehouse,
      can,
      companies,
      contextError,
      contextLoading,
      loading,
      profile,
      refreshContext,
      session,
      setActiveCompanyId,
      setActiveLocationId,
      signIn,
      signOut,
      warehouses,
    ],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useOperationalContext() {
  const context = useContext(AuthContext)
  if (!context) throw new Error("useOperationalContext must be used inside AuthProvider")
  return context
}
