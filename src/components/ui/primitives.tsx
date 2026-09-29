import { useState, useEffect, type ReactNode } from "react"
import Icon, { type IconName } from "./Icon"
import type { Task, SyncState } from "../inventory/models"

/* ---------- Button ---------- */
type ButtonProps = {
  children: ReactNode
  onClick?: () => void
  variant?: "primary" | "secondary"
  icon?: IconName
  className?: string
}

export function Button({ children, onClick, variant = "primary", icon, className = "" }: ButtonProps) {
  const base =
    "w-full h-[54px] rounded-[1.25rem] text-[15px] font-bold inline-flex items-center justify-center gap-2.5 transition-all duration-200 active:scale-[0.98] focus:outline-none focus-visible:ring-4 focus-visible:ring-brand/20"
  const styles =
    variant === "primary"
      ? "bg-gradient-brand text-white shadow-[0_8px_24px_-8px_rgba(67,56,202,0.6)] hover:shadow-[0_12px_28px_-6px_rgba(67,56,202,0.7)] hover:opacity-95"
      : "bg-white text-ink shadow-sm border border-hairline hover:bg-gray-50 hover:border-gray-300"
  return (
    <button onClick={onClick} className={`${base} ${styles} ${className}`}>
      {icon && <Icon name={icon} className="h-5 w-5" strokeWidth={2.2} />}
      {children}
    </button>
  )
}

/* ---------- StatusChip ---------- */
type Tone = "success" | "warning" | "danger" | "neutral" | "brand"

const toneMap: Record<Tone, string> = {
  success: "bg-success-soft text-success border-success/20",
  warning: "bg-warning-soft text-warning border-warning/30",
  danger: "bg-danger-soft text-danger border-danger/20",
  neutral: "bg-[#f1f2f5] text-ink-soft border-[#e2e8f0]",
  brand: "bg-brand-soft text-brand-vibrant border-brand/20",
}

export function StatusChip({ tone, children }: { tone: Tone; children: ReactNode }) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[12px] font-bold uppercase tracking-wider ${toneMap[tone]}`}
    >
      {children}
    </span>
  )
}

/* ---------- SectionHeader ---------- */
export function SectionHeader({
  title,
  action,
  onAction,
}: {
  title: string
  action?: string
  onAction?: () => void
}) {
  return (
    <div className="flex items-center justify-between px-5">
      <h3 className="text-[15px] font-bold tracking-[-0.01em] text-ink">{title}</h3>
      {action && (
        <button
          onClick={onAction}
          className="text-[13px] font-semibold text-brand transition-colors hover:text-[#3a41e0]"
        >
          {action}
        </button>
      )}
    </div>
  )
}

/* ---------- ProgressBar ---------- */
export function ProgressBar({
  value,
  tone = "brand",
  className = "",
}: {
  value: number
  tone?: "brand" | "success"
  className?: string
}) {
  const fill = tone === "success" ? "bg-success" : "bg-brand"
  return (
    <div className={`h-1.5 w-full overflow-hidden rounded-full bg-[#edeef2] ${className}`}>
      <div
        className={`h-full rounded-full ${fill} transition-[width] duration-500 ease-out`}
        style={{ width: `${Math.min(100, Math.max(0, value))}%` }}
      />
    </div>
  )
}

/* ---------- ItemThumb ---------- */
export function ItemThumb({ src, alt }: { src: string; alt: string }) {
  return (
    <div className="h-11 w-11 shrink-0 overflow-hidden rounded-xl border border-hairline bg-[#f5f6f8]">
      <img src={src} alt={alt} className="h-full w-full object-cover" loading="lazy" />
    </div>
  )
}

