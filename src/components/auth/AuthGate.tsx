import { useMemo, useState, type FormEvent, type ReactNode } from "react"
import { useOperationalContext } from "../../lib/auth"

import PhoneFrame from "../PhoneFrame"

function CenteredCard({ children, mesh = false }: { children: ReactNode, mesh?: boolean }) {
  return (
    <div className={`flex min-h-full h-full items-center justify-center p-4 text-ink ${mesh ? 'bg-gradient-mesh' : 'bg-canvas'}`}>
      <div className={`w-full max-w-sm rounded-3xl border border-white/40 p-6 shadow-2xl ${mesh ? 'glass' : 'bg-white'}`}>
        {children}
      </div>
    </div>
  )
}

function SignIn() {
  const { signIn } = useOperationalContext()
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    setSubmitting(true)
    setError(null)
    try {
      await signIn(email.trim(), password)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Unable to sign in")
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <main className="flex min-h-screen items-center justify-center p-3 sm:p-6 bg-canvas">
      <PhoneFrame>
        <CenteredCard mesh>
          <div className="flex items-center gap-2 mb-3">
            <span className="grid h-8 w-8 place-items-center rounded-xl bg-gradient-brand text-white shadow-lg">
              <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4" />
              </svg>
            </span>
            <p className="text-[12px] font-bold uppercase tracking-[0.15em] text-brand">FieldOne</p>
          </div>
          
          <h1 className="mt-1 text-[26px] font-extrabold tracking-tight leading-tight">Welcome back</h1>
          <p className="mt-1 text-[13px] leading-relaxed text-ink-soft">
            Sign in to access your secure warehouse operations context.
          </p>
          
          <form onSubmit={submit} className="mt-6 space-y-4">
            <label className="block">
              <span className="text-[12px] font-bold text-ink-soft">Email address</span>
              <input
                autoComplete="email"
                type="email"
                required
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                className="mt-1.5 w-full rounded-2xl border border-white/60 bg-white/50 px-3.5 py-3 text-[14px] font-medium text-ink outline-none transition-all focus:border-brand focus:bg-white focus:ring-4 focus:ring-brand/10"
                placeholder="you@example.com"
              />
            </label>
            <label className="block">
              <span className="text-[12px] font-bold text-ink-soft">Password</span>
              <input
                autoComplete="current-password"
                type="password"
                required
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                className="mt-1.5 w-full rounded-2xl border border-white/60 bg-white/50 px-3.5 py-3 text-[14px] font-medium text-ink outline-none transition-all focus:border-brand focus:bg-white focus:ring-4 focus:ring-brand/10"
                placeholder="••••••••"
              />
            </label>
            {error && <p className="animate-float rounded-xl bg-danger-soft/80 backdrop-blur px-3 py-2 text-[13px] font-semibold text-danger border border-danger/20">{error}</p>}
            <button
              type="submit"
              disabled={submitting}
              className="mt-2 flex w-full items-center justify-center rounded-2xl bg-gradient-brand px-4 py-3.5 text-[14px] font-bold text-white shadow-[0_8px_20px_-8px_rgba(67,56,202,0.6)] transition-all hover:opacity-90 active:scale-[0.98] disabled:opacity-50"
            >
              {submitting ? "Authenticating..." : "Sign in securely"}
            </button>
          </form>
        </CenteredCard>
      </PhoneFrame>
    </main>
  )
}

function AccessProblem({ message }: { message: string }) {
  const { user, signOut, refreshContext, contextLoading } = useOperationalContext()
  return (
    <main className="flex min-h-screen items-center justify-center p-3 sm:p-6 bg-canvas">
      <PhoneFrame>
        <CenteredCard>
          <p className="text-[12px] font-bold uppercase tracking-[0.12em] text-warning">Access not provisioned</p>
          <h1 className="mt-1 text-[22px] font-extrabold">Warehouse access required</h1>
          <p className="mt-2 text-[13px] leading-6 text-ink-soft">{message}</p>
          {user && (
            <div className="mt-4 rounded-xl bg-[#f6f7fb] px-3.5 py-3 text-[12px] text-ink-soft">
              <p>{user.email ?? "Authenticated user"}</p>
              <p className="mt-1 break-all font-mono text-[11px] text-ink-faint">{user.id}</p>
            </div>
          )}
          <div className="mt-5 flex gap-2">
            <button
              type="button"
              onClick={() => void refreshContext()}
              disabled={contextLoading}
              className="flex-1 rounded-xl border border-hairline px-3 py-2 text-[12px] font-bold text-ink"
            >
              Refresh access
            </button>
            <button
              type="button"
              onClick={() => void signOut()}
              className="flex-1 rounded-xl bg-[#0c1033] px-3 py-2 text-[12px] font-bold text-white"
            >
              Sign out
            </button>
          </div>
        </CenteredCard>
      </PhoneFrame>
    </main>
  )
}

