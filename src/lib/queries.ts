import { useQuery } from '@tanstack/react-query'
import { supabase } from './supabase'
import { useOperationalContext } from './auth'
import { loadSnapshot, saveSnapshot, type OfflineOwner, type PersistedSnapshot } from './offlineStore'
import { probeBackendReachability } from './reachability'
import { findItemById, itemSlugToUuid, itemUuidToSlug, type Item } from '../components/inventory/models'

type PositionRow = {
  company_id: string
  location_id: string
  product_id: string
  product_name: string
  sku: string
  base_unit_id: string
  base_unit_name: string
  base_unit_code: string
  quantity_scale: number
  quantity_step: number | string
  physical_on_hand_base_qty: number | string
  available_physical_base_qty: number | string
  damaged_base_qty: number | string
  blocked_base_qty: number | string
  reserved_base_qty: number | string
  available_to_promise_base_qty: number | string
  in_transit_inbound_base_qty: number | string
  physical_revision: number | string
  reservation_revision: number | string
}


function ownerFromContext(userId: string | null, companyId: string | null, locationId: string | null): OfflineOwner | null {
  if (!userId || !companyId || !locationId) return null
  return { authUserId: userId, companyId, locationId }
}

async function inventorySnapshotFallback<T>(
  owner: OfflineOwner | null,
  kind: Extract<PersistedSnapshot["kind"], "inventory-items" | "inventory-item" | "item-bins" | "item-movements">,
  key: string,
  loadRemote: () => Promise<T>,
): Promise<T> {
  if (owner && !(await probeBackendReachability())) {
    const cached = await loadSnapshot<T>(owner, kind, key)
    if (cached) return cached.value
    throw new Error(`FieldOne backend is unreachable and no ${kind} snapshot is available`)
  }
  try {
    const value = await loadRemote()
    if (owner) await saveSnapshot({ schemaVersion: 1, owner, kind, key, capturedAt: new Date().toISOString(), value })
    return value
  } catch (error) {
    if (owner) {
      const cached = await loadSnapshot<T>(owner, kind, key)
      if (cached) return cached.value
    }
    throw error
  }
}

const CATALOG_PAGE_SIZE = 500
const IDENTIFIER_BATCH_SIZE = 200

async function fetchAllLocationPositions(companyId: string, locationId: string): Promise<PositionRow[]> {
  const rows: PositionRow[] = []
  for (let from = 0; ; from += CATALOG_PAGE_SIZE) {
    const result = await supabase
      .from('inventory_location_positions')
      .select(
        'company_id, location_id, product_id, product_name, sku, base_unit_id, base_unit_name, base_unit_code, quantity_scale, quantity_step, physical_on_hand_base_qty, available_physical_base_qty, damaged_base_qty, blocked_base_qty, reserved_base_qty, available_to_promise_base_qty, in_transit_inbound_base_qty, physical_revision, reservation_revision',
      )
      .eq('company_id', companyId)
      .eq('location_id', locationId)
      .order('product_name')
      .order('product_id')
      .range(from, from + CATALOG_PAGE_SIZE - 1)
    if (result.error) throw result.error
    const page = (result.data ?? []) as PositionRow[]
    rows.push(...page)
    if (page.length < CATALOG_PAGE_SIZE) break
  }
  return rows
}

async function fetchPrimaryBarcodes(companyId: string, productIds: string[]) {
  const barcodeByProduct = new Map<string, string>()
  for (let start = 0; start < productIds.length; start += IDENTIFIER_BATCH_SIZE) {
    const ids = productIds.slice(start, start + IDENTIFIER_BATCH_SIZE)
    const result = await supabase
      .from('product_identifiers')
      .select('product_id, identifier_value, identifier_type')
      .eq('company_id', companyId)
      .eq('is_active', true)
      .in('product_id', ids)
      .in('identifier_type', ['BARCODE', 'GTIN'])
      .order('created_at')
    if (result.error) throw result.error
    for (const identifier of result.data ?? []) {
      if (!barcodeByProduct.has(identifier.product_id)) barcodeByProduct.set(identifier.product_id, identifier.identifier_value)
    }
  }
  return barcodeByProduct
}

const GENERIC_PRODUCT_IMAGE = '/product-placeholder.svg'

function decimal(value: number | string | null | undefined): number {
  const parsed = typeof value === 'number' ? value : Number(value ?? 0)
  if (!Number.isFinite(parsed)) throw new Error(`Invalid inventory numeric value: ${String(value)}`)
  return parsed
}

