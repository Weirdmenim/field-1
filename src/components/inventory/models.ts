export type Item = {
  id: string
  name: string
  sku: string
  barcode: string
  img: string
  unit: string
  onHand: number
  available: number
  reserved: number
  inTransit: number
  damaged: number
  blocked: number
  baseUnitId?: string
  quantityScale?: number
  quantityStep?: number
}

export const itemUuidToSlug: Record<string, string> = {
  "44444444-4444-4444-4444-444444444441": "el-b-045",
  "44444444-4444-4444-4444-444444444442": "pvc-2-5",
  "44444444-4444-4444-4444-444444444443": "jb-100",
  "44444444-4444-4444-4444-444444444444": "cb-32",
  "44444444-4444-4444-4444-444444444445": "cp-20",
}

export const itemSlugToUuid: Record<string, string> = {
  "el-b-045": "44444444-4444-4444-4444-444444444441",
  "pvc-2-5": "44444444-4444-4444-4444-444444444442",
  "jb-100": "44444444-4444-4444-4444-444444444443",
  "cb-32": "44444444-4444-4444-4444-444444444444",
  "cp-20": "44444444-4444-4444-4444-444444444445",
}

export const findItemById = (id: string, list: Item[]): Item | undefined => {
  const norm = (id || "").trim().toLowerCase()
  const slug = itemUuidToSlug[id] || norm
  return list.find(
    (i) =>
      i.id === id ||
      i.id.toLowerCase() === norm ||
      i.id.toLowerCase() === slug ||
      i.sku.toLowerCase() === norm ||
      itemSlugToUuid[i.id] === id,
  )
}

const unknownItem = (id: string): Item => ({
  id: (id || "unknown").toLowerCase(),
  name: "Unknown product",
  sku: id || "UNKNOWN",
  barcode: id || "UNKNOWN",
  img: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160' viewBox='0 0 160 160'%3E%3Crect width='160' height='160' fill='%23f1f2f5'/%3E%3Cpath d='M45 58l35-19 35 19v44l-35 19-35-19z' fill='none' stroke='%23959aa5' stroke-width='5'/%3E%3C/svg%3E",
  unit: "unit",
  quantityScale: 0,
  quantityStep: 1,
  onHand: 0,
  available: 0,
  reserved: 0,
  inTransit: 0,
  damaged: 0,
  blocked: 0,
})

export const itemById = (id: string, list: Item[]): Item => {
  const found = findItemById(id, list)
  if (found) return found
  return unknownItem(id)
}

export type TaskStatus = "assigned" | "in-progress" | "overdue" | "completed"
export type Task = {
  id: string
  kind: "receive" | "dispatch" | "count"
  ref: string
  title: string
  where: string
  due: string
  priority: "normal" | "high"
  done: number
  total: number
  status: TaskStatus
  group: "today" | "upcoming" | "attention"
}

export type LineStatus = "received" | "pending" | "exception"

export type ReceiveLine = {
  id: string
  itemId: string
  expected: number
  received: number
  bin: string
  status: LineStatus
  exception?: "shortage" | "overage" | "damaged" | "wrong-item"
}

export type PickLine = {
  id: string
  itemId: string
  expected: number
  picked: number
  bin: string
  status: LineStatus
}

export type CountLine = {
  id: string
  itemId: string
  expected: number
  counted: number
  bin: string
  status: LineStatus
  discrepancy?: boolean
}

export type SyncState = "local" | "queued" | "syncing" | "confirmed" | "failed" | "conflict" | "blocked" | "cancelled"

export type TxnKind = "receive" | "dispatch" | "count" | "adjust"
export type Transaction = {
  id: string
  kind: TxnKind
  ref: string
  itemId: string
  qty: string
  when: string
  sync: SyncState
  user?: string
  from?: string
  to?: string
}
