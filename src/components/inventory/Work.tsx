import { useState } from "react"
import Icon from "../ui/Icon"
import { TaskRow } from "../ui/primitives"
import type { Nav } from "./types"

type Filter = "today" | "upcoming" | "attention"

const filters: { id: Filter; label: string }[] = [
  { id: "today", label: "Today" },
  { id: "upcoming", label: "Upcoming" },
  { id: "attention", label: "Requires attention" },
]

export default function Work({ nav }: { nav: Nav }) {
  const [filter, setFilter] = useState<Filter>("today")
  const isComplete = (task: (typeof nav.workItems)[number]) => task.total > 0 && task.done >= task.total
  const allowedTask = (task: (typeof nav.workItems)[number]) =>
    task.kind === "receive"
      ? nav.can("inventory.receive")
      : task.kind === "dispatch"
        ? nav.can("inventory.dispatch")
        : nav.can("inventory.count")
  const visibleTasks = nav.workItems.filter(allowedTask)
  const list = visibleTasks.filter((t) => t.group === filter && !(filter === "attention" && isComplete(t)))

  return (
    <div className="fo-screen flex min-h-full flex-col pb-6">
      <div className="px-5 pb-4 pt-4">
        <h1 className="text-[24px] font-extrabold tracking-[-0.02em] text-ink">My Work</h1>
        <p className="mt-0.5 text-[13px] text-ink-faint">
          {visibleTasks.filter((t) => t.group === "today").length} tasks today ·{" "}
          {visibleTasks.filter((t) => t.status === "overdue" && !isComplete(t)).length} need attention
        </p>
      </div>

      {/* segmented filters */}
      <div className="no-scrollbar -mx-5 mb-4 overflow-x-auto px-5">
        <div className="flex gap-2">
          {filters.map((f) => {
            const on = f.id === filter
            const count = visibleTasks.filter((t) => t.group === f.id && !(f.id === "attention" && isComplete(t))).length
            return (
              <button
                key={f.id}
                onClick={() => setFilter(f.id)}
                className={`flex shrink-0 items-center gap-1.5 rounded-full border px-3.5 py-2 text-[13px] font-semibold transition-all ${
                  on
                    ? "border-brand bg-brand text-white"
                    : "border-hairline bg-white text-ink-soft hover:border-brand/30"
                }`}
              >
                {f.id === "attention" && (
                  <Icon name="alert" className={`h-3.5 w-3.5 ${on ? "" : "text-danger"}`} strokeWidth={2.2} />
                )}
                {f.label}
                <span className={`text-[13px] ${on ? "text-white/70" : "text-ink-faint"}`}>{count}</span>
              </button>
            )
          })}
        </div>
      </div>

      <div className="flex-1 space-y-2.5 px-5">
        {list.length === 0 ? (
          <div className="flex flex-col items-center gap-2 rounded-2xl border border-dashed border-hairline bg-white py-14 text-center">
            <Icon name="check-circle" className="h-9 w-9 text-success" strokeWidth={1.75} />
            <p className="text-[14px] font-semibold text-ink">All clear</p>
            <p className="text-[13px] text-ink-faint">Nothing in this list right now.</p>
          </div>
        ) : (
          list.map((t) => (
            <TaskRow key={t.id} task={t} progress={nav.progressFor(t)} onClick={() => nav.openTask(t.id)} />
          ))
        )}
      </div>
    </div>
  )
}