function mapPosition(row: PositionRow, barcode = ""): Item {
  const slug = itemUuidToSlug[row.product_id] || row.sku.toLowerCase().replace(/\./g, '-')
  const fixture = findItemById(row.product_id, []) ?? findItemById(row.sku, [])
  return {
    id: slug,
    name: row.product_name,
    sku: row.sku,
    barcode,
    img: fixture?.img ?? GENERIC_PRODUCT_IMAGE,
    unit: row.base_unit_code,
    baseUnitId: row.base_unit_id,
    quantityScale: Number(row.quantity_scale ?? 0),
    quantityStep: decimal(row.quantity_step ?? 1),
    onHand: decimal(row.physical_on_hand_base_qty),
    available: decimal(row.available_to_promise_base_qty),
    reserved: decimal(row.reserved_base_qty),
    inTransit: decimal(row.in_transit_inbound_base_qty),
    damaged: decimal(row.damaged_base_qty),
    blocked: decimal(row.blocked_base_qty),
  }
}

export function useItems() {
  const { user, activeCompanyId, activeLocationId } = useOperationalContext()
  const owner = ownerFromContext(user?.id ?? null, activeCompanyId, activeLocationId)

  return useQuery({
    queryKey: ['items', activeCompanyId, activeLocationId],
    enabled: Boolean(activeCompanyId && activeLocationId),
    queryFn: async () => {
      if (!activeCompanyId || !activeLocationId) return [] as Item[]
      return inventorySnapshotFallback(owner, 'inventory-items', `${activeCompanyId}:${activeLocationId}`, async () => {
        const rows = await fetchAllLocationPositions(activeCompanyId, activeLocationId)
        const barcodeByProduct = await fetchPrimaryBarcodes(activeCompanyId, rows.map((row) => row.product_id))
        return rows.map((row) => mapPosition(row, barcodeByProduct.get(row.product_id) ?? ''))
      })
    },
    staleTime: 1000 * 30,
  })
}

export function useItem(id: string) {
  const { user, activeCompanyId, activeLocationId } = useOperationalContext()
  const owner = ownerFromContext(user?.id ?? null, activeCompanyId, activeLocationId)

  return useQuery({
    queryKey: ['item', activeCompanyId, activeLocationId, id],
    enabled: Boolean(activeCompanyId && activeLocationId && id),
    queryFn: async () => {
      if (!activeCompanyId || !activeLocationId) return null
      return inventorySnapshotFallback(owner, 'inventory-item', id, async () => {
      const targetUuid = itemSlugToUuid[id] || null
      let query = supabase
        .from('inventory_location_positions')
        .select(
          'company_id, location_id, product_id, product_name, sku, base_unit_id, base_unit_name, base_unit_code, quantity_scale, quantity_step, physical_on_hand_base_qty, available_physical_base_qty, damaged_base_qty, blocked_base_qty, reserved_base_qty, available_to_promise_base_qty, in_transit_inbound_base_qty, physical_revision, reservation_revision',
        )
        .eq('company_id', activeCompanyId)
        .eq('location_id', activeLocationId)

      query = targetUuid ? query.eq('product_id', targetUuid) : query.ilike('sku', id)
      const result = await query.maybeSingle()
      if (result.error) throw result.error
      if (!result.data) return null
      const row = result.data as PositionRow
      const identifiers = await supabase.from('product_identifiers').select('identifier_value, identifier_type').eq('company_id', activeCompanyId).eq('product_id', row.product_id).eq('is_active', true).in('identifier_type', ['BARCODE','GTIN']).limit(1)
      if (identifiers.error) throw identifiers.error
      return mapPosition(row, identifiers.data?.[0]?.identifier_value ?? '')
      })
    },
    staleTime: 1000 * 30,
  })
}

type BinPositionRow = {
  bin_id: string
  bin_code: string
  product_id: string
  physical_on_hand_base_qty: number | string
  available_to_promise_base_qty: number | string
  reserved_base_qty: number | string
  damaged_base_qty: number | string
  blocked_base_qty: number | string
  in_transit_inbound_base_qty: number | string
}

export type LiveBinPosition = {
  binId: string
  binCode: string
  onHand: number
  available: number
  reserved: number
  damaged: number
  blocked: number
  inTransit: number
}

export function useItemBins(productIdOrSlug: string) {
  const { user, activeCompanyId, activeLocationId } = useOperationalContext()
  const owner = ownerFromContext(user?.id ?? null, activeCompanyId, activeLocationId)
  const targetUuid = itemSlugToUuid[productIdOrSlug] || productIdOrSlug
  return useQuery({
    queryKey: ['item-bins', activeCompanyId, activeLocationId, targetUuid],
    enabled: Boolean(activeCompanyId && activeLocationId && targetUuid),
    queryFn: async () => {
      if (!activeCompanyId || !activeLocationId) return [] as LiveBinPosition[]
      return inventorySnapshotFallback(owner, 'item-bins', targetUuid, async () => {
      const result = await supabase
        .from('inventory_bin_positions')
        .select('bin_id, bin_code, product_id, physical_on_hand_base_qty, available_to_promise_base_qty, reserved_base_qty, damaged_base_qty, blocked_base_qty, in_transit_inbound_base_qty')
        .eq('company_id', activeCompanyId)
        .eq('location_id', activeLocationId)
        .eq('product_id', targetUuid)
        .order('bin_code')
      if (result.error) throw result.error
      return ((result.data ?? []) as BinPositionRow[]).map((row) => ({
        binId: row.bin_id,
        binCode: row.bin_code,
        onHand: decimal(row.physical_on_hand_base_qty),
        available: decimal(row.available_to_promise_base_qty),
        reserved: decimal(row.reserved_base_qty),
        damaged: decimal(row.damaged_base_qty),
        blocked: decimal(row.blocked_base_qty),
        inTransit: decimal(row.in_transit_inbound_base_qty),
      }))
      })
    },
    staleTime: 1000 * 30,
  })
}

