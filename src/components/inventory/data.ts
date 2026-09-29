/* ------------------------------------------------------------------ *
 * FieldOne · Inventory V2 fixtures
 *
 * One coherent story, document-driven. Every task maps to a document
 * (transfer / order / count sheet). Progress is owned by the task
 * (done/total) so Work, Home and the flow screens never contradict.
 *
 * Stock maths (consistent everywhere):
 *   Available = On hand − Reserved − Damaged − Blocked
 *   In transit is NOT part of On hand until received.
 *   Stock-by-location on-hand / reserved / damaged sum to the item totals.
 * ------------------------------------------------------------------ */

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

const thumb = (url: string) => `${url.split("?")[0]}?w=160&h=160&fit=crop&auto=format&q=70`

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

export const items: Item[] = [
  {
    id: "el-b-045",
    name: "Industrial LED Bulb 18W",
    sku: "EL-B-045",
    barcode: "EL-B-045",
    img: "/product-placeholder.svg",
    unit: "pcs",
    quantityScale: 0,
    quantityStep: 1,
    onHand: 42,
    available: 34,
    reserved: 6,
    inTransit: 12,
    damaged: 2,
    blocked: 0,
  },
  {
    id: "pvc-2-5",
    name: "PVC Cable 2.5mm",
    sku: "PVC-2.5",
    barcode: "PVC-2.5",
    img: "/product-placeholder.svg",
    unit: "rolls",
    quantityScale: 2,
    quantityStep: 0.25,
    onHand: 12,
    available: 7,
    reserved: 4,
    inTransit: 0,
    damaged: 0,
    blocked: 1,
  },
  {
    id: "jb-100",
    name: "Junction Box 100x100",
    sku: "JB-100",
    barcode: "JB-100",
    img: "/product-placeholder.svg",
    unit: "pcs",
    quantityScale: 0,
    quantityStep: 1,
    onHand: 6,
    available: 4,
    reserved: 2,
    inTransit: 0,
    damaged: 0,
    blocked: 0,
  },
  {
    id: "cb-32",
    name: "Circuit Breaker 32A",
    sku: "CB-32",
    barcode: "CB-32",
    img: "/product-placeholder.svg",
    unit: "pcs",
    quantityScale: 0,
    quantityStep: 1,
    onHand: 88,
    available: 78,
    reserved: 10,
    inTransit: 4,
    damaged: 0,
    blocked: 0,
  },
  {
    id: "cp-20",
    name: "Conduit Pipe 20mm",
    sku: "CP-20",
    barcode: "CP-20",
    img: "/product-placeholder.svg",
    unit: "bundles",
    quantityScale: 0,
    quantityStep: 1,
    onHand: 0,
    available: 0,
    reserved: 0,
    inTransit: 40,
    damaged: 0,
    blocked: 0,
  },
]

