import { useState } from "react"
import { ScreenHeader } from "../PhoneFrame"
import Icon, { type IconName } from "../ui/Icon"
import { StatusChip, SyncBadge } from "../ui/primitives"
import { useItems, useLocationMovements } from "../../lib/queries"
import { useOperationalContext } from "../../lib/auth"
import { useSyncEngine } from "../../lib/useSyncEngine"
import { itemUuidToSlug, itemById as dataItemById, type Transaction, type TxnKind } from "./models"
import type { Nav } from "./types"

type FilterId = "all" | TxnKind

const filters: { id: FilterId; label: string }[] = [
  { id: "all", label: "All" },
  { id: "receive", label: "Receipts" },
  { id: "dispatch", label: "Dispatches" },
  { id: "count", label: "Counts" },
  { id: "adjust", label: "Adjustments" },
]

const kind: Record<TxnKind, { icon: IconName; label: string }> = {
  receive: { icon: "receive", label: "Receipt" },
  dispatch: { icon: "dispatch", label: "Dispatch" },
  count: { icon: "clipboard", label: "Cycle count" },
  adjust: { icon: "layers", label: "Adjustment" },
}

export default function TransactionHistory({ nav }: { nav: Nav }) {
  const [filter, setFilter] = useState<FilterId>("all")
  const [openId, setOpenId] = useState<string | null>(null)
  
  const { data: itemsFromQuery = [] } = useItems()
  const items = itemsFromQuery
  const itemById = (id: string) => dataItemById(id, items)

  const { user, activeCompanyId, activeLocationId } = useOperationalContext()
  const { queue } = useSyncEngine(user?.id && activeCompanyId && activeLocationId ? { authUserId: user.id, companyId: activeCompanyId, locationId: activeLocationId } : { authUserId: '', companyId: '', locationId: '' })
  const { data: movements = [] } = useLocationMovements()

  // Map movements to Transactions
  const dbTransactions: Transaction[] = movements.map(m => {
    let kind: TxnKind = "adjust"
    if (m.type.toLowerCase().includes("receive")) kind = "receive"
    if (m.type.toLowerCase().includes("dispatch") || m.type.toLowerCase().includes("ship")) kind = "dispatch"
    if (m.type.toLowerCase().includes("count")) kind = "count"
    return {
      id: m.id,
      kind,
      ref: m.ref,
      itemId: m.productId,
      qty: m.qty,
      user: "System", // Or user name if available
      when: m.when,
      sync: "confirmed",
    }
  })

  // Map outbox queue to Transactions
  const outboxTransactions: Transaction[] = queue.map(q => {
    let kind: TxnKind = "adjust"
    let itemId = ""
    let qty = "0"
    if (q.kind === "transfer_receive") {
      kind = "receive"
      itemId = (q.payload as any)?.productId as string || ""
    }
    if (q.kind === "sales_dispatch" || q.kind === "transfer_ship") {
      kind = "dispatch"
      itemId = (q.payload as any)?.productId as string || ""
    }
    if (q.kind === "count_observation" || q.kind === "count_finalize") {
      kind = "count"
      itemId = (q.payload as any)?.productId as string || ""
    }
    if (q.kind === "transfer_line_capture" || q.kind === "sales_line_capture") {
      kind = q.kind.startsWith("transfer") ? "receive" : "dispatch"
      itemId = (q.payload as any)?.productId as string || "" // We may not have product in line capture easily
    }
    return {
      id: q.id,
      kind,
      ref: q.label,
      itemId,
      qty,
      user: "You",
      when: new Date(q.clientRecordedAt).toLocaleString(),
      sync: q.state,
    }
  })

  const allTransactions = [...outboxTransactions, ...dbTransactions]

  if (openId) return <TxnDetail id={openId} nav={nav} transactions={allTransactions} onBack={() => setOpenId(null)} />

  const list = allTransactions.filter((t) => filter === "all" || t.kind === filter)

  return (
    <div className="fo-screen flex min-h-full flex-col pb-6">
      <ScreenHeader title="Transaction History" subtitle="Audit trail for this location" onBack={() => nav.go("home")} />

      <div className="no-scrollbar -mx-0 mb-3 overflow-x-auto px-5">
        <div className="flex gap-2">
          {filters.map((f) => {
            const on = f.id === filter
            return (
              <button
                key={f.id}
                onClick={() => setFilter(f.id)}
                className={`shrink-0 rounded-full border px-3.5 py-1.5 text-[13px] font-semibold transition-all ${
                  on ? "border-brand bg-brand text-white" : "border-hairline bg-white text-ink-soft hover:border-brand/30"
                }`}
              >
                {f.label}
              </button>
            )
          })}
        </div>
      </div>

      <ul className="space-y-2.5 px-5">
        {list.map((t) => {
          const it = itemById(t.itemId)
          const k = kind[t.kind]
          const neg = t.qty.startsWith("−")
          return (
            <li key={t.id}>
              <button
                onClick={() => setOpenId(t.id)}
                className="flex w-full items-center gap-3 rounded-2xl border border-hairline bg-white px-3.5 py-3 text-left transition-all hover:border-brand/30"
              >
                <span className="grid h-10 w-10 shrink-0 place-items-center rounded-xl bg-[#f5f6f8] text-ink-soft">
                  <Icon name={k.icon} className="h-5 w-5" strokeWidth={2} />
                </span>
                <span className="min-w-0 flex-1">
                  <span className="flex items-center gap-2">
                    <span className="truncate text-[14px] font-semibold text-ink">
                      {k.label} {t.ref}
                    </span>
                  </span>
                  <span className="block truncate text-[13px] text-ink-faint">
                    {it.sku} · {t.user} · {t.when}
                  </span>
                  <span className="mt-1.5 block">
                    <SyncBadge state={t.sync} />
                  </span>
                </span>
                {t.qty !== "0" && (
                  <span className={`shrink-0 text-[14px] font-bold ${neg ? "text-danger" : "text-success"}`}>
                    {t.qty}
                    <span className="text-[13px] font-medium text-ink-faint"> {it.unit}</span>
                  </span>
                )}
              </button>
            </li>
          )
        })}
      </ul>
    </div>
  )
}