/* ---------- LocationRow (document/location context selector) ---------- */
export function ContextRow({
  icon,
  title,
  subtitle,
  onClick,
  tone = "brand",
}: {
  icon: IconName
  title: string
  subtitle: string
  onClick?: () => void
  tone?: Tone
}) {
  return (
    <button
      onClick={onClick}
      className="flex w-full items-center gap-3 rounded-2xl border border-hairline bg-white px-3.5 py-3 text-left transition-all hover:border-brand/30 hover:shadow-[0_6px_16px_-12px_rgba(12,16,51,0.35)]"
    >
      <span
        className={`grid h-10 w-10 place-items-center rounded-xl ${toneMap[tone]}`}
      >
        <Icon name={icon} className="h-5 w-5" strokeWidth={2} />
      </span>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-[15px] font-semibold text-ink">{title}</span>
        <span className="block truncate text-[13px] text-ink-faint">{subtitle}</span>
      </span>
      <Icon name="chevron-right" className="h-4.5 w-4.5 shrink-0 text-ink-faint" strokeWidth={2} />
    </button>
  )
}

/* ---------- StickyBar (bottom action) ---------- */
export function StickyBar({ children }: { children: ReactNode }) {
  return (
    <div className="sticky bottom-0 mt-auto border-t border-hairline bg-canvas/95 px-5 py-4 backdrop-blur">
      {children}
    </div>
  )
}

/* ---------- OfflineBanner ---------- */
export function ConnState({
  online,
  detail,
  onClick,
}: {
  online: boolean
  detail: string
  onClick?: () => void
}) {
  return (
    <button
      onClick={onClick}
      className={`flex w-full items-center gap-2.5 rounded-xl px-3 py-2 text-left transition-colors ${
        online ? "bg-transparent" : "bg-warning-soft"
      }`}
    >
      <Icon
        name={online ? "cloud-sync" : "cloud-off"}
        className={`h-4 w-4 shrink-0 ${online ? "text-success" : "text-warning"}`}
        strokeWidth={2}
      />
      <span className="min-w-0 flex-1">
        <span className={`text-[13px] font-semibold ${online ? "text-ink" : "text-[#c77a00]"}`}>
          {online ? "Online" : "Offline"}
        </span>
        <span className="ml-1.5 text-[13px] text-ink-faint">{detail}</span>
      </span>
    </button>
  )
}

/* ---------- DocumentHeader ---------- */
export function DocumentHeader({
  ref: docRef,
  from,
  to,
  status,
  tone = "brand",
  meta,
}: {
  ref: string
  from: string
  to: string
  status: string
  tone?: Tone
  meta?: string
}) {
  return (
    <div className="rounded-2xl border border-hairline bg-white p-4">
      <div className="flex items-center justify-between">
        <span className="text-[16px] font-extrabold tracking-[-0.01em] text-ink">{docRef}</span>
        <StatusChip tone={tone}>{status}</StatusChip>
      </div>
      <div className="mt-3 flex items-center gap-2 text-[13px]">
        <span className="min-w-0 flex-1 truncate font-semibold text-ink-soft">{from}</span>
        <Icon name="arrow-right" className="h-4 w-4 shrink-0 text-brand" strokeWidth={2.2} />
        <span className="min-w-0 flex-1 truncate text-right font-semibold text-ink">{to}</span>
      </div>
      {meta && <p className="mt-2.5 border-t border-hairline pt-2.5 text-[13px] text-ink-faint">{meta}</p>}
    </div>
  )
}

/* ---------- TaskRow ---------- */
const taskKind: Record<Task["kind"], { icon: IconName; verb: string }> = {
  receive: { icon: "receive", verb: "Receive" },
  dispatch: { icon: "dispatch", verb: "Dispatch" },
  count: { icon: "clipboard", verb: "Count" },
}

