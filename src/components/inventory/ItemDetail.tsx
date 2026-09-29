import { ScreenHeader } from "../PhoneFrame"
import Icon from "../ui/Icon"
import { Button, SectionHeader, StatusChip, SyncBadge } from "../ui/primitives"
import type { Nav } from "./types"
import { useItem, useItemBins, useItemMovements } from "../../lib/queries"

export default function ItemDetail({ nav, itemId }: { nav: Nav; itemId: string }) {
  const { data: item, isLoading, isError, error } = useItem(itemId)
  const { data: binPositions = [] } = useItemBins(itemId)
  const { data: moves = [] } = useItemMovements(itemId)

  if (isLoading) {
    return (
      <div className="fo-screen flex min-h-full flex-col pb-6">
        <ScreenHeader title="Item Detail" subtitle="Loading..." onBack={() => nav.go("search")} />
        <div className="flex flex-1 items-center justify-center">
          <Icon name="loader" className="h-8 w-8 animate-spin text-ink-faint" />
        </div>
      </div>
    )
  }

  if (isError || !item) {
    return (
      <div className="fo-screen flex min-h-full flex-col pb-6">
        <ScreenHeader title="Item Detail" subtitle="Unavailable" onBack={() => nav.go("search")} />
        <div className="mx-5 mt-8 rounded-2xl border border-danger/20 bg-danger-soft p-4 text-center">
          <Icon name="alert" className="mx-auto h-7 w-7 text-danger" strokeWidth={1.75} />
          <p className="mt-2 text-[15px] font-bold text-ink">Live inventory unavailable</p>
          <p className="mt-1 text-[13px] text-ink-soft">
            No fixture stock has been substituted.{error instanceof Error ? ` ${error.message}` : ""}
          </p>
        </div>
      </div>
    )
  }

  const stock = binPositions.map((position) => ({
    loc: nav.locationName,
    bin: position.binCode,
    onHand: position.onHand,
    available: position.available,
    reserved: position.reserved,
    damaged: position.damaged,
    inTransit: position.inTransit,
  }))
  const states: { label: string; value: number; tone: string }[] = [
    { label: "On hand", value: item.onHand, tone: "text-ink" },
    { label: "Available", value: item.available, tone: "text-success" },
    { label: "Reserved", value: item.reserved, tone: "text-warning" },
    { label: "In transit", value: item.inTransit, tone: "text-brand" },
    { label: "Damaged", value: item.damaged, tone: "text-danger" },
    { label: "Blocked", value: item.blocked, tone: "text-ink-soft" },
  ]

  return (
    <div className="fo-screen flex min-h-full flex-col pb-6">
      <ScreenHeader title="Item Detail" subtitle={`${item.sku} · UOM ${item.unit}`} onBack={() => nav.go("search")} />

      {/* hero */}
      <div className="px-5">
        <div className="flex gap-4">
          <div className="h-20 w-20 shrink-0 overflow-hidden rounded-2xl border border-hairline bg-[#f5f6f8]">
            <img src={item.img} alt={item.name} className="h-full w-full object-cover" />
          </div>
          <div className="min-w-0 flex-1">
            <h2 className="text-[18px] font-extrabold leading-tight tracking-[-0.01em] text-ink">{item.name}</h2>
            <p className="mt-0.5 text-[13px] text-ink-faint">{item.sku} · barcode {item.barcode}</p>
            <div className="mt-2 flex flex-wrap gap-1.5">
              {item.available < 0 ? (
                <StatusChip tone="danger">Negative available-to-promise</StatusChip>
              ) : item.available === 0 ? (
                <StatusChip tone="danger">Out of stock</StatusChip>
              ) : item.available <= 8 ? (
                <StatusChip tone="warning">Low stock</StatusChip>
              ) : (
                <StatusChip tone="success">In stock</StatusChip>
              )}
              {item.blocked > 0 && <StatusChip tone="neutral">{item.blocked} blocked</StatusChip>}
            </div>
          </div>
        </div>
      </div>

      {/* stock truth grid */}
      <div className="mt-5 px-5">
        <div className="grid grid-cols-3 overflow-hidden rounded-2xl border border-hairline bg-white">
          {states.map((s, i) => (
            <div
              key={s.label}
              className={`px-2 py-3.5 text-center ${i % 3 !== 2 ? "border-r border-hairline" : ""} ${
                i < 3 ? "border-b border-hairline" : ""
              }`}
            >
              <div className={`text-[20px] font-extrabold tracking-tight ${s.tone}`}>{s.value}</div>
              <div className="mt-0.5 text-[13px] font-medium text-ink-faint">{s.label}</div>
            </div>
          ))}
        </div>
        <p className="mt-2 px-1 text-[13px] text-ink-faint">
          Available = on hand − reserved − damaged − blocked. In-transit stays separate until received.
        </p>
      </div>

      {/* stock by authoritative bin */}
      <div className="mt-6 space-y-3">
        <SectionHeader title="Stock by bin" />
        <ul className="mx-5 divide-y divide-hairline overflow-hidden rounded-2xl border border-hairline bg-white">
          {stock.map((l) => (
            <li key={`${l.loc}:${l.bin}`}>
              <button
                onClick={() => nav.go("search")}
                className="flex w-full items-center gap-3 px-3.5 py-3 text-left transition-colors hover:bg-[#fafbfc]"
              >
                <span className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-brand-soft text-brand">
                  <Icon name="location" className="h-4.5 w-4.5" strokeWidth={2} />
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[14px] font-semibold text-ink">{l.loc}</span>
                  <span className="block text-[13px] text-ink-faint">
                    Bin {l.bin} · {l.available} avail · {l.reserved} reserved
                    {l.damaged > 0 ? ` · ${l.damaged} damaged` : ""}
                    {l.inTransit > 0 ? ` · ${l.inTransit} inbound transit` : ""}
                  </span>
                </span>
                <span className="text-right">
                  <span className="block text-[14px] font-bold text-ink">{l.onHand}</span>
                  <span className="block text-[13px] text-ink-faint">{item.unit}</span>
                </span>
                <Icon name="chevron-right" className="h-4 w-4 shrink-0 text-ink-faint" strokeWidth={2} />
              </button>
            </li>
          ))}
        </ul>
      </div>

      {/* recent movements */}
      <div className="mt-6 space-y-3">
        <SectionHeader title="Recent movements" action="Full history" onAction={() => nav.go("history")} />
        <ul className="mx-5 divide-y divide-hairline overflow-hidden rounded-2xl border border-hairline bg-white">
          {moves.map((m) => (
            <li key={m.ref + m.when} className="flex items-center gap-3 px-3.5 py-3">
              <span
                className={`grid h-9 w-9 shrink-0 place-items-center rounded-xl ${
                  m.qty.startsWith("+") ? "bg-success-soft text-success" : m.qty.startsWith("-") ? "bg-danger-soft text-danger" : "bg-brand-soft text-brand"
                }`}
              >
                <Icon name="history" className="h-4.5 w-4.5" strokeWidth={2} />
              </span>
              <span className="min-w-0 flex-1">
                <span className="block truncate text-[14px] font-semibold text-ink">{m.type}</span>
                <span className="block truncate text-[13px] text-ink-faint">{m.ref} · {m.when}</span>
                <span className="mt-1 block">
                  <SyncBadge state={m.sync} />
                </span>
              </span>
              <span className={`text-[14px] font-bold ${m.qty.startsWith("+") ? "text-success" : m.qty.startsWith("-") ? "text-danger" : "text-brand"}`}>
                {m.qty} <span className="text-[13px] font-medium text-ink-faint">{item.unit}</span>
              </span>
            </li>
          ))}
        </ul>
      </div>

      {/* Authoritative related documents are introduced in Phase 3.
          Do not mix fixture tasks into a live inventory detail screen. */}

      <div className="mt-auto grid grid-cols-2 gap-3 px-5 pt-6">
        <Button variant="secondary" icon="history" onClick={() => nav.go("history")}>
          View movements
        </Button>
        <Button icon="arrow-right" onClick={() => nav.go("work")}>
          Find active tasks
        </Button>
      </div>
    </div>
  )
}
