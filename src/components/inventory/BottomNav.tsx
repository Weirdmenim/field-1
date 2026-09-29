import Icon, { type IconName } from "../ui/Icon"

export type Tab = "home" | "work" | "scan" | "inventory" | "sync"

const tabs: { id: Tab; label: string; icon: IconName }[] = [
  { id: "home", label: "Home", icon: "home" },
  { id: "work", label: "Work", icon: "work" },
  { id: "scan", label: "Scan", icon: "scan" },
  { id: "inventory", label: "Inventory", icon: "box" },
  { id: "sync", label: "Sync", icon: "cloud-sync" },
]

export default function BottomNav({
  active,
  onSelect,
  pending = 0,
}: {
  active: Tab
  onSelect: (t: Tab) => void
  pending?: number
}) {
  return (
    <div className="absolute bottom-6 left-1/2 -translate-x-1/2 w-[calc(100%-2.5rem)] max-w-sm z-50">
      <nav className="rounded-[2rem] border border-white/50 bg-white/80 p-2 shadow-[0_16px_40px_-12px_rgba(17,24,39,0.25)] backdrop-blur-xl">
        <ul className="flex items-center justify-between px-1">
          {tabs.map((t) => {
            if (t.id === "scan") {
              return (
                <li key={t.id} className="mx-2">
                  <button
                    onClick={() => onSelect(t.id)}
                    className="group flex flex-col items-center gap-1"
                    aria-label="Scan"
                  >
                    <span className="grid h-16 w-16 place-items-center rounded-2xl bg-gradient-brand text-white shadow-[0_8px_20px_-6px_rgba(67,56,202,0.6)] transition-all duration-300 group-hover:scale-105 group-hover:shadow-[0_12px_24px_-4px_rgba(67,56,202,0.7)] group-active:scale-95">
                      <Icon name="scan" className="h-7 w-7" strokeWidth={2.2} />
                    </span>
                  </button>
                </li>
              )
            }
            const on = t.id === active
            return (
              <li key={t.id} className="flex-1">
                <button
                  onClick={() => onSelect(t.id)}
                  className="relative flex w-full flex-col items-center gap-1.5 rounded-2xl py-2 transition-all hover:bg-black/5 active:scale-95"
                >
                  {t.id === "sync" && pending > 0 && (
                    <span className="absolute right-[15%] top-1 grid h-4.5 min-w-[18px] place-items-center rounded-full border-2 border-white bg-warning px-1 text-[11px] font-black text-white shadow-sm">
                      {pending}
                    </span>
                  )}
                  <Icon
                    name={t.icon}
                    className={`h-6 w-6 transition-colors ${on ? "text-brand" : "text-ink-faint/70"}`}
                    strokeWidth={on ? 2.2 : 1.8}
                  />
                  <span className={`text-[11px] font-bold tracking-wide transition-colors ${on ? "text-brand" : "text-ink-faint/70"}`}>
                    {t.label}
                  </span>
                </button>
              </li>
            )
          })}
        </ul>
      </nav>
    </div>
  )
}

