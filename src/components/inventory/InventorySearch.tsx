import { useState } from "react"
import Icon from "../ui/Icon"
import { StatusChip } from "../ui/primitives"
import { useItems } from "../../lib/queries"
import type { Nav } from "./types"

type FilterId = "all" | "low" | "reserved" | "in-transit"

const filters: { id: FilterId; label: string }[] = [
  { id: "all", label: "All items" },
  { id: "low", label: "Low / out" },
  { id: "reserved", label: "Has reserved" },
  { id: "in-transit", label: "In transit" },
]

export default function InventorySearch({ nav }: { nav: Nav }) {
  const [q, setQ] = useState("")
  const [filter, setFilter] = useState<FilterId>("all")
  
  const { data: items = [], isLoading, isError, error } = useItems()

  const byFilter = items.filter((it) => {
    if (filter === "low") return it.available <= 8
    if (filter === "reserved") return it.reserved > 0
    if (filter === "in-transit") return it.inTransit > 0
    return true
  })
  const results = byFilter.filter(
    (it) =>
      it.name.toLowerCase().includes(q.toLowerCase()) ||
      it.sku.toLowerCase().includes(q.toLowerCase()) ||
      it.barcode.replace(/\s/g, "").includes(q.replace(/\s/g, "")),
  )

  return (
    <div className="fo-screen flex min-h-full flex-col pb-6">
      <div className="px-5 pb-3 pt-4">
        <h1 className="text-[24px] font-extrabold tracking-[-0.02em] text-ink">Inventory</h1>
        <p className="mt-0.5 text-[13px] text-ink-faint">Search by name, SKU or barcode</p>
      </div>

      {/* search field + scan */}
      <div className="flex items-center gap-2.5 px-5">
        <div className="flex flex-1 items-center gap-2.5 rounded-xl border border-hairline bg-white px-3.5">
          <Icon name="search" className="h-4.5 w-4.5 text-ink-faint" strokeWidth={2} />
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="e.g. LED bulb, EL-B-045"
            className="h-12 flex-1 bg-transparent text-[15px] text-ink placeholder:text-ink-faint focus:outline-none"
          />
          {q && (
            <button onClick={() => setQ("")} aria-label="Clear">
              <Icon name="x" className="h-4 w-4 text-ink-faint" strokeWidth={2} />
            </button>
          )}
        </div>
        <button
          onClick={() => nav.openScan("browse")}
          className="grid h-12 w-12 shrink-0 place-items-center rounded-xl bg-brand text-white transition-transform active:scale-95"
          aria-label="Scan barcode"
        >
          <Icon name="scan" className="h-5 w-5" strokeWidth={2} />
        </button>
      </div>

      {/* filters */}
      <div className="no-scrollbar mt-3 overflow-x-auto px-5">
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

      {!nav.online && (
        <div className="mx-5 mt-3 flex items-center gap-2 rounded-xl bg-warning-soft px-3 py-2 text-[13px] font-medium text-[#c77a00]">
          <Icon name="cloud-off" className="h-4 w-4" strokeWidth={2} />
          Offline — searching stock cached on this device
        </div>
      )}

      {/* results */}
      <div className="mt-4 flex-1 px-5">
        {isLoading ? (
          <div className="mt-8 flex flex-col items-center gap-2 text-center text-ink-faint">
            <Icon name="loader" className="h-6 w-6 animate-spin" strokeWidth={1.75} />
            <p className="mt-1 text-[13px]">Loading stock levels...</p>
          </div>
        ) : isError ? (
          <div className="mt-8 flex flex-col items-center gap-2 text-center">
            <span className="grid h-14 w-14 place-items-center rounded-2xl bg-danger-soft text-danger">
              <Icon name="alert" className="h-6 w-6" strokeWidth={1.75} />
            </span>
            <p className="mt-1 text-[15px] font-bold text-ink">Inventory unavailable</p>
            <p className="max-w-[17rem] text-[13px] text-ink-faint">
              Live warehouse stock could not be loaded. No demo inventory has been substituted.
              {error instanceof Error ? ` ${error.message}` : ""}
            </p>
          </div>
        ) : results.length === 0 ? (
          <div className="mt-8 flex flex-col items-center gap-2 text-center">
            <span className="grid h-14 w-14 place-items-center rounded-2xl bg-[#f1f2f5] text-ink-faint">
              <Icon name="search" className="h-6 w-6" strokeWidth={1.75} />
            </span>
            <p className="mt-1 text-[15px] font-bold text-ink">No items found</p>
            <p className="max-w-[15rem] text-[13px] text-ink-faint">
              Nothing matches “{q}”. Check the spelling or scan the barcode instead.
            </p>
          </div>
        ) : (
          <>
            <p className="mb-2 text-[13px] font-semibold uppercase tracking-wide text-ink-faint">
              {results.length} result{results.length > 1 ? "s" : ""}
            </p>
            <ul className="space-y-2.5">
              {results.map((it) => (
                <li key={it.id}>
                  <button
                    onClick={() => nav.openItem(it.id)}
                    className="flex w-full items-center gap-3 rounded-2xl border border-hairline bg-white px-3.5 py-3 text-left transition-all hover:border-brand/30"
                  >
                    <div className="h-12 w-12 shrink-0 overflow-hidden rounded-xl border border-hairline bg-[#f5f6f8]">
                      <img src={it.img} alt={it.name} className="h-full w-full object-cover" />
                    </div>
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-[14px] font-semibold text-ink">{it.name}</p>
                      <p className="text-[13px] text-ink-faint">{it.sku} · {it.unit}</p>
                      <div className="mt-1 flex flex-wrap gap-1.5">
                        {it.available < 0 ? (
                          <StatusChip tone="danger">Negative ATP · {it.available}</StatusChip>
                        ) : it.available === 0 ? (
                          <StatusChip tone="danger">Out of stock</StatusChip>
                        ) : it.available <= 8 ? (
                          <StatusChip tone="warning">Low · {it.available} avail</StatusChip>
                        ) : (
                          <StatusChip tone="success">{it.available} available</StatusChip>
                        )}
                        {it.inTransit > 0 && <StatusChip tone="brand">{it.inTransit} in transit</StatusChip>}
                      </div>
                    </div>
                    <div className="shrink-0 text-right">
                      <p className="text-[15px] font-extrabold text-ink">{it.onHand}</p>
                      <p className="text-[13px] text-ink-faint">on hand</p>
                    </div>
                  </button>
                </li>
              ))}
            </ul>
          </>
        )}
      </div>
    </div>
  )
}