export function TaskRow({
  task,
  onClick,
  progress,
}: {
  task: Task
  onClick?: () => void
  progress?: { done: number; total: number }
}) {
  const k = taskKind[task.kind]
  const done = progress?.done ?? task.done
  const total = progress?.total ?? task.total
  const pct = total > 0 ? Math.round((done / total) * 100) : 0
  const completed = total > 0 && done >= total
  const overdue = task.status === "overdue" && !completed
  return (
    <button
      onClick={onClick}
      className="group flex w-full items-start gap-4 rounded-[1.25rem] border border-white bg-white p-4 text-left shadow-[0_4px_20px_-12px_rgba(17,24,39,0.1)] transition-all hover:border-brand/20 hover:shadow-[0_8px_30px_-12px_rgba(67,56,202,0.15)] active:scale-[0.985]"
    >
      <span
        className={`mt-0.5 grid h-11 w-11 shrink-0 place-items-center rounded-[14px] transition-transform group-hover:scale-105 ${
          completed ? "bg-success-soft text-success" : overdue ? "bg-danger-soft text-danger" : "bg-gradient-brand text-white shadow-md shadow-brand/30"
        }`}
      >
        <Icon name={k.icon} className="h-5 w-5" strokeWidth={2.2} />
      </span>
      <span className="min-w-0 flex-1">
        <span className="flex items-center gap-2">
          <span className="truncate text-[16px] font-extrabold tracking-tight text-ink">
            {k.verb} {task.ref}
          </span>
          {completed ? <StatusChip tone="success">Completed</StatusChip> : task.priority === "high" && <StatusChip tone="danger">High</StatusChip>}
        </span>
        <span className="mt-0.5 block truncate text-[14px] font-medium text-ink-faint">{task.where}</span>
        <span className="mt-3 flex items-center gap-3">
          <ProgressBar value={pct} tone={pct === 100 ? "success" : "brand"} className="flex-1" />
          <span className="shrink-0 text-[13px] font-bold text-ink-soft">
            {done}/{total}
          </span>
        </span>
        <span className={`mt-2 flex items-center gap-1.5 text-[13px] font-bold ${completed ? "text-success" : overdue ? "text-danger" : "text-ink-faint"}`}>
          <Icon name={completed ? "check-circle" : "clock"} className="h-4 w-4" strokeWidth={2.2} />
          {completed ? "Completed" : task.due}
        </span>
      </span>
    </button>
  )
}

/* ---------- QtyStepper ---------- */
export function QtyStepper({
  value,
  onChange,
  unit,
  autoFocus,
  step = 1,
  scale = 0,
  max,
}: {
  value: number
  onChange: (v: number) => void
  unit: string
  autoFocus?: boolean
  step?: number
  scale?: number
  max?: number
}) {
  const normalizedScale = Math.max(0, Math.min(scale, 6))
  const safeStep = step > 0 ? step : 1
  const format = (v: number) => {
    const factor = 10 ** normalizedScale
    const rounded = Math.round((v + Number.EPSILON) * factor) / factor
    return normalizedScale > 0
      ? rounded.toFixed(normalizedScale).replace(/(?:\.0+|(?:(\.[0-9]*?)0+))$/, "$1")
      : String(Math.trunc(rounded))
  }
  const normalize = (v: number) => {
    const factor = 10 ** normalizedScale
    const stepped = Math.round((v + Number.EPSILON) / safeStep) * safeStep
    const rounded = Math.round((stepped + Number.EPSILON) * factor) / factor
    const bounded = Math.max(0, max == null ? rounded : Math.min(rounded, max))
    return Math.round((bounded + Number.EPSILON) * factor) / factor
  }

  const [text, setText] = useState(format(value))

  useEffect(() => {
    setText(format(value))
  }, [value, normalizedScale])

  const commit = (candidate: number) => {
    const next = normalize(candidate)
    setText(format(next))
    onChange(next)
  }

  return (
    <div className="flex items-center gap-3">
      <button
        onClick={() => commit(value - safeStep)}
        className="grid h-12 w-12 shrink-0 place-items-center rounded-xl border border-hairline bg-white text-ink transition-colors hover:bg-[#f5f6f8] active:scale-95"
        aria-label="Decrease"
      >
        <Icon name="minus" className="h-5 w-5" strokeWidth={2.4} />
      </button>
      <div className="flex flex-1 items-baseline justify-center gap-1.5 rounded-xl border border-brand/25 bg-brand-soft py-2.5">
        <input
          autoFocus={autoFocus}
          inputMode="decimal"
          value={text}
          onChange={(e) => {
            const raw = e.target.value.replace(/,/g, ".")
            const pattern = normalizedScale > 0
              ? new RegExp(`^\\d*(?:\\.\\d{0,${normalizedScale}})?$`)
              : /^\d*$/
            if (!pattern.test(raw)) return
            setText(raw)
            if (raw !== "" && raw !== ".") {
              const parsed = Number(raw)
              if (Number.isFinite(parsed)) onChange(normalize(parsed))
            }
          }}
          onBlur={() => {
            const parsed = Number(text)
            commit(Number.isFinite(parsed) ? parsed : 0)
          }}
          className="w-20 bg-transparent text-center text-[28px] font-extrabold tracking-tight text-brand focus:outline-none"
        />
        <span className="text-[14px] font-semibold text-brand/70">{unit}</span>
      </div>
      <button
        onClick={() => commit(value + safeStep)}
        className="grid h-12 w-12 shrink-0 place-items-center rounded-xl border border-hairline bg-white text-ink transition-colors hover:bg-[#f5f6f8] active:scale-95"
        aria-label="Increase"
      >
        <Icon name="plus" className="h-5 w-5" strokeWidth={2.4} />
      </button>
    </div>
  )
}