function TxnDetail({ id, nav, onBack, transactions }: { id: string; nav: Nav; onBack: () => void; transactions: Transaction[] }) {
  const t: Transaction | undefined = transactions.find(txn => txn.id === id)
  const { data: itemsFromQuery = [] } = useItems()
  const items = itemsFromQuery
  const itemById = (itemId: string) => dataItemById(itemId, items)
  if (!t) return null
  const it = itemById(t.itemId)
  const k = kind[t.kind] || kind.adjust
  const neg = t.qty.startsWith("−") || t.qty.startsWith("-")

  return (
    <div className="fo-screen flex min-h-full flex-col pb-6">
      <ScreenHeader title={`${k.label} ${t.ref}`} subtitle={t.when} onBack={onBack} />

      <div className="space-y-4 px-5">
        {/* movement summary */}
        <div className="rounded-2xl border border-hairline bg-white p-4">
          <div className="flex items-center justify-between">
            <span className="flex items-center gap-2 text-[14px] font-bold text-ink">
              <span className="grid h-9 w-9 place-items-center rounded-xl bg-brand-soft text-brand">
                <Icon name={k.icon} className="h-5 w-5" strokeWidth={2} />
              </span>
              {k.label}
            </span>
            <SyncBadge state={t.sync} />
          </div>
          {t.from && (
            <div className="mt-3 flex items-center gap-2 border-t border-hairline pt-3 text-[13px]">
              <span className="min-w-0 flex-1 truncate font-semibold text-ink-soft">{t.from}</span>
              {t.to && <Icon name="arrow-right" className="h-4 w-4 shrink-0 text-brand" strokeWidth={2.2} />}
              {t.to && <span className="min-w-0 flex-1 truncate text-right font-semibold text-ink">{t.to}</span>}
            </div>
          )}
        </div>

        {/* affected item */}
        <button
          onClick={() => nav.openItem(t.itemId)}
          className="flex w-full items-center gap-3 rounded-2xl border border-hairline bg-white px-3.5 py-3 text-left transition-all hover:border-brand/30"
        >
          <div className="h-12 w-12 shrink-0 overflow-hidden rounded-xl border border-hairline bg-[#f5f6f8]">
            <img src={it.img} alt={it.name} className="h-full w-full object-cover" />
          </div>
          <div className="min-w-0 flex-1">
            <p className="truncate text-[14px] font-semibold text-ink">{it.name}</p>
            <p className="text-[13px] text-ink-faint">{it.sku} · UOM {it.unit}</p>
          </div>
          {t.qty !== "0" ? (
            <span className={`text-[16px] font-extrabold ${neg ? "text-danger" : "text-success"}`}>{t.qty}</span>
          ) : (
            <StatusChip tone="neutral">No change</StatusChip>
          )}
        </button>

        {/* meta rows */}
        <dl className="divide-y divide-hairline overflow-hidden rounded-2xl border border-hairline bg-white">
          <Row label="Reference" value={t.ref} />
          <Row label="Type" value={k.label} />
          <Row label="Performed by" value={t.user} />
          <Row label="Timestamp" value={t.when} />
          <Row label="Movement" value={t.qty === "0" ? "No stock change" : `${t.qty} ${it.unit}`} />
        </dl>

        {/* sync status callout */}
        <div className="flex items-start gap-2.5 rounded-2xl border border-hairline bg-white px-3.5 py-3">
          <Icon name="shield" className="mt-0.5 h-4.5 w-4.5 shrink-0 text-brand" strokeWidth={2} />
          <p className="text-[13px] text-ink-soft">
            {t.sync === "confirmed"
              ? "Confirmed by the server and written to the ledger."
              : t.sync === "local"
                ? "Saved on this device. Not yet sent to the server."
                : t.sync === "queued"
                  ? "Queued — waiting to sync to the server."
                  : t.sync === "syncing"
                    ? "Syncing now. Awaiting server confirmation."
                    : t.sync === "failed"
                      ? "Sync failed — this movement has not been applied. Retry from Sync Center."
                      : "Conflict with a server update. Resolve in Sync Center."}
          </p>
        </div>

        {(t.sync === "failed" || t.sync === "conflict") && (
          <button
            onClick={() => nav.go("sync")}
            className="flex w-full items-center justify-center gap-2 rounded-2xl border border-danger/25 bg-danger-soft py-3 text-[14px] font-semibold text-danger"
          >
            <Icon name="alert" className="h-4.5 w-4.5" strokeWidth={2.2} />
            Resolve in Sync Center
          </button>
        )}
      </div>
    </div>
  )
}

function Row({ label, value }: { label: string; value?: string }) {
  if (!value) return null
  return (
    <div className="flex items-center justify-between px-3.5 py-3">
      <dt className="text-[13px] text-ink-faint">{label}</dt>
      <dd className="text-[14px] font-semibold text-ink">{value}</dd>
    </div>
  )
}
