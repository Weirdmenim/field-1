import type { ReactNode } from "react"
import Icon from "./ui/Icon"

/* Screen header used inside sub-screens */
export function ScreenHeader({
  title,
  subtitle,
  onBack,
}: {
  title: string
  subtitle: string
  onBack?: () => void
}) {
  return (
    <div className="flex items-start gap-3 px-5 pt-3 pb-4">
      {onBack && (
        <button
          onClick={onBack}
          className="mt-0.5 grid h-9 w-9 shrink-0 place-items-center rounded-full border border-hairline bg-white text-ink transition-colors hover:bg-[#f5f6f8]"
          aria-label="Back"
        >
          <Icon name="chevron-left" className="h-5 w-5" strokeWidth={2} />
        </button>
      )}
      <div className="min-w-0 flex-1">
        <h1 className="text-[22px] font-extrabold leading-tight tracking-[-0.02em] text-ink">{title}</h1>
        <p className="mt-0.5 text-[13px] text-ink-faint">{subtitle}</p>
      </div>
      <button
        className="mt-0.5 grid h-9 w-9 shrink-0 place-items-center rounded-full text-ink-faint transition-colors hover:bg-[#f5f6f8]"
        aria-label="More options"
      >
        <Icon name="dots" className="h-5 w-5" />
      </button>
    </div>
  )
}

export default function PhoneFrame({
  children,
  bottomBar,
}: {
  children: ReactNode
  bottomBar?: ReactNode
}) {
  return (
    <div className="relative h-[812px] w-[375px] shrink-0 rounded-[3.2rem] bg-[#0c1033] p-[5px] shadow-[0_40px_80px_-24px_rgba(12,16,51,0.45),0_0_0_1px_rgba(12,16,51,0.06)]">
      {/* screen */}
      <div className="relative flex h-full w-full flex-col overflow-hidden rounded-[2.85rem] bg-canvas">
        {/* status bar */}
        <div className="relative z-20 flex h-11 items-center justify-between px-7 pt-1.5 text-ink">
          <span className="text-[13px] font-semibold tracking-tight">9:41</span>
          {/* notch */}
          <div className="absolute left-1/2 top-2 h-6 w-[112px] -translate-x-1/2 rounded-full bg-[#0c1033]" />
          <div className="flex items-center gap-1.5">
            <SignalBars />
            <WifiGlyph />
            <BatteryGlyph />
          </div>
        </div>

        {/* scrollable content */}
        <div className="no-scrollbar relative flex-1 overflow-y-auto">{children}</div>

        {/* bottom bar */}
        {bottomBar && <div className="relative z-20 shrink-0">{bottomBar}</div>}
      </div>
    </div>
  )
}

function SignalBars() {
  return (
    <svg width="18" height="12" viewBox="0 0 18 12" className="text-ink">
      <rect x="0" y="8" width="3" height="4" rx="1" fill="currentColor" />
      <rect x="5" y="5.5" width="3" height="6.5" rx="1" fill="currentColor" />
      <rect x="10" y="3" width="3" height="9" rx="1" fill="currentColor" />
      <rect x="15" y="0.5" width="3" height="11.5" rx="1" fill="currentColor" opacity="0.35" />
    </svg>
  )
}

function WifiGlyph() {
  return (
    <svg width="16" height="12" viewBox="0 0 16 12" className="text-ink" fill="none">
      <path d="M1 4.2a11 11 0 0 1 14 0" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
      <path d="M3.4 6.9a7.3 7.3 0 0 1 9.2 0" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
      <path d="M5.8 9.5a3.6 3.6 0 0 1 4.4 0" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  )
}

function BatteryGlyph() {
  return (
    <svg width="26" height="13" viewBox="0 0 26 13" className="text-ink" fill="none">
      <rect x="0.6" y="0.6" width="21" height="11.8" rx="3" stroke="currentColor" strokeWidth="1.2" opacity="0.4" />
      <rect x="2.2" y="2.2" width="16" height="8.6" rx="1.8" fill="currentColor" />
      <rect x="23" y="4" width="2.2" height="5" rx="1.1" fill="currentColor" opacity="0.4" />
    </svg>
  )
}