/* ---------- ReasonSelector ---------- */
export function ReasonSelector({
  reasons,
  value,
  onChange,
  label,
}: {
  reasons: string[]
  value: string
  onChange: (v: string) => void
  label: string
}) {
  return (
    <div className="space-y-2">
      <label className="block text-[13px] font-bold text-ink">{label}</label>
      <div className="flex flex-wrap gap-2">
        {reasons.map((r) => {
          const on = r === value
          return (
            <button
              key={r}
              onClick={() => onChange(r)}
              className={`rounded-full border px-3 py-1.5 text-[13px] font-semibold transition-all ${
                on
                  ? "border-brand bg-brand text-white"
                  : "border-hairline bg-white text-ink-soft hover:border-brand/30"
              }`}
            >
              {r}
            </button>
          )
        })}
      </div>
    </div>
  )
}

/* ---------- ExceptionPanel ---------- */
export function ExceptionPanel({
  tone = "danger",
  title,
  children,
}: {
  tone?: "danger" | "warning"
  title: string
  children: ReactNode
}) {
  const styles =
    tone === "danger"
      ? "border-danger/25 bg-danger-soft"
      : "border-warning/30 bg-warning-soft"
  const iconColor = tone === "danger" ? "text-danger" : "text-warning"
  return (
    <div className={`rounded-2xl border p-4 ${styles}`}>
      <div className="flex items-center gap-2">
        <Icon name="alert" className={`h-4.5 w-4.5 ${iconColor}`} strokeWidth={2.2} />
        <span className="text-[14px] font-bold text-ink">{title}</span>
      </div>
      <div className="mt-3 space-y-3">{children}</div>
    </div>
  )
}

/* ---------- SyncBadge ---------- */
const syncMap: Record<SyncState, { label: string; tone: Tone; icon: IconName; spin?: boolean }> = {
  local: { label: "Saved locally", tone: "neutral", icon: "cloud-off" },
  queued: { label: "Queued", tone: "brand", icon: "clock" },
  syncing: { label: "Syncing", tone: "brand", icon: "refresh", spin: true },
  confirmed: { label: "Confirmed", tone: "success", icon: "check-circle" },
  failed: { label: "Failed", tone: "danger", icon: "x-circle" },
  conflict: { label: "Conflict", tone: "warning", icon: "alert" },
  blocked: { label: "Blocked", tone: "danger", icon: "alert" },
  cancelled: { label: "Cancelled", tone: "neutral", icon: "x-circle" },
}

export function SyncBadge({ state }: { state: SyncState }) {
  const s = syncMap[state]
  return (
    <StatusChip tone={s.tone}>
      <Icon name={s.icon} className={`h-3.5 w-3.5 ${s.spin ? "fo-spin" : ""}`} strokeWidth={2.2} />
      {s.label}
    </StatusChip>
  )
}