export const findItemById = (id: string, list: Item[] = items): Item | undefined => {
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

export const itemById = (id: string, list: Item[] = items): Item => {
  const found = findItemById(id, list)
  if (found) return found
  // Fixture fallback is permitted only when the caller is explicitly using the fixture list.
  // Live/empty production lists fail closed to an unknown zero-stock product.
  if (list === items) return findItemById(id, items) ?? unknownItem(id)
  return unknownItem(id)
}


export const resolveCode = (raw: string, list: Item[] = items): Item | undefined => {
  const q = raw.trim().toLowerCase().replace(/\s/g, "")
  if (!q) return undefined
  return (
    list.find(
      (i) =>
        i.sku.toLowerCase().replace(/\s/g, "") === q ||
        i.barcode.toLowerCase().replace(/\s/g, "") === q ||
        i.id.toLowerCase() === q ||
        itemSlugToUuid[i.id] === q ||
        i.sku.toLowerCase().includes(q) ||
        i.name.toLowerCase().includes(raw.trim().toLowerCase()),
    ) ??
    items.find(
      (i) =>
        i.sku.toLowerCase().replace(/\s/g, "") === q ||
        i.barcode.toLowerCase().replace(/\s/g, "") === q ||
        i.id.toLowerCase() === q ||
        itemSlugToUuid[i.id] === q ||
        i.sku.toLowerCase().includes(q) ||
        i.name.toLowerCase().includes(raw.trim().toLowerCase()),
    )
  )
}

/* ---------------- Location & user ---------------- */
export const location = { name: "Ikeja Central Warehouse", code: "WH-IKJ-01", city: "Lagos, NG" }
export const user = {
  name: "John Adeyemi",
  role: "Inventory Officer",
  avatar: "/avatar-placeholder.svg",
}

/* ---------------- Tasks (own the progress numbers) ---------------- */
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

/* NOTE: done/total below are derived from the documents' line status so Work,
 * Home and every flow reconcile. If a document changes, update it here too —
 * or read progress via taskProgress() which recomputes from the document. */
export const tasks: Task[] = [
  { id: "t-recv-291", kind: "receive", ref: "TR-00291", title: "Receive Transfer", where: "Main Depot → Ikeja Central", due: "Due 11:30", priority: "normal", done: 3, total: 4, status: "in-progress", group: "today" },
  { id: "t-disp-18420", kind: "dispatch", ref: "SO-18420", title: "Dispatch Order", where: "→ Lagos Main Branch", due: "Due 14:00", priority: "high", done: 3, total: 5, status: "in-progress", group: "today" },
  { id: "t-count-93", kind: "count", ref: "CC-0093", title: "Cycle Count", where: "Zone B · Aisle 2", due: "Due today", priority: "normal", done: 0, total: 3, status: "in-progress", group: "today" },
  { id: "t-recv-305", kind: "receive", ref: "TR-00305", title: "Receive Transfer", where: "Abuja Depot → Ikeja Central", due: "Tomorrow, 09:00", priority: "normal", done: 0, total: 2, status: "assigned", group: "upcoming" },
  { id: "t-count-95", kind: "count", ref: "CC-0095", title: "Cycle Count", where: "Zone C · Aisle 4", due: "Tomorrow", priority: "normal", done: 0, total: 2, status: "assigned", group: "upcoming" },
  { id: "t-disp-18402", kind: "dispatch", ref: "SO-18402", title: "Dispatch Order", where: "→ Ikorodu Site", due: "Overdue · was 09:00", priority: "high", done: 2, total: 3, status: "overdue", group: "attention" },
]

export const taskById = (id: string): Task | undefined => tasks.find((t) => t.id === id)
export const taskByRef = (ref: string) => tasks.find((t) => t.ref === ref)

/* ---------------- Line types ---------------- */
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
  requested: number
  picked: number
  available: number
  bin: string
  status: LineStatus
}

export type CountLine = { id: string; itemId: string; expected: number; bin: string }

/* ---------------- Document registry (keyed by task ref) ---------------- */
export type TransferDoc = { ref: string; from: string; to: string; assignee: string; due: string; lines: ReceiveLine[] }
export type OrderDoc = { ref: string; from: string; to: string; customer: string; due: string; priority: string; lines: PickLine[] }
export type CountDoc = { ref: string; zone: string; location: string; policy: string; lines: CountLine[] }

export const transferDocs: Record<string, TransferDoc> = {
  "TR-00291": {
    ref: "TR-00291",
    from: "Main Depot",
    to: "Ikeja Central Warehouse",
    assignee: "John Adeyemi",
    due: "14 Sep, 11:30",
    lines: [
      { id: "rl-1", itemId: "el-b-045", expected: 12, received: 12, bin: "B2-04", status: "received" },
      { id: "rl-2", itemId: "cb-32", expected: 4, received: 4, bin: "C3-02", status: "received" },
      { id: "rl-3", itemId: "pvc-2-5", expected: 6, received: 5, bin: "A1-11", status: "exception", exception: "shortage" },
      { id: "rl-4", itemId: "jb-100", expected: 2, received: 0, bin: "B2-06", status: "pending" },
    ],
  },
  "TR-00305": {
    ref: "TR-00305",
    from: "Abuja Depot",
    to: "Ikeja Central Warehouse",
    assignee: "John Adeyemi",
    due: "15 Sep, 09:00",
    lines: [
      { id: "rl305-1", itemId: "cp-20", expected: 40, received: 0, bin: "D1-01", status: "pending" },
      { id: "rl305-2", itemId: "cb-32", expected: 10, received: 0, bin: "C3-02", status: "pending" },
    ],
  },
}