function OperationalContextControls() {
  const {
    profile,
    companies,
    warehouses,
    activeCompanyId,
    activeLocationId,
    activeWarehouse,
    setActiveCompanyId,
    setActiveLocationId,
    signOut,
  } = useOperationalContext()

  const locationOptions = useMemo(
    () => warehouses.filter((warehouse) => warehouse.companyId === activeCompanyId),
    [activeCompanyId, warehouses],
  )

  return (
    <details className="fixed right-3 top-3 z-50">
      <summary className="cursor-pointer list-none rounded-full border border-hairline bg-white/95 px-3 py-2 text-[11px] font-extrabold text-ink shadow-lg backdrop-blur">
        {activeWarehouse?.code || "Access"} · Access
      </summary>
      <div className="mt-2 w-[min(19rem,calc(100vw-1.5rem))] space-y-3 rounded-2xl border border-hairline bg-white/95 p-3 shadow-xl backdrop-blur">
        <div className="min-w-0">
          <p className="truncate text-[13px] font-bold text-ink">{profile?.fullName || "FieldOne user"}</p>
          <p className="text-[11px] text-ink-faint">Authenticated operational context</p>
        </div>
        <label className="block text-[11px] font-bold text-ink-soft">
          Company
          <select
            aria-label="Active company"
            value={activeCompanyId ?? ""}
            onChange={(event) => setActiveCompanyId(event.target.value)}
            className="mt-1 w-full rounded-lg border border-hairline bg-white px-2.5 py-2 text-[12px] font-semibold text-ink"
          >
            {companies.map((company) => (
              <option value={company.id} key={company.id}>
                {company.name}
              </option>
            ))}
          </select>
        </label>
        <label className="block text-[11px] font-bold text-ink-soft">
          Warehouse
          <select
            aria-label="Active warehouse"
            value={activeLocationId ?? ""}
            onChange={(event) => setActiveLocationId(event.target.value)}
            className="mt-1 w-full rounded-lg border border-hairline bg-white px-2.5 py-2 text-[12px] font-semibold text-ink"
          >
            {locationOptions.map((warehouse) => (
              <option value={warehouse.id} key={warehouse.id}>
                {warehouse.code} · {warehouse.name}
              </option>
            ))}
          </select>
        </label>
        <button
          type="button"
          onClick={() => void signOut()}
          className="w-full rounded-lg bg-[#0c1033] px-3 py-2 text-[12px] font-bold text-white"
        >
          Sign out
        </button>
      </div>
    </details>
  )
}

export default function AuthGate({ children }: { children: ReactNode }) {
  const {
    loading,
    contextLoading,
    session,
    profile,
    companies,
    activeCompanyId,
    activeLocationId,
    contextError,
  } = useOperationalContext()

  if (loading || (session && contextLoading)) {
    return (
      <main className="flex min-h-screen items-center justify-center p-3 sm:p-6 bg-canvas">
        <PhoneFrame>
          <CenteredCard>
            <p className="text-[14px] font-semibold text-ink-soft text-center">Loading authenticated warehouse access...</p>
          </CenteredCard>
        </PhoneFrame>
      </main>
    )
  }

  if (!session) return <SignIn />

  if (contextError) {
    return <AccessProblem message={`FieldOne could not load your operational access: ${contextError}`} />
  }

  if (!profile) {
    return (
      <AccessProblem message="Your Supabase account is authenticated, but it is not yet bound to an operational FieldOne profile. An administrator must set profiles.auth_user_id to this authenticated user and assign company/warehouse memberships." />
    )
  }

  if (companies.length === 0 || !activeCompanyId) {
    return <AccessProblem message="Your profile has no active company membership." />
  }

  if (!activeLocationId) {
    return <AccessProblem message="Your profile has no active warehouse membership for the selected company." />
  }

  return (
    <>
      <OperationalContextControls />
      {children}
    </>
  )
}
