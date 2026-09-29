import Icon from "../ui/Icon"
import { ConnState, SectionHeader, StatusChip, TaskRow } from "../ui/primitives"
import type { Nav } from "./types"
import { useLocationMovements, useItems } from "../../lib/queries"
import { useOperationalContext } from "../../lib/auth"
import { useSyncEngine } from "../../lib/useSyncEngine"
import { itemById as dataItemById } from "./models"

export default function InventoryHome({ nav }: { nav: Nav }) {
  const { user, activeCompanyId, activeLocationId } = useOperationalContext()
  const { queue } = useSyncEngine(user?.id && activeCompanyId && activeLocationId ? { authUserId: user.id, companyId: activeCompanyId, locationId: activeLocationId } : { authUserId: '', companyId: '', locationId: '' })
  const { data: movements = [] } = useLocationMovements()
  const { data: items = [] } = useItems()
  const itemById = (id: string) => dataItemById(id, items)
  const isComplete = (task: (typeof nav.workItems)[number]) => task.total > 0 && task.done >= task.total
  const allowedTask = (task: (typeof nav.workItems)[number]) =>
    task.kind === "receive"
      ? nav.can("inventory.receive")
      : task.kind === "dispatch"
        ? nav.can("inventory.dispatch")
        : nav.can("inventory.count")
  const today = nav.workItems.filter((t) => allowedTask(t) && t.group === "today")
  const attention = nav.workItems.filter((t) => allowedTask(t) && t.group === "attention" && !isComplete(t))
  const pending = nav.syncOps.filter((o) => !["confirmed", "cancelled"].includes(o.state)).length
  const freshness = nav.lastConfirmedAt
    ? `Last confirmed ${new Date(nav.lastConfirmedAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`
    : "Never synced"

  return (
    <div className="fo-screen space-y-6 pb-6">
      {/* top bar — module context */}
      <div className="flex items-center justify-between px-5 pt-2">
        <button className="grid h-9 w-9 place-items-center rounded-full text-ink transition-colors hover:bg-[#f5f6f8]">
          <Icon name="menu" className="h-5 w-5" strokeWidth={2} />
        </button>
        <div className="flex items-center gap-1.5">
          <span className="grid h-6 w-6 place-items-center rounded-md bg-brand text-white">
            <Icon name="box" className="h-3.5 w-3.5" strokeWidth={2.2} />
          </span>
          <span className="text-[15px] font-extrabold tracking-[-0.02em] text-ink">Inventory</span>
        </div>
        <div className="h-9 w-9 overflow-hidden rounded-full border border-hairline bg-[#f5f6f8]">
          <span className="grid h-full w-full place-items-center text-[12px] font-extrabold text-brand">{nav.actorName.slice(0, 2).toUpperCase()}</span>
        </div>
      </div>

      {/* greeting + role */}
      <div className="px-5">
        <h1 className="text-[24px] font-extrabold leading-tight tracking-[-0.02em] text-ink">
          What&apos;s next, {nav.actorName.split(" " )[0] || "there"}?
        </h1>
        <p className="mt-0.5 flex items-center gap-1.5 text-[13px] font-medium text-ink-faint">
          <Icon name="shield" className="h-3.5 w-3.5 text-brand" strokeWidth={2} />
          {nav.role}
        </p>
      </div>

      {/* location + connection */}
      <div className="mx-5 rounded-2xl border border-hairline bg-white p-1.5">
        <div className="flex items-center gap-3 px-2.5 py-2">
          <span className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-brand-soft text-brand">
            <Icon name="location" className="h-4.5 w-4.5" strokeWidth={2} />
          </span>
          <div className="min-w-0 flex-1">
            <p className="truncate text-[14px] font-semibold text-ink">{nav.locationName}</p>
            <p className="text-[13px] text-ink-faint">{nav.locationCode} · authorized warehouse</p>
          </div>
          <Icon name="chevron-down" className="h-4.5 w-4.5 text-ink-faint" strokeWidth={2} />
        </div>
        <div className="border-t border-hairline pt-1">
          <ConnState
            online={nav.online}
            detail={
              nav.online
                ? pending > 0
                  ? `${freshness} · ${pending} pending`
                  : `${freshness} · all confirmed`
                : `Offline · ${freshness} · ${pending} pending`
            }
          />
        </div>
      </div>

      {/* prominent scan */}
      <div className="px-5">
        <button
          onClick={() => nav.openScan("browse")}
          className="group flex w-full items-center gap-5 rounded-[1.5rem] bg-gradient-brand p-5 text-left text-white shadow-[0_16px_32px_-12px_rgba(67,56,202,0.6)] transition-all duration-300 hover:shadow-[0_20px_40px_-12px_rgba(67,56,202,0.7)] hover:scale-[1.01] active:scale-[0.98]"
        >
          <span className="grid h-14 w-14 shrink-0 place-items-center rounded-2xl bg-white/20 shadow-inner backdrop-blur-md transition-transform group-hover:scale-110">
            <Icon name="scan" className="h-7 w-7" strokeWidth={2.2} />
          </span>
          <span className="flex-1">
            <span className="block text-[17px] font-extrabold tracking-tight">Scan to find an item</span>
            <span className="mt-0.5 block text-[14px] font-medium text-white/80">Look up stock, locations and movements</span>
          </span>
          <Icon name="chevron-right" className="h-6 w-6 text-white/70 transition-transform group-hover:translate-x-1" strokeWidth={2.5} />
        </button>
      </div>

      {/* exceptions */}
      {attention.length > 0 && (
        <div className="space-y-3">
          <SectionHeader title="Requires attention" action="Work" onAction={() => nav.go("work")} />
          <div className="space-y-2.5 px-5">
            {attention.map((t) => (
              <TaskRow key={t.id} task={t} progress={nav.progressFor(t)} onClick={() => nav.openTask(t.id)} />
            ))}
          </div>
        </div>
      )}

      {/* assigned work today */}
      <div className="space-y-3">
        <SectionHeader title="Assigned today" action="See all" onAction={() => nav.go("work")} />
        <div className="space-y-2.5 px-5">
          {today.map((t) => (
            <TaskRow key={t.id} task={t} progress={nav.progressFor(t)} onClick={() => nav.openTask(t.id)} />
          ))}
        </div>
      </div>

      {/* recent activity — quiet */}
      <div className="space-y-3">
        <SectionHeader title="Recent activity" action="History" onAction={() => nav.go("history")} />
        <ul className="mx-5 space-y-1">
          {movements.slice(0, 3).map((m) => {
            const it = itemById(m.productId)
            return (
              <li key={m.id} className="flex items-center gap-3 px-1 py-2">
                <span
                  className={`h-2 w-2 shrink-0 rounded-full ${
                    m.qty.startsWith("+") ? "bg-success" : m.qty.startsWith("-") ? "bg-danger" : "bg-warning"
                  }`}
                />
                <span className="min-w-0 flex-1 truncate text-[13px] font-medium text-ink-soft">
                  {m.type} {m.qty} {it.unit} · {it.sku}
                </span>
                <span className="shrink-0 text-[13px] text-ink-faint">{m.ref} · {m.when.split(", ")[1] || m.when}</span>
              </li>
            )
          })}
          {movements.length === 0 && (
            <li className="px-1 py-2 text-[13px] text-ink-faint">No recent activity.</li>
          )}
        </ul>
      </div>

      <div className="px-5">
        <StatusChip tone="neutral">Role-based view · {nav.role}</StatusChip>
      </div>
    </div>
  )
}