export const orderDocs: Record<string, OrderDoc> = {
  "SO-18420": {
    ref: "SO-18420",
    from: "Ikeja Central Warehouse",
    to: "Lagos Main Branch",
    customer: "Lagos Main Branch",
    due: "Due today, 14:00",
    priority: "High priority",
    lines: [
      { id: "pl-1", itemId: "el-b-045", requested: 10, picked: 10, available: 34, bin: "B2-04", status: "received" },
      { id: "pl-2", itemId: "cb-32", requested: 6, picked: 6, available: 78, bin: "C3-02", status: "received" },
      { id: "pl-3", itemId: "jb-100", requested: 10, picked: 0, available: 4, bin: "B2-06", status: "exception" },
      { id: "pl-4", itemId: "pvc-2-5", requested: 3, picked: 0, available: 7, bin: "A1-11", status: "pending" },
      { id: "pl-5", itemId: "cp-20", requested: 5, picked: 0, available: 0, bin: "D1-01", status: "pending" },
    ],
  },
  "SO-18402": {
    ref: "SO-18402",
    from: "Ikeja Central Warehouse",
    to: "Ikorodu Site",
    customer: "Ikorodu Site",
    due: "Overdue · was 09:00",
    priority: "High priority",
    lines: [
      { id: "pl402-1", itemId: "cb-32", requested: 12, picked: 12, available: 78, bin: "C3-02", status: "received" },
      { id: "pl402-2", itemId: "el-b-045", requested: 8, picked: 4, available: 34, bin: "B2-04", status: "exception" },
      { id: "pl402-3", itemId: "pvc-2-5", requested: 4, picked: 0, available: 7, bin: "A1-11", status: "pending" },
    ],
  },
}

export const countDocs: Record<string, CountDoc> = {
  "CC-0093": {
    ref: "CC-0093",
    zone: "Zone B · Aisle 2",
    location: "Ikeja Central Warehouse",
    policy: "Blind count",
    lines: [
      { id: "cl-1", itemId: "el-b-045", expected: 12, bin: "B2-04" },
      { id: "cl-2", itemId: "cb-32", expected: 20, bin: "C3-02" },
      { id: "cl-3", itemId: "jb-100", expected: 6, bin: "B2-06" },
    ],
  },
  "CC-0095": {
    ref: "CC-0095",
    zone: "Zone C · Aisle 4",
    location: "Ikeja Central Warehouse",
    policy: "Blind count",
    lines: [
      { id: "cl95-1", itemId: "pvc-2-5", expected: 12, bin: "A1-11" },
      { id: "cl95-2", itemId: "cp-20", expected: 0, bin: "D1-01" },
    ],
  },
}

/* progress helpers derive everything from the document lines, so the visible
 * lines, matched/exception/pending counts and overall progress always reconcile */
export function receiveProgress(doc: TransferDoc) {
  const lines = doc?.lines ?? []
  const matched = lines.filter((l) => l.status === "received").length
  const exceptions = lines.filter((l) => l.status === "exception").length
  const pending = lines.filter((l) => l.status === "pending").length
  return { matched, exceptions, pending, done: matched + exceptions, total: lines.length }
}
export function dispatchProgress(doc: OrderDoc) {
  const lines = doc?.lines ?? []
  const picked = lines.filter((l) => l.status === "received").length
  const exceptions = lines.filter((l) => l.status === "exception").length
  const pending = lines.filter((l) => l.status === "pending").length
  return { picked, exceptions, pending, done: picked + exceptions, total: lines.length }
}