type MovementRow = {
  id: string
  movement_type: string
  source_location_id: string | null
  destination_location_id: string | null
  source_inventory_status: string | null
  destination_inventory_status: string | null
  base_quantity: number | string
  reference_number: string | null
  posted_at: string
}

export type LiveMovement = {
  id: string
  type: string
  ref: string
  qty: string
  when: string
  inbound: boolean
  sync: "confirmed"
}

function movementLabel(type: string) {
  return type
    .toLowerCase()
    .split('_')
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ')
}

export function useItemMovements(productIdOrSlug: string) {
  const { user, activeCompanyId, activeLocationId } = useOperationalContext()
  const owner = ownerFromContext(user?.id ?? null, activeCompanyId, activeLocationId)
  const targetUuid = itemSlugToUuid[productIdOrSlug] || productIdOrSlug
  return useQuery({
    queryKey: ['item-movements', activeCompanyId, activeLocationId, targetUuid],
    enabled: Boolean(activeCompanyId && activeLocationId && targetUuid),
    queryFn: async () => {
      if (!activeCompanyId || !activeLocationId) return [] as LiveMovement[]
      return inventorySnapshotFallback(owner, 'item-movements', targetUuid, async () => {
      const result = await supabase
        .from('inventory_movements')
        .select('id, movement_type, source_location_id, destination_location_id, source_inventory_status, destination_inventory_status, base_quantity, reference_number, posted_at')
        .eq('company_id', activeCompanyId)
        .eq('product_id', targetUuid)
        .or(`source_location_id.eq.${activeLocationId},destination_location_id.eq.${activeLocationId}`)
        .order('posted_at', { ascending: false })
        .limit(20)
      if (result.error) throw result.error
      return ((result.data ?? []) as MovementRow[]).map((row) => {
        const inbound = row.destination_location_id === activeLocationId && row.source_location_id !== activeLocationId
        const outbound = row.source_location_id === activeLocationId && row.destination_location_id !== activeLocationId
        const prefix = inbound ? '+' : outbound ? '-' : '±'
        return {
          id: row.id,
          type: movementLabel(row.movement_type),
          ref: row.reference_number ?? 'Inventory movement',
          qty: `${prefix}${decimal(row.base_quantity)}`,
          when: new Date(row.posted_at).toLocaleString(),
          inbound,
          sync: "confirmed" as const,
        }
      })
      })
    },
    staleTime: 1000 * 15,
  })
}

export function useLocationMovements() {
  const { user, activeCompanyId, activeLocationId } = useOperationalContext()
  const owner = ownerFromContext(user?.id ?? null, activeCompanyId, activeLocationId)
  return useQuery({
    queryKey: ['location-movements', activeCompanyId, activeLocationId],
    enabled: Boolean(activeCompanyId && activeLocationId),
    queryFn: async () => {
      if (!activeCompanyId || !activeLocationId) return []
      return inventorySnapshotFallback(owner, 'item-movements', 'ALL', async () => {
        const result = await supabase
          .from('inventory_movements')
          .select('id, movement_type, source_location_id, destination_location_id, source_inventory_status, destination_inventory_status, base_quantity, reference_number, posted_at, product_id')
          .eq('company_id', activeCompanyId)
          .or(`source_location_id.eq.${activeLocationId},destination_location_id.eq.${activeLocationId}`)
          .order('posted_at', { ascending: false })
          .limit(50)
        if (result.error) throw result.error
        return ((result.data ?? []) as (MovementRow & { product_id: string })[]).map((row) => {
          const inbound = row.destination_location_id === activeLocationId && row.source_location_id !== activeLocationId
          const outbound = row.source_location_id === activeLocationId && row.destination_location_id !== activeLocationId
          const prefix = inbound ? '+' : outbound ? '-' : '±'
          return {
            id: row.id,
            productId: row.product_id,
            type: movementLabel(row.movement_type),
            ref: row.reference_number ?? 'Inventory movement',
            qty: `${prefix}${decimal(row.base_quantity)}`,
            when: new Date(row.posted_at).toLocaleString(),
            inbound,
            sync: "confirmed" as const,
          }
        })
      })
    },
    staleTime: 1000 * 15,
  })
}

