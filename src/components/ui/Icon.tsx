import type { ReactNode } from "react"

type IconProps = {
  name: IconName
  className?: string
  strokeWidth?: number
}

export type IconName =
  | "menu"
  | "chevron-right"
  | "chevron-left"
  | "chevron-down"
  | "dots"
  | "box"
  | "receive"
  | "dispatch"
  | "clipboard"
  | "search"
  | "home"
  | "work"
  | "customers"
  | "more"
  | "orders"
  | "collections"
  | "procurement"
  | "finance"
  | "reporting"
  | "field"
  | "commercial"
  | "truck"
  | "scan"
  | "check"
  | "check-circle"
  | "cloud-sync"
  | "refresh"
  | "dot"
  | "warning"
  | "location"
  | "history"
  | "layers"
  | "flash"
  | "flash-off"
  | "keyboard"
  | "x"
  | "x-circle"
  | "plus"
  | "minus"
  | "clock"
  | "cloud-off"
  | "alert"
  | "arrow-right"
  | "filter"
  | "package-check"
  | "user"
  | "shield"
  | "loader"

const paths: Record<IconName, ReactNode> = {
  menu: (
    <>
      <path d="M3 6h18M3 12h18M3 18h18" />
    </>
  ),
  loader: (
    <>
      <path d="M12 2v4M12 18v4M4.93 4.93l2.83 2.83M16.24 16.24l2.83 2.83M2 12h4M18 12h4M4.93 19.07l2.83-2.83M16.24 7.76l2.83-2.83" />
    </>
  ),
  "chevron-right": <path d="m9 6 6 6-6 6" />,
  "chevron-left": <path d="m15 6-6 6 6 6" />,
  "chevron-down": <path d="m6 9 6 6 6-6" />,
  dots: (
    <>
      <circle cx="12" cy="5" r="1.4" />
      <circle cx="12" cy="12" r="1.4" />
      <circle cx="12" cy="19" r="1.4" />
    </>
  ),
  box: (
    <>
      <path d="M21 8 12 3 3 8v8l9 5 9-5V8Z" />
      <path d="m3 8 9 5 9-5M12 13v8" />
    </>
  ),
  receive: (
    <>
      <path d="M12 3v11" />
      <path d="m7 9 5 5 5-5" />
      <path d="M5 21h14" />
    </>
  ),
  dispatch: (
    <>
      <path d="M12 14V3" />
      <path d="m7 8 5-5 5 5" />
      <path d="M5 21h14" />
    </>
  ),
  clipboard: (
    <>
      <rect x="6" y="4" width="12" height="17" rx="2" />
      <path d="M9 4V3h6v1" />
      <path d="m8.5 11 1.5 1.5L13 9M8.5 16l1.5 1.5L13 14" />
    </>
  ),
  search: (
    <>
      <circle cx="11" cy="11" r="7" />
      <path d="m20 20-3.2-3.2" />
    </>
  ),
  home: (
    <>
      <path d="M4 10.5 12 4l8 6.5V20a1 1 0 0 1-1 1h-4v-6H9v6H5a1 1 0 0 1-1-1v-9.5Z" />
    </>
  ),
  work: (
    <>
      <path d="m8.5 12.5 2.2 2.2L16 9.5" />
      <rect x="3.5" y="4.5" width="17" height="15" rx="3" />
    </>
  ),
  customers: (
    <>
      <circle cx="9" cy="8" r="3.2" />
      <path d="M3.5 20c0-3 2.5-5 5.5-5s5.5 2 5.5 5" />
      <path d="M16 5.2A3.2 3.2 0 0 1 16 11" />
      <path d="M17 15c2.4.4 4 2.3 4 5" />
    </>
  ),
  more: (
    <>
      <circle cx="5" cy="12" r="1.6" />
      <circle cx="12" cy="12" r="1.6" />
      <circle cx="19" cy="12" r="1.6" />
    </>
  ),
  orders: (
    <>
      <rect x="5" y="3.5" width="14" height="17" rx="2.5" />
      <path d="M8.5 8h7M8.5 12h7M8.5 16h4" />
    </>
  ),
  collections: (
    <>
      <rect x="3" y="6" width="18" height="12" rx="2.5" />
      <path d="M3 10h18" />
      <path d="M7 15h3" />
    </>
  ),
  procurement: (
    <>
      <path d="M3 4h2l1.5 11h11l1.5-8H6" />
      <circle cx="9" cy="19" r="1.4" />
      <circle cx="17" cy="19" r="1.4" />
    </>
  ),
  finance: (
    <>
      <rect x="4" y="4" width="16" height="16" rx="2.5" />
      <path d="M8.5 15V11M12 15V9M15.5 15v-2.5" />
    </>
  ),
  reporting: (
    <>
      <path d="M5 20V10M12 20V4M19 20v-7" />
    </>
  ),
  field: (
    <>
      <path d="M12 21s7-6.2 7-11a7 7 0 1 0-14 0c0 4.8 7 11 7 11Z" />
      <circle cx="12" cy="10" r="2.4" />
    </>
  ),
  commercial: (
    <>
      <path d="M5 20V11M9.5 20V7M14 20v-6M18.5 20V5" />
    </>
  ),
  truck: (
    <>
      <path d="M3 6.5h11v9H3z" />
      <path d="M14 9.5h4l3 3v3h-7z" />
      <circle cx="7" cy="17.5" r="1.8" />
      <circle cx="17.5" cy="17.5" r="1.8" />
    </>
  ),
  scan: (
    <>
      <path d="M4 8V6a2 2 0 0 1 2-2h2M16 4h2a2 2 0 0 1 2 2v2M20 16v2a2 2 0 0 1-2 2h-2M8 20H6a2 2 0 0 1-2-2v-2" />
      <path d="M4 12h16" />
    </>
  ),
  check: <path d="m5 12.5 4.2 4.2L19 7" />,
  "check-circle": (
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="m8.2 12.3 2.6 2.6L16 9.6" />
    </>
  ),
  "cloud-sync": (
    <>
      <path d="M7 18a4 4 0 0 1-.5-7.97A5.5 5.5 0 0 1 17.5 10 3.5 3.5 0 0 1 17 17" />
      <path d="M9.5 13.5 12 11l2.5 2.5M12 11v6" />
    </>
  ),
  refresh: (
    <>
      <path d="M20 11a8 8 0 0 0-14-4.5L4 8" />
      <path d="M4 4v4h4" />
      <path d="M4 13a8 8 0 0 0 14 4.5L20 16" />
      <path d="M20 20v-4h-4" />
    </>
  ),
  dot: <circle cx="12" cy="12" r="4" />,
  warning: (
    <>
      <path d="M12 3 2.5 20h19L12 3Z" />
      <path d="M12 10v4M12 17.2v.1" />
    </>
  ),
  location: (
    <>
      <path d="M12 21s7-6.2 7-11a7 7 0 1 0-14 0c0 4.8 7 11 7 11Z" />
      <circle cx="12" cy="10" r="2.4" />
    </>
  ),
  history: (
    <>
      <path d="M3.5 12a8.5 8.5 0 1 1 2.6 6.1" />
      <path d="M3.5 19v-4h4" />
      <path d="M12 8v4.5l3 1.8" />
    </>
  ),
  layers: (
    <>
      <path d="m12 3 9 5-9 5-9-5 9-5Z" />
      <path d="m3 13 9 5 9-5" />
    </>
  ),
  flash: <path d="M13 2 4 14h6l-1 8 9-12h-6l1-8Z" />,
  "flash-off": (
    <>
      <path d="M13 2 8 8m-2 6h4l-1 8 4.5-6M4 4l16 16" />
    </>
  ),
  keyboard: (
    <>
      <rect x="3" y="6" width="18" height="12" rx="2.5" />
      <path d="M7 10h.01M11 10h.01M15 10h.01M8 14h8" />
    </>
  ),
  x: <path d="M6 6 18 18M18 6 6 18" />,
  "x-circle": (
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="m9 9 6 6M15 9l-6 6" />
    </>
  ),
  plus: <path d="M12 5v14M5 12h14" />,
  minus: <path d="M5 12h14" />,
  clock: (
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7v5l3 2" />
    </>
  ),
  "cloud-off": (
    <>
      <path d="M7 18a4 4 0 0 1-.5-7.97 5.5 5.5 0 0 1 6.2-3.44M17 8a3.5 3.5 0 0 1 0 9H9" />
      <path d="M3 3l18 18" />
    </>
  ),
  alert: (
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 8v4.5M12 16v.1" />
    </>
  ),
  "arrow-right": <path d="M5 12h14M13 6l6 6-6 6" />,
  filter: <path d="M3 5h18l-7 8v5l-4 2v-7L3 5Z" />,
  "package-check": (
    <>
      <path d="M21 8 12 3 3 8v8l9 5 9-5v-4" />
      <path d="m3 8 9 5 9-5" />
      <path d="m15.5 12.5 2 2 3.5-3.5" />
    </>
  ),
  user: (
    <>
      <circle cx="12" cy="8" r="3.4" />
      <path d="M5 20c0-3.5 3-6 7-6s7 2.5 7 6" />
    </>
  ),
  shield: (
    <>
      <path d="M12 3 5 6v5c0 4.5 3 7.5 7 9 4-1.5 7-4.5 7-9V6l-7-3Z" />
      <path d="m9 12 2 2 4-4" />
    </>
  ),
}

export default function Icon({ name, className, strokeWidth = 1.75 }: IconProps) {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      {paths[name]}
    </svg>
  )
}