/* single source of task progress for Home / Work rows — recomputed from the doc */
export function taskProgress(task: Task): { done: number; total: number } {
  if (task.kind === "receive" && transferDocs[task.ref]) {
    const p = receiveProgress(transferDocs[task.ref])
    return { done: p.done, total: p.total }
  }
  if (task.kind === "dispatch" && orderDocs[task.ref]) {
    const p = dispatchProgress(orderDocs[task.ref])
    return { done: p.done, total: p.total }
  }
  if (task.kind === "count" && countDocs[task.ref]) {
    // blind count: progress is what the worker has confirmed (task.done owns it)
    return { done: task.done, total: countDocs[task.ref].lines.length }
  }
  return { done: task.done, total: task.total }
}

const fallbackReceiveLine: ReceiveLine = { id: "rl-fallback", itemId: "el-b-045", expected: 1, received: 0, bin: "B2-04", status: "pending" }
const fallbackPickLine: PickLine = { id: "pl-fallback", itemId: "el-b-045", requested: 1, picked: 0, available: 1, bin: "B2-04", status: "pending" }

/* first line a scan should resolve to for a document (next actionable line) */
export const nextReceiveLine = (doc: TransferDoc): ReceiveLine =>
  (doc?.lines && doc.lines.length > 0)
    ? (doc.lines.find((l) => l.status === "pending") ?? doc.lines.find((l) => l.status === "exception") ?? doc.lines[0])
    : fallbackReceiveLine

export const nextPickLine = (doc: OrderDoc): PickLine =>
  (doc?.lines && doc.lines.length > 0)
    ? (doc.lines.find((l) => l.status === "exception") ?? doc.lines.find((l) => l.status === "pending") ?? doc.lines[0])
    : fallbackPickLine

/* ---------------- Sync operations (seed; App mutates a copy) ---------------- */
export type SyncState = "local" | "queued" | "syncing" | "confirmed" | "failed" | "conflict" | "blocked" | "cancelled"
export type SyncOp = { id: string; kind: "receive" | "dispatch" | "count" | "adjust"; ref: string; label: string; when: string; state: SyncState }

export const seedSyncOps: SyncOp[] = [
  { id: "s-4", kind: "adjust", ref: "ADJ-0021", label: "Adjustment", when: "Needs review", state: "conflict" },
  { id: "s-5", kind: "receive", ref: "TR-00284", label: "Receipt", when: "Failed 09:12", state: "failed" },
  { id: "s-6", kind: "count", ref: "CC-0088", label: "Cycle count", when: "Confirmed 08:40", state: "confirmed" },
]

/* ---------------- Stock by location (reconciles to item totals) ---------------- */
type LocRow = { loc: string; bin: string; onHand: number; available: number; reserved: number; damaged: number }

export const stockByLocation: Record<string, LocRow[]> = {
  "el-b-045": [
    // onHand 30+8+4 = 42; reserved 6+0+0 = 6; damaged 2+0+0 = 2; available 22+8+4 = 34
    { loc: "Ikeja Central Warehouse", bin: "B2-04", onHand: 30, available: 22, reserved: 6, damaged: 2 },
    { loc: "Lagos Main Branch", bin: "A1-11", onHand: 8, available: 8, reserved: 0, damaged: 0 },
    { loc: "Abuja Depot", bin: "C3-02", onHand: 4, available: 4, reserved: 0, damaged: 0 },
  ],
}

export const itemStock = (id: string): LocRow[] => {
  const slug = itemUuidToSlug[id] ?? id
  if (stockByLocation[slug]) return stockByLocation[slug]
  if (stockByLocation[id]) return stockByLocation[id]
  return [{ loc: location.name, bin: "B2-04", onHand: 0, available: 0, reserved: 0, damaged: 0 }]
}

