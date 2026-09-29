import { useState } from "react"
import { ScreenHeader } from "../PhoneFrame"
import Icon, { type IconName } from "../ui/Icon"
import { Button, StatusChip, StickyBar, SyncBadge } from "../ui/primitives"
import type { Nav } from "./types"
import type { OutboxCommandKind, QueuedOperation } from "../../lib/syncEngine"

const kindIcon: Record<OutboxCommandKind, IconName> = {
  transfer_line_capture: "receive",
  sales_line_capture: "dispatch",
  sales_backorder: "alert",
  count_observation: "clipboard",
  count_variance_reason: "clipboard",
  count_decision: "shield",
  transfer_ship: "dispatch",
  transfer_receive: "receive",
  sales_dispatch: "dispatch",
  count_finalize: "clipboard",
  transfer_exception_disposition: "shield",
  unknown_scan_report: "alert",
}

export default function SyncCenter({ nav }: { nav: Nav }) {
  const [selected, setSelected] = useState<QueuedOperation | null>(null)
  const { syncing, online, syncOps } = nav
  const active = syncOps.filter((operation) => !["confirmed", "cancelled"].includes(operation.state))
  const pending = active.length
  const attention = active.filter((operation) => ["failed", "conflict", "blocked"].includes(operation.state)).length
  const fullySynced = online && !syncing && pending === 0
  const freshness = nav.lastConfirmedAt
    ? `Last confirmed ${new Date(nav.lastConfirmedAt).toLocaleString([], { hour: "2-digit", minute: "2-digit", month: "short", day: "numeric" })}`
    : "No server confirmation recorded yet"

  if (selected) {
    return <OperationDetail nav={nav} operation={selected} onBack={() => setSelected(null)} />
  }

  return (
    <div className="fo-screen flex min-h-full flex-col pb-2">
      <ScreenHeader title="Sync Center" subtitle="Durable command outbox" onBack={() => nav.go("home")} />
      <div className="space-y-4 px-5">
        {!nav.storageAvailable && <div className="rounded-2xl border border-danger/25 bg-danger-soft p-4"><p className="text-[14px] font-bold text-danger">Durable storage unavailable</p><p className="mt-1 text-[13px] text-ink-soft">{nav.storageError ?? "FieldOne cannot prove that offline work is durable. New sync processing is paused until storage recovers."}</p></div>}
        <div className={`flex items-center gap-3.5 rounded-2xl border p-4 ${!online ? "border-warning/25 bg-warning-soft" : attention > 0 ? "border-danger/20 bg-danger-soft" : syncing || pending > 0 ? "border-brand/20 bg-brand-soft" : "border-success/20 bg-success-soft"}`}>
          <span className={`grid h-11 w-11 shrink-0 place-items-center rounded-xl text-white ${!online ? "bg-warning" : attention > 0 ? "bg-danger" : syncing || pending > 0 ? "bg-brand" : "bg-success"}`}>
            <Icon name={!online ? "cloud-off" : attention > 0 ? "alert" : syncing || pending > 0 ? "refresh" : "cloud-sync"} className={`h-6 w-6 ${syncing ? "fo-spin" : ""}`} strokeWidth={2} />
          </span>
          <div className="min-w-0 flex-1">
            <p className="text-[15px] font-bold text-ink">{!online ? "Working offline" : attention > 0 ? "Attention needed" : syncing ? "Syncing commands…" : fullySynced ? "All commands confirmed" : `${pending} command${pending === 1 ? "" : "s"} pending`}</p>
            <p className="mt-0.5 text-[13px] text-ink-soft">{!online ? `${pending} durable command${pending === 1 ? "" : "s"} preserved on this device` : attention > 0 ? `${attention} blocked/failed/conflicted · ${freshness}` : freshness}</p>
          </div>
        </div>

        <div className="flex flex-wrap gap-1.5">
          <StatusChip tone="brand">Queued / Syncing</StatusChip>
          <StatusChip tone="success">Confirmed</StatusChip>
          <StatusChip tone="danger">Failed / Blocked</StatusChip>
          <StatusChip tone="warning">Conflict</StatusChip>
        </div>

        <ul className="space-y-2.5">
          {syncOps.length === 0 && <li className="rounded-2xl border border-dashed border-hairline bg-white p-8 text-center text-[13px] text-ink-faint">No durable commands for this user/company/warehouse.</li>}
          {syncOps.map((operation) => {
            const actionable = ["failed", "conflict", "blocked"].includes(operation.state)
            return <li key={operation.id}>
              <button onClick={() => actionable ? setSelected(operation) : undefined} className={`flex w-full items-center gap-3 rounded-2xl border bg-white px-3.5 py-3 text-left ${actionable ? "border-danger/20 hover:border-danger/40" : "border-hairline"}`}>
                <span className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-[#f5f6f8] text-ink-soft"><Icon name={kindIcon[operation.kind]} className="h-5 w-5" strokeWidth={2} /></span>
                <span className="min-w-0 flex-1"><span className="block truncate text-[14px] font-semibold text-ink">{operation.label} {operation.ref}</span><span className="block text-[13px] text-ink-faint">{operation.attemptCount} attempt{operation.attemptCount === 1 ? "" : "s"} · created {new Date(operation.createdAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</span>{operation.lastError && <span className="mt-0.5 block truncate text-[12px] text-danger">{operation.lastError.message}</span>}</span>
                <span className="flex shrink-0 items-center gap-1.5"><SyncBadge state={operation.state} />{actionable && <Icon name="chevron-right" className="h-4 w-4 text-ink-faint" />}</span>
              </button>
            </li>
          })}
        </ul>

        <p className="px-1 text-[13px] text-ink-faint">Commands are record-per-command, owner scoped and preserved through reload/crash. Conflict and permanent validation states never participate in ordinary automatic retry.</p>
        <button onClick={() => nav.go("history")} className="flex w-full items-center justify-center gap-2 rounded-2xl border border-hairline bg-white py-3 text-[14px] font-semibold text-ink-soft"><Icon name="history" className="h-4.5 w-4.5" />View transaction history</button>
      </div>
      <StickyBar><Button icon="refresh" onClick={nav.runSync}>{syncing ? "Syncing…" : online ? pending > 0 ? "Process pending commands" : "Refresh sync state" : "Will sync when online"}</Button></StickyBar>
    </div>
  )
}

function OperationDetail({ nav, operation, onBack }: { nav: Nav; operation: QueuedOperation; onBack: () => void }) {
  const [busy, setBusy] = useState(false)
  const conflict = operation.state === "conflict"
  const failed = operation.state === "failed"
  return <div className="fo-screen flex min-h-full flex-col pb-2">
    <ScreenHeader title={conflict ? "Conflict blocked" : operation.state === "blocked" ? "Command blocked" : "Retryable failure"} subtitle={`${operation.label} ${operation.ref}`} onBack={onBack} />
    <div className="space-y-4 px-5">
      <div className={`rounded-2xl border p-4 ${conflict ? "border-warning/25 bg-warning-soft" : "border-danger/20 bg-danger-soft"}`}><p className="text-[14px] font-bold">{operation.lastError?.message ?? "No structured error message was recorded."}</p><p className="mt-1 text-[13px] text-ink-soft">Type: {operation.lastError?.kind ?? "unknown"} · Code: {operation.lastError?.code ?? "n/a"}</p></div>
      <div className="rounded-2xl border border-hairline bg-white p-4 text-[13px]"><div className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-2"><b>Stable command</b><span className="break-all">{operation.id}</span><b>State</b><span>{operation.state}</span><b>Attempts</b><span>{operation.attemptCount}</span><b>Recorded</b><span>{new Date(operation.clientRecordedAt).toLocaleString()}</span><b>Dependencies</b><span>{operation.dependencyIds.length ? operation.dependencyIds.length : "None"}</span></div></div>
      {conflict && <div className="rounded-xl border border-hairline bg-white p-3 text-[13px] text-ink-soft"><Icon name="shield" className="mr-2 inline h-4 w-4 text-brand" />The server state is not fabricated here. Accepting server state preserves this command as cancelled audit history. Keeping local work creates a new stable successor command against the latest authoritative document revision; server validation still decides whether it can execute.</div>}
    </div>
    <StickyBar><div className="space-y-2">{failed && <Button onClick={async()=>{setBusy(true);try{await nav.retryOperation(operation.id);onBack()}finally{setBusy(false)}}}>{busy?"Retrying…":"Retry with same stable command"}</Button>}{conflict && <Button onClick={async()=>{setBusy(true);try{await nav.acceptServerVersion(operation.id);onBack()}finally{setBusy(false)}}}>{busy?"Applying…":"Accept server state"}</Button>}{conflict && <Button variant="secondary" onClick={async()=>{setBusy(true);try{await nav.rebaseConflictOperation(operation.id);onBack()}finally{setBusy(false)}}}>{busy?"Rebasing…":"Keep my work as new revision"}</Button>}<Button variant="secondary" onClick={onBack}>Back</Button></div></StickyBar>
  </div>
}