/* ---------------- Movements per item (carry sync state) ---------------- */
export const movements: Record<string, { type: string; ref: string; qty: string; when: string; sync: SyncState }[]> = {
  "el-b-045": [
    { type: "Received", ref: "TR-00291", qty: "+12", when: "Today, 11:04", sync: "local" },
    { type: "Dispatched", ref: "SO-18420", qty: "−10", when: "Today, 10:58", sync: "syncing" },
    { type: "Cycle count adj.", ref: "CC-0088", qty: "−2", when: "Yesterday, 08:40", sync: "confirmed" },
    { type: "Received (failed)", ref: "TR-00284", qty: "+20", when: "Yesterday, 15:30", sync: "failed" },
  ],
}
export const itemMovements = (id: string) => {
  const slug = itemUuidToSlug[id] ?? id
  return (
    movements[slug] ??
    movements[id] ?? [
      { type: "Received", ref: "TR-00291", qty: "+8", when: "Today, 11:04", sync: "local" as SyncState },
      { type: "Dispatched", ref: "SO-18410", qty: "−4", when: "Yesterday, 16:40", sync: "confirmed" as SyncState },
    ]
  )
}

/* related work for an item (document-driven; no arbitrary ops from Item Detail) */
export const relatedTasksForItem = (id: string) => {
  const slug = itemUuidToSlug[id] ?? id
  return tasks.filter((t) => {
    if (t.kind === "receive") return transferDocs[t.ref]?.lines.some((l) => l.itemId === slug || l.itemId === id)
    if (t.kind === "dispatch") return orderDocs[t.ref]?.lines.some((l) => l.itemId === slug || l.itemId === id)
    return countDocs[t.ref]?.lines.some((l) => l.itemId === slug || l.itemId === id)
  })
}

/* ---------------- Transaction history (audit trail) ---------------- */
export type TxnKind = "receive" | "dispatch" | "count" | "adjust"
export type Transaction = { id: string; kind: TxnKind; ref: string; itemId: string; qty: string; from?: string; to?: string; user: string; when: string; sync: SyncState }

export const transactions: Transaction[] = [
  { id: "tx-1", kind: "receive", ref: "TR-00291", itemId: "el-b-045", qty: "+12", from: "Main Depot", to: location.name, user: "John Adeyemi", when: "Today, 11:04", sync: "local" },
  { id: "tx-2", kind: "dispatch", ref: "SO-18420", itemId: "el-b-045", qty: "−10", from: location.name, to: "Lagos Main Branch", user: "John Adeyemi", when: "Today, 10:58", sync: "syncing" },
  { id: "tx-3", kind: "count", ref: "CC-0093", itemId: "jb-100", qty: "0", from: "Zone B · Aisle 2", user: "John Adeyemi", when: "Today, 10:45", sync: "queued" },
  { id: "tx-4", kind: "adjust", ref: "ADJ-0021", itemId: "el-b-045", qty: "−3", from: location.name, user: "John Adeyemi", when: "Today, 10:20", sync: "conflict" },
  { id: "tx-5", kind: "receive", ref: "TR-00284", itemId: "el-b-045", qty: "+20", from: "Abuja Depot", to: location.name, user: "S. Okafor", when: "Yesterday, 15:30", sync: "failed" },
  { id: "tx-6", kind: "count", ref: "CC-0088", itemId: "el-b-045", qty: "−2", from: "Zone B · Aisle 2", user: "S. Okafor", when: "Yesterday, 08:40", sync: "confirmed" },
  { id: "tx-7", kind: "dispatch", ref: "SO-18410", itemId: "cb-32", qty: "−8", from: location.name, to: "Ikorodu Site", user: "John Adeyemi", when: "12 Sep, 16:40", sync: "confirmed" },
]

export const txnById = (id: string) => transactions.find((t) => t.id === id) ?? transactions[0]
