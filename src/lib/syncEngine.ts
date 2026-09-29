import localforage from "localforage"
import { supabase } from "./supabase"
import {
  createSalesOrderBackorder,
  decideCountVariance,
  dispatchSalesOrder,
  fetchCountSessionDocument,
  fetchSalesOrderDocument,
  fetchTransferDocument,
  finalizeCountSession,
  getDocumentCommandResult,
  receiveTransferDocument,
  recordCountObservation,
  recordSalesOrderPickLine,
  recordTransferReceiptLine,
  reportUnknownInventoryScan,
  resolveTransferReceiptException,
  shipTransferDocument,
  type DocumentCommandResult,
  type StockRevisionPrecondition,
} from "./documents"
import { replaceWorkflowCommandReference, setLastConfirmedAt, type OfflineOwner } from "./offlineStore"
import { storageGet, storageIterate, storageRemove, storageSet } from "./durableStorage"

export type QueueOwner = OfflineOwner


export type OutboxState = "queued" | "syncing" | "confirmed" | "failed" | "conflict" | "blocked" | "cancelled"
export type OutboxErrorKind = "transient" | "validation" | "authorization" | "conflict" | "dependency" | "storage" | "unknown"

export type OutboxLastError = {
  kind: OutboxErrorKind
  code: string | null
  message: string
  at: string
}

export type OutboxCommandKind =
  | "transfer_line_capture"
  | "sales_line_capture"
  | "sales_backorder"
  | "count_observation"
  | "count_variance_reason"
  | "count_decision"
  | "transfer_ship"
  | "transfer_receive"
  | "sales_dispatch"
  | "count_finalize"
  | "unknown_scan_report"
  | "transfer_exception_disposition"

export type OutboxPayloadMap = {
  transfer_line_capture: {
    lineId: string
    documentId: string
    expectedRevision: number
    receivedQuantity: number
    unitId: string
    destinationBinId: string
    exceptionCode?: string | null
    exceptionNotes?: string | null
    clientRecordedAt: string
  }
  sales_line_capture: {
    lineId: string
    documentId: string
    expectedRevision: number
    pickedQuantity: number
    unitId: string
    sourceBinId: string
    exceptionCode?: string | null
    exceptionNotes?: string | null
    clientRecordedAt: string
  }
  sales_backorder: {
    lineId: string
    documentId: string
    expectedRevision: number
    baseQuantity: number
    reasonCode: string
    reasonText?: string | null
  }
  count_observation: {
    lineId: string
    documentId: string
    expectedRevision: number
    observedQuantity: number
    unitId: string
    reasonCode?: string | null
    notes?: string | null
    clientRecordedAt: string
  }
  count_variance_reason: {
    observationId: string
    documentId: string
    expectedRevision: number
    reasonCode: string
    notes?: string | null
  }
  count_decision: {
    observationId: string
    documentId: string
    expectedRevision: number
    decision: "APPROVED" | "REJECTED" | "RECOUNT"
    reason?: string | null
  }
  transfer_ship: { documentId: string; expectedRevision: number; commandId: string; clientRecordedAt: string; stockPreconditions: StockRevisionPrecondition[] }
  transfer_receive: { documentId: string; expectedRevision: number; commandId: string; allowPartial: boolean; clientRecordedAt: string; stockPreconditions: StockRevisionPrecondition[] }
  sales_dispatch: { documentId: string; expectedRevision: number; commandId: string; clientRecordedAt: string; stockPreconditions: StockRevisionPrecondition[] }
  count_finalize: { documentId: string; expectedRevision: number; commandId: string; clientRecordedAt: string; stockPreconditions: StockRevisionPrecondition[] }
  unknown_scan_report: { rawCode: string; context: "browse" | "receive" | "dispatch"; documentType?: "TRANSFER" | "SALES_ORDER" | null; documentId?: string | null }
  transfer_exception_disposition: {
    lineId: string
    documentId: string
    expectedRevision: number
    commandId: string
    disposition: "ACCEPT_DAMAGED" | "REJECT_WRONG_ITEM" | "REJECT_UNEXPECTED" | "ACCEPT_EXPECTED_REJECT_OVERAGE"
    reasonText: string
    clientRecordedAt: string
  }
}

export type QueuedOperation<K extends OutboxCommandKind = OutboxCommandKind> = {
  schemaVersion: 2
  id: string
  owner: QueueOwner
  kind: K
  ref: string
  label: string
  documentId: string | null
  createdAt: string
  clientRecordedAt: string
  state: OutboxState
  payload: OutboxPayloadMap[K]
  dependencyIds: string[]
  attemptCount: number
  nextAttemptAt: string | null
  lastError: OutboxLastError | null
  leaseOwner: string | null
  leaseExpiresAt: string | null
  confirmedAt: string | null
  serverResult: unknown | null
}

export type LegacyQuarantineRecord = {
  schemaVersion: 1
  id: string
  quarantinedAt: string
  reason: string
  legacyValue: unknown
}

const outbox = localforage.createInstance({ name: "FieldOneOffline", storeName: "OutboxV2" })
const meta = localforage.createInstance({ name: "FieldOneOffline", storeName: "OutboxMetaV2" })
const quarantine = localforage.createInstance({ name: "FieldOneOffline", storeName: "LegacyQuarantineV1" })
const legacyQueueStore = localforage.createInstance({ name: "FieldOne", storeName: "SyncQueue" })

const LEGACY_QUEUE_KEY = "fieldone_sync_queue"
const LEGACY_MIGRATED_KEY = "legacy-v1-migrated"
const LEASE_MS = 30_000
const MAX_RETRY_DELAY_MS = 5 * 60_000
const RPC_TIMEOUT_MS = 20_000
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const workerId = typeof crypto !== "undefined" && "randomUUID" in crypto ? crypto.randomUUID() : `worker-${Date.now()}`

const channel = typeof BroadcastChannel !== "undefined" ? new BroadcastChannel("fieldone-outbox-v2") : null

function ownerKey(owner: QueueOwner) {
  return `${owner.authUserId}:${owner.companyId}:${owner.locationId}`
}

function sameOwner(operation: QueuedOperation, owner: QueueOwner) {
  return operation.owner.authUserId === owner.authUserId && operation.owner.companyId === owner.companyId && operation.owner.locationId === owner.locationId
}

function notify(owner?: QueueOwner) {
  channel?.postMessage({ type: "outbox-change", owner: owner ? ownerKey(owner) : null, at: Date.now() })
}

export function subscribeOutbox(owner: QueueOwner, callback: () => void) {
  if (!channel) return () => undefined
  const key = ownerKey(owner)
  const handler = (event: MessageEvent) => {
    const data = event.data as { type?: string; owner?: string | null } | null
    if (data?.type === "outbox-change" && (!data.owner || data.owner === key)) callback()
  }
  channel.addEventListener("message", handler)
  return () => channel.removeEventListener("message", handler)
}

export async function migrateLegacyQueueOnce() {
  if ((await storageGet<boolean>(meta, LEGACY_MIGRATED_KEY)) === true) return
  const legacy = await storageGet<unknown[]>(legacyQueueStore, LEGACY_QUEUE_KEY)
  if (Array.isArray(legacy) && legacy.length > 0) {
    for (const value of legacy) {
      const record = value && typeof value === "object" ? (value as { id?: unknown }) : null
      const id = typeof record?.id === "string" && record.id ? record.id : crypto.randomUUID()
      const quarantined: LegacyQuarantineRecord = {
        schemaVersion: 1,
        id: `legacy-${id}`,
        quarantinedAt: new Date().toISOString(),
        reason: "Legacy whole-array queue schema cannot prove authoritative document-command identity; preserved for reconciliation and never auto-submitted.",
        legacyValue: value,
      }
      await storageSet(quarantine, quarantined.id, quarantined)
    }
    await storageRemove(legacyQueueStore, LEGACY_QUEUE_KEY)
  }
  await storageSet(meta, LEGACY_MIGRATED_KEY, true)
  notify()
}

export async function listQuarantinedLegacyRecords() {
  const result: LegacyQuarantineRecord[] = []
  await storageIterate<LegacyQuarantineRecord>(quarantine, (value) => {
    if (value?.schemaVersion === 1) result.push(value)
  })
  return result.sort((a, b) => a.quarantinedAt.localeCompare(b.quarantinedAt))
}

const OUTBOX_KINDS: OutboxCommandKind[] = [
  "transfer_line_capture",
  "sales_line_capture",
  "sales_backorder",
  "count_observation",
  "count_variance_reason",
  "count_decision",
  "transfer_ship",
  "transfer_receive",
  "sales_dispatch",
  "count_finalize",
  "unknown_scan_report",
  "transfer_exception_disposition",
]
const OUTBOX_STATES: OutboxState[] = ["queued", "syncing", "confirmed", "failed", "conflict", "blocked", "cancelled"]

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function isIsoTimestamp(value: unknown): value is string {
  return typeof value === "string" && Number.isFinite(Date.parse(value))
}

function isNullableTimestamp(value: unknown): value is string | null {
  return value === null || isIsoTimestamp(value)
}

function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value)
}

function validOwner(value: unknown): value is QueueOwner {
  if (!isRecord(value)) return false
  return isUuid(value.authUserId) && isUuid(value.companyId) && isUuid(value.locationId)
}

function validCapturePayload(payload: Record<string, unknown>, kind: "transfer_line_capture" | "sales_line_capture" | "count_observation") {
  if (!isUuid(payload.lineId) || !isUuid(payload.documentId) || !Number.isInteger(payload.expectedRevision) || (payload.expectedRevision as number) < 0) return false
  if (!isUuid(payload.unitId) || !isIsoTimestamp(payload.clientRecordedAt)) return false
  if (kind === "transfer_line_capture") return typeof payload.receivedQuantity === "number" && Number.isFinite(payload.receivedQuantity) && (payload.receivedQuantity as number) >= 0 && isUuid(payload.destinationBinId)
  if (kind === "sales_line_capture") return typeof payload.pickedQuantity === "number" && Number.isFinite(payload.pickedQuantity) && (payload.pickedQuantity as number) >= 0 && isUuid(payload.sourceBinId)
  return typeof payload.observedQuantity === "number" && Number.isFinite(payload.observedQuantity) && (payload.observedQuantity as number) >= 0
}

function validStockPreconditions(value: unknown): value is StockRevisionPrecondition[] {
  if (!Array.isArray(value) || value.length === 0) return false
  return value.every((entry) => isRecord(entry)
    && isUuid(entry.locationId) && isUuid(entry.binId) && isUuid(entry.productId)
    && ["AVAILABLE", "DAMAGED", "BLOCKED"].includes(String(entry.inventoryStatus))
    && Number.isInteger(entry.physicalRevision) && (entry.physicalRevision as number) >= 0
    && Number.isInteger(entry.binReservationRevision) && (entry.binReservationRevision as number) >= 0
    && Number.isInteger(entry.locationReservationRevision) && (entry.locationReservationRevision as number) >= 0)
}

function validPayload(kind: OutboxCommandKind, value: unknown) {
  if (!isRecord(value)) return false
  switch (kind) {
    case "transfer_line_capture":
    case "sales_line_capture":
    case "count_observation":
      return validCapturePayload(value, kind)
    case "sales_backorder":
      return isUuid(value.lineId) && isUuid(value.documentId) && Number.isInteger(value.expectedRevision) && (value.expectedRevision as number) >= 0 && typeof value.baseQuantity === "number" && Number.isFinite(value.baseQuantity) && (value.baseQuantity as number) > 0 && typeof value.reasonCode === "string" && value.reasonCode.length > 0
    case "count_variance_reason":
      return isUuid(value.observationId) && isUuid(value.documentId) && Number.isInteger(value.expectedRevision) && (value.expectedRevision as number) >= 0 && typeof value.reasonCode === "string" && value.reasonCode.length > 0
    case "count_decision":
      return isUuid(value.observationId) && isUuid(value.documentId) && Number.isInteger(value.expectedRevision) && (value.expectedRevision as number) >= 0 && ["APPROVED", "REJECTED", "RECOUNT"].includes(String(value.decision))
    case "transfer_ship":
    case "sales_dispatch":
      return isUuid(value.documentId) && Number.isInteger(value.expectedRevision) && (value.expectedRevision as number) >= 0 && isUuid(value.commandId) && isIsoTimestamp(value.clientRecordedAt) && validStockPreconditions(value.stockPreconditions)
    case "count_finalize":
      return isUuid(value.documentId) && Number.isInteger(value.expectedRevision) && (value.expectedRevision as number) >= 0 && isUuid(value.commandId) && isIsoTimestamp(value.clientRecordedAt) && validStockPreconditions(value.stockPreconditions)
    case "transfer_receive":
      return isUuid(value.documentId) && Number.isInteger(value.expectedRevision) && (value.expectedRevision as number) >= 0 && isUuid(value.commandId) && typeof value.allowPartial === "boolean" && isIsoTimestamp(value.clientRecordedAt) && validStockPreconditions(value.stockPreconditions)
    case "transfer_exception_disposition":
      return isUuid(value.lineId) && isUuid(value.documentId) && Number.isInteger(value.expectedRevision) && (value.expectedRevision as number) >= 0 && isUuid(value.commandId) && ["ACCEPT_DAMAGED", "REJECT_WRONG_ITEM", "REJECT_UNEXPECTED", "ACCEPT_EXPECTED_REJECT_OVERAGE"].includes(String(value.disposition)) && typeof value.reasonText === "string" && value.reasonText.trim().length > 0 && isIsoTimestamp(value.clientRecordedAt)
    case "unknown_scan_report":
      return typeof value.rawCode === "string" && typeof value.context === "string"
  }
}

function parseOutboxRecord(value: unknown): QueuedOperation | null {
  if (!isRecord(value) || value.schemaVersion !== 2 || !isUuid(value.id) || !validOwner(value.owner)) return null
  if (typeof value.kind !== "string" || !OUTBOX_KINDS.includes(value.kind as OutboxCommandKind)) return null
  if (typeof value.state !== "string" || !OUTBOX_STATES.includes(value.state as OutboxState)) return null
  if (typeof value.ref !== "string" || typeof value.label !== "string") return null
  if (!(value.documentId === null || isUuid(value.documentId))) return null
  if (!isIsoTimestamp(value.createdAt) || !isIsoTimestamp(value.clientRecordedAt)) return null
  if (!Array.isArray(value.dependencyIds) || !value.dependencyIds.every(isUuid)) return null
  if (!Number.isInteger(value.attemptCount) || (value.attemptCount as number) < 0) return null
  if (!isNullableTimestamp(value.nextAttemptAt) || !isNullableTimestamp(value.leaseExpiresAt) || !isNullableTimestamp(value.confirmedAt)) return null
  if (!(value.leaseOwner === null || typeof value.leaseOwner === "string")) return null
  if (!(value.lastError === null || (isRecord(value.lastError) && typeof value.lastError.kind === "string" && typeof value.lastError.message === "string" && isIsoTimestamp(value.lastError.at)))) return null
  if (!validPayload(value.kind as OutboxCommandKind, value.payload)) return null
  return value as unknown as QueuedOperation
}

async function quarantineInvalidV2(key: string, value: unknown) {
  const record: LegacyQuarantineRecord = {
    schemaVersion: 1,
    id: `invalid-v2-${key}-${Date.now()}`,
    quarantinedAt: new Date().toISOString(),
    reason: "Malformed or incompatible OutboxV2 record failed runtime validation; preserved for reconciliation and removed from executable outbox.",
    legacyValue: value,
  }
  await storageSet(quarantine, record.id, record)
  await storageRemove(outbox, key)
}

export async function getQueue(): Promise<QueuedOperation[]> {
  await migrateLegacyQueueOnce()
  const result: QueuedOperation[] = []
  const invalid: Array<{ key: string; value: unknown }> = []
  await storageIterate<unknown>(outbox, (value, key) => {
    const parsed = parseOutboxRecord(value)
    if (parsed) result.push(parsed)
    else invalid.push({ key, value })
  })
  for (const entry of invalid) await quarantineInvalidV2(entry.key, entry.value)
  return result.sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id))
}

export async function getQueueForOwner(owner: QueueOwner) {
  const queue = await getQueue()
  return queue.filter((operation) => sameOwner(operation, owner))
}

async function putOperation(operation: QueuedOperation) {
  await storageSet(outbox, operation.id, operation)
  notify(operation.owner)
  return operation
}

export async function enqueueCommand<K extends OutboxCommandKind>(input: {
  id: string
  owner: QueueOwner
  kind: K
  ref: string
  label: string
  documentId?: string | null
  clientRecordedAt: string
  payload: OutboxPayloadMap[K]
  dependencyIds?: string[]
}) {
  if (!UUID_RE.test(input.id)) throw new Error("Outbox command id must be a stable UUID created with the business action")
  const existing = await storageGet<QueuedOperation>(outbox, input.id)
  if (existing) {
    if (!sameOwner(existing, input.owner) || existing.kind !== input.kind || existing.ref !== input.ref) {
      throw new Error("Stable outbox command id is already owned by different immutable command content")
    }
    return existing
  }

  const operation: QueuedOperation<K> = {
    schemaVersion: 2,
    id: input.id,
    owner: input.owner,
    kind: input.kind,
    ref: input.ref,
    label: input.label,
    documentId: input.documentId ?? null,
    createdAt: new Date().toISOString(),
    clientRecordedAt: input.clientRecordedAt,
    state: "queued",
    payload: input.payload,
    dependencyIds: [...new Set(input.dependencyIds ?? [])],
    attemptCount: 0,
    nextAttemptAt: null,
    lastError: null,
    leaseOwner: null,
    leaseExpiresAt: null,
    confirmedAt: null,
    serverResult: null,
  }
  await putOperation(operation as QueuedOperation)
  return operation
}

function parseRpcError(error: unknown): { code: string | null; message: string } {
  if (error && typeof error === "object") {
    const record = error as { code?: unknown; message?: unknown; details?: unknown }
    return {
      code: typeof record.code === "string" ? record.code : null,
      message: typeof record.message === "string" ? record.message : typeof record.details === "string" ? record.details : String(error),
    }
  }
  return { code: null, message: error instanceof Error ? error.message : String(error) }
}

function classifyError(error: unknown): OutboxLastError {
  const { code, message } = parseRpcError(error)
  const lower = message.toLowerCase()
  let kind: OutboxErrorKind = "unknown"
  if (code === "42501" || lower.includes("permission") || lower.includes("authenticated")) kind = "authorization"
  else if (code === "40001" || lower.includes("revision conflict") || lower.includes("conflict")) kind = "conflict"
  else if (code === "22023" || code === "P0002" || lower.includes("invalid") || lower.includes("required") || lower.includes("immutable")) kind = "validation"
  else if (!code || code.startsWith("08") || code === "57014" || lower.includes("network") || lower.includes("timeout") || lower.includes("fetch")) kind = "transient"
  return { kind, code, message, at: new Date().toISOString() }
}

function retryDelay(attemptCount: number) {
  const exponent = Math.min(8, Math.max(0, attemptCount - 1))
  const base = Math.min(MAX_RETRY_DELAY_MS, 1_000 * 2 ** exponent)
  const jitter = Math.floor(Math.random() * Math.max(250, Math.floor(base * 0.2)))
  return Math.min(MAX_RETRY_DELAY_MS, base + jitter)
}

function due(operation: QueuedOperation) {
  if (!operation.nextAttemptAt) return true
  return new Date(operation.nextAttemptAt).getTime() <= Date.now()
}

function terminal(operation: QueuedOperation) {
  return operation.state === "confirmed" || operation.state === "cancelled"
}

function active(operation: QueuedOperation) {
  return !terminal(operation)
}

async function recoverStaleClaims(owner: QueueOwner) {
  const queue = await getQueueForOwner(owner)
  const now = Date.now()
  for (const operation of queue) {
    if (operation.state !== "syncing") continue
    const expires = operation.leaseExpiresAt ? new Date(operation.leaseExpiresAt).getTime() : 0
    if (expires > now) continue
    await putOperation({
      ...operation,
      state: "queued",
      leaseOwner: null,
      leaseExpiresAt: null,
      nextAttemptAt: null,
      lastError: { kind: "transient", code: "STALE_LEASE", message: "Recovered command whose processing lease expired after interruption.", at: new Date().toISOString() },
    })
  }
}

async function claim(operation: QueuedOperation) {
  const current = await storageGet<QueuedOperation>(outbox, operation.id)
  if (!current || terminal(current) || current.state === "conflict" || current.state === "blocked") return null
  const now = Date.now()
  if (current.state === "syncing" && current.leaseExpiresAt && new Date(current.leaseExpiresAt).getTime() > now && current.leaseOwner !== workerId) return null
  const claimed: QueuedOperation = {
    ...current,
    state: "syncing",
    attemptCount: current.attemptCount + 1,
    nextAttemptAt: null,
    leaseOwner: workerId,
    leaseExpiresAt: new Date(now + LEASE_MS).toISOString(),
  }
  await putOperation(claimed)
  return claimed
}

function rawRecord(value: unknown) {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : null
}

async function reconcileCapture(operation: QueuedOperation): Promise<unknown | null> {
  if (operation.kind === "transfer_line_capture") {
    const payload = operation.payload as OutboxPayloadMap["transfer_line_capture"]
    const doc = await fetchTransferDocument(payload.documentId)
    const line = doc?.lines.find((entry) => entry.id === payload.lineId)
    if (line && line.capturedReceivedBaseQuantity === payload.receivedQuantity && (line.exceptionCode ?? null) === (payload.exceptionCode ?? null)) {
      return { reconciled: true, document_revision: doc!.revision, line_id: line.id }
    }
  }
  if (operation.kind === "sales_line_capture") {
    const payload = operation.payload as OutboxPayloadMap["sales_line_capture"]
    const doc = await fetchSalesOrderDocument(payload.documentId)
    const line = doc?.lines.find((entry) => entry.id === payload.lineId)
    if (line && line.capturedPickedBaseQuantity === payload.pickedQuantity && (line.exceptionCode ?? null) === (payload.exceptionCode ?? null)) {
      return { reconciled: true, document_revision: doc!.revision, line_id: line.id }
    }
  }
  if (operation.kind === "sales_backorder") {
    const payload = operation.payload as OutboxPayloadMap["sales_backorder"]
    const doc = await fetchSalesOrderDocument(payload.documentId)
    const line = doc?.lines.find((entry) => entry.id === payload.lineId)
    if (line && line.backorderedBaseQuantity >= payload.baseQuantity) return { reconciled: true, document_revision: doc!.revision, line_id: line.id }
  }
  if (operation.kind === "count_observation") {
    const payload = operation.payload as OutboxPayloadMap["count_observation"]
    const doc = await fetchCountSessionDocument(payload.documentId)
    const line = doc?.lines.find((entry) => entry.id === payload.lineId)
    if (line && line.observedBaseQuantity === payload.observedQuantity && (line.reasonCode ?? null) === (payload.reasonCode ?? null)) {
      return { reconciled: true, session_revision: doc!.revision, line_id: line.id, observation_id: line.latestObservationId }
    }
  }
  if (operation.kind === "count_variance_reason") {
    const payload = operation.payload as OutboxPayloadMap["count_variance_reason"]
    const doc = await fetchCountSessionDocument(payload.documentId)
    const line = doc?.lines.find((entry) => entry.latestObservationId === payload.observationId)
    if (line && line.reasonCode === payload.reasonCode) return { reconciled: true, session_revision: doc!.revision, line_id: line.id }
  }
  if (operation.kind === "count_decision") {
    const payload = operation.payload as OutboxPayloadMap["count_decision"]
    const doc = await fetchCountSessionDocument(payload.documentId)
    const line = doc?.lines.find((entry) => entry.latestObservationId === payload.observationId)
    if (line && line.approvalDecision === payload.decision) return { reconciled: true, session_revision: doc!.revision, line_id: line.id }
  }
  return null
}

async function executeDocumentResult(result: DocumentCommandResult) {
  if (result.outcome === "accepted" || result.outcome === "duplicate") return { disposition: "confirmed" as const, result }
  if (result.outcome === "conflict") return { disposition: "conflict" as const, result }
  if (result.outcome === "validation_error" || result.outcome === "authorization_error") return { disposition: "blocked" as const, result }
  return { disposition: "retry" as const, result }
}

async function execute(operation: QueuedOperation) {
  switch (operation.kind) {
    case "transfer_line_capture": {
      const p = operation.payload as OutboxPayloadMap["transfer_line_capture"]
      return { disposition: "confirmed" as const, result: await recordTransferReceiptLine({ lineId: p.lineId, documentRevision: p.expectedRevision, receivedQuantity: p.receivedQuantity, unitId: p.unitId, destinationBinId: p.destinationBinId, exceptionCode: p.exceptionCode, exceptionNotes: p.exceptionNotes, clientRecordedAt: p.clientRecordedAt }) }
    }
    case "sales_line_capture": {
      const p = operation.payload as OutboxPayloadMap["sales_line_capture"]
      return { disposition: "confirmed" as const, result: await recordSalesOrderPickLine({ lineId: p.lineId, documentRevision: p.expectedRevision, pickedQuantity: p.pickedQuantity, unitId: p.unitId, sourceBinId: p.sourceBinId, exceptionCode: p.exceptionCode, exceptionNotes: p.exceptionNotes, clientRecordedAt: p.clientRecordedAt }) }
    }
    case "sales_backorder": {
      const p = operation.payload as OutboxPayloadMap["sales_backorder"]
      return { disposition: "confirmed" as const, result: await createSalesOrderBackorder({ lineId: p.lineId, documentRevision: p.expectedRevision, baseQuantity: p.baseQuantity, reasonCode: p.reasonCode, reasonText: p.reasonText }) }
    }
    case "count_observation": {
      const p = operation.payload as OutboxPayloadMap["count_observation"]
      return { disposition: "confirmed" as const, result: await recordCountObservation({ lineId: p.lineId, sessionRevision: p.expectedRevision, observedQuantity: p.observedQuantity, unitId: p.unitId, reasonCode: p.reasonCode, notes: p.notes, clientRecordedAt: p.clientRecordedAt }) }
    }
    case "count_variance_reason": {
      const p = operation.payload as OutboxPayloadMap["count_variance_reason"]
      const { data, error } = await supabase.rpc("set_count_variance_reason", {
        p_observation_id: p.observationId,
        p_expected_session_revision: p.expectedRevision,
        p_reason_code: p.reasonCode,
        p_notes: p.notes ?? null,
      })
      if (error) throw error
      return { disposition: "confirmed" as const, result: data }
    }
    case "count_decision": {
      const p = operation.payload as OutboxPayloadMap["count_decision"]
      return { disposition: "confirmed" as const, result: await decideCountVariance({ observationId: p.observationId, sessionRevision: p.expectedRevision, decision: p.decision, reason: p.reason }) }
    }
    case "transfer_ship": {
      const p = operation.payload as OutboxPayloadMap["transfer_ship"]
      return executeDocumentResult(await shipTransferDocument({ documentId: p.documentId, documentRevision: p.expectedRevision, commandId: p.commandId, clientRecordedAt: p.clientRecordedAt, stockPreconditions: p.stockPreconditions }))
    }
    case "transfer_receive": {
      const p = operation.payload as OutboxPayloadMap["transfer_receive"]
      return executeDocumentResult(await receiveTransferDocument({ documentId: p.documentId, documentRevision: p.expectedRevision, commandId: p.commandId, allowPartial: p.allowPartial, clientRecordedAt: p.clientRecordedAt, stockPreconditions: p.stockPreconditions }))
    }
    case "sales_dispatch": {
      const p = operation.payload as OutboxPayloadMap["sales_dispatch"]
      return executeDocumentResult(await dispatchSalesOrder({ documentId: p.documentId, documentRevision: p.expectedRevision, commandId: p.commandId, clientRecordedAt: p.clientRecordedAt, stockPreconditions: p.stockPreconditions }))
    }
    case "count_finalize": {
      const p = operation.payload as OutboxPayloadMap["count_finalize"]
      return executeDocumentResult(await finalizeCountSession({ documentId: p.documentId, documentRevision: p.expectedRevision, commandId: p.commandId, clientRecordedAt: p.clientRecordedAt, stockPreconditions: p.stockPreconditions }))
    }
    case "unknown_scan_report": {
      const p = operation.payload as OutboxPayloadMap["unknown_scan_report"]
      return { disposition: "confirmed" as const, result: await reportUnknownInventoryScan({
        clientEventId: operation.id, locationId: operation.owner.locationId, rawCode: p.rawCode, context: p.context,
        documentType: p.documentType ?? null, documentId: p.documentId ?? null, clientRecordedAt: operation.clientRecordedAt,
      }) }
    }
    case "transfer_exception_disposition": {
      const p = operation.payload as OutboxPayloadMap["transfer_exception_disposition"]
      return executeDocumentResult(await resolveTransferReceiptException({
        lineId: p.lineId, documentRevision: p.expectedRevision, commandId: p.commandId,
        disposition: p.disposition, reasonText: p.reasonText, clientRecordedAt: p.clientRecordedAt,
      }))
    }
  }
}

async function reconcileDocumentCommand(operation: QueuedOperation) {
  if (!operation.documentId) return null
  if (operation.kind !== "transfer_ship" && operation.kind !== "transfer_receive" && operation.kind !== "sales_dispatch" && operation.kind !== "count_finalize" && operation.kind !== "transfer_exception_disposition") return null
  const status = await getDocumentCommandResult(operation.owner.companyId, operation.id)
  if (!status) return null
  if (status.status === "COMPLETED") return { disposition: "confirmed" as const, result: status }
  if (status.status === "CONFLICT") return { disposition: "conflict" as const, result: status }
  if (status.status === "VALIDATION_ERROR" || status.status === "AUTHORIZATION_ERROR") return { disposition: "blocked" as const, result: status }
  return null
}

async function markConfirmed(operation: QueuedOperation, result: unknown) {
  const now = new Date().toISOString()
  await putOperation({ ...operation, state: "confirmed", confirmedAt: now, serverResult: result, leaseOwner: null, leaseExpiresAt: null, nextAttemptAt: null, lastError: null })
  await setLastConfirmedAt(operation.owner, now)
}

async function markFailure(operation: QueuedOperation, error: OutboxLastError) {
  if (error.kind === "conflict") {
    await putOperation({ ...operation, state: "conflict", lastError: error, leaseOwner: null, leaseExpiresAt: null, nextAttemptAt: null })
    return
  }
  if (error.kind === "validation" || error.kind === "authorization" || error.kind === "dependency") {
    await putOperation({ ...operation, state: "blocked", lastError: error, leaseOwner: null, leaseExpiresAt: null, nextAttemptAt: null })
    return
  }
  await putOperation({
    ...operation,
    state: "failed",
    lastError: error,
    leaseOwner: null,
    leaseExpiresAt: null,
    nextAttemptAt: new Date(Date.now() + retryDelay(operation.attemptCount)).toISOString(),
  })
}

async function processOwnerQueue(owner: QueueOwner) {
  await recoverStaleClaims(owner)
  let queue = await getQueueForOwner(owner)
  const byId = new Map(queue.map((entry) => [entry.id, entry]))

  for (const candidate of queue) {
    if (!active(candidate) || candidate.state === "conflict" || candidate.state === "blocked" || !due(candidate)) continue

    const dependencies = candidate.dependencyIds.map((id) => byId.get(id)).filter(Boolean) as QueuedOperation[]
    const badDependency = dependencies.find((entry) => entry.state === "conflict" || entry.state === "blocked" || entry.state === "cancelled")
    if (badDependency) {
      await markFailure(candidate, { kind: "dependency", code: "DEPENDENCY_BLOCKED", message: `Dependency ${badDependency.id} is ${badDependency.state}; causal successor is blocked.`, at: new Date().toISOString() })
      continue
    }
    if (dependencies.some((entry) => entry.state !== "confirmed")) continue

    const operation = await claim(candidate)
    if (!operation) continue

    try {
      const reconciliation = await reconcileDocumentCommand(operation)
      if (reconciliation?.disposition === "confirmed") {
        await markConfirmed(operation, reconciliation.result)
        byId.set(operation.id, { ...operation, state: "confirmed" })
        continue
      }
      if (reconciliation?.disposition === "conflict") {
        await markFailure(operation, { kind: "conflict", code: "SERVER_CONFLICT", message: "Server command is in conflict state.", at: new Date().toISOString() })
        continue
      }
      if (reconciliation?.disposition === "blocked") {
        await markFailure(operation, { kind: "validation", code: "SERVER_REJECTED", message: "Server command is permanently blocked.", at: new Date().toISOString() })
        continue
      }

      const outcome = await execute(operation)
      if (outcome.disposition === "confirmed") {
        await markConfirmed(operation, outcome.result)
        byId.set(operation.id, { ...operation, state: "confirmed" })
      } else if (outcome.disposition === "conflict") {
        const record = rawRecord(outcome.result)
        await markFailure(operation, { kind: "conflict", code: typeof record?.code === "string" ? record.code : "CONFLICT", message: typeof record?.message === "string" ? record.message : "Authoritative server state moved since this offline action.", at: new Date().toISOString() })
      } else if (outcome.disposition === "blocked") {
        const record = rawRecord(outcome.result)
        await markFailure(operation, { kind: "validation", code: typeof record?.code === "string" ? record.code : "REJECTED", message: typeof record?.message === "string" ? record.message : "Server rejected this command.", at: new Date().toISOString() })
      } else {
        await markFailure(operation, { kind: "transient", code: "PROCESSING", message: "Server command is still processing; retry will reconcile the stable command id.", at: new Date().toISOString() })
      }
    } catch (error) {
      let reconciled: unknown | null = null
      try { reconciled = await reconcileCapture(operation) } catch { /* keep original failure classification */ }
      if (reconciled) {
        await markConfirmed(operation, reconciled)
        byId.set(operation.id, { ...operation, state: "confirmed" })
        continue
      }
      await markFailure(operation, classifyError(error))
    }
  }

  queue = await getQueueForOwner(owner)
  return queue
}

type NavigatorWithLocks = Navigator & {
  locks?: { request: (name: string, options: { ifAvailable: boolean; mode: "exclusive" }, callback: (lock: unknown | null) => Promise<unknown>) => Promise<unknown> }
}

type DurableLeaseRecord = { owner: string; expiresAt: string }
const LEASE_DB_NAME = "FieldOneOfflineLocksV1"
const LEASE_STORE_NAME = "leases"

function openLeaseDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    if (typeof indexedDB === "undefined") {
      reject(new Error("IndexedDB is unavailable; cannot safely acquire a cross-context outbox lease"))
      return
    }
    const request = indexedDB.open(LEASE_DB_NAME, 1)
    request.onupgradeneeded = () => {
      const db = request.result
      if (!db.objectStoreNames.contains(LEASE_STORE_NAME)) db.createObjectStore(LEASE_STORE_NAME)
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error ?? new Error("Unable to open durable outbox lease database"))
  })
}

async function acquireDurableLease(key: string) {
  const db = await openLeaseDb()
  try {
    return await new Promise<boolean>((resolve, reject) => {
      const tx = db.transaction(LEASE_STORE_NAME, "readwrite")
      const store = tx.objectStore(LEASE_STORE_NAME)
      const request = store.get(key)
      let acquired = false
      request.onsuccess = () => {
        const current = request.result as DurableLeaseRecord | undefined
        const expired = !current || new Date(current.expiresAt).getTime() <= Date.now()
        if (expired || current.owner === workerId) {
          store.put({ owner: workerId, expiresAt: new Date(Date.now() + LEASE_MS).toISOString() } satisfies DurableLeaseRecord, key)
          acquired = true
        }
      }
      request.onerror = () => tx.abort()
      tx.oncomplete = () => resolve(acquired)
      tx.onabort = () => reject(tx.error ?? request.error ?? new Error("Unable to acquire durable outbox lease"))
      tx.onerror = () => reject(tx.error ?? new Error("Unable to acquire durable outbox lease"))
    })
  } finally {
    db.close()
  }
}

async function renewDurableLease(key: string) {
  const db = await openLeaseDb()
  try {
    return await new Promise<boolean>((resolve, reject) => {
      const tx = db.transaction(LEASE_STORE_NAME, "readwrite")
      const store = tx.objectStore(LEASE_STORE_NAME)
      const request = store.get(key)
      let renewed = false
      request.onsuccess = () => {
        const current = request.result as DurableLeaseRecord | undefined
        if (current?.owner === workerId) {
          store.put({ owner: workerId, expiresAt: new Date(Date.now() + LEASE_MS).toISOString() } satisfies DurableLeaseRecord, key)
          renewed = true
        }
      }
      request.onerror = () => tx.abort()
      tx.oncomplete = () => resolve(renewed)
      tx.onabort = () => reject(tx.error ?? request.error ?? new Error("Unable to renew durable outbox lease"))
      tx.onerror = () => reject(tx.error ?? new Error("Unable to renew durable outbox lease"))
    })
  } finally {
    db.close()
  }
}

async function releaseDurableLease(key: string) {
  const db = await openLeaseDb()
  try {
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(LEASE_STORE_NAME, "readwrite")
      const store = tx.objectStore(LEASE_STORE_NAME)
      const request = store.get(key)
      request.onsuccess = () => {
        const current = request.result as DurableLeaseRecord | undefined
        if (current?.owner === workerId) store.delete(key)
      }
      request.onerror = () => tx.abort()
      tx.oncomplete = () => resolve()
      tx.onabort = () => reject(tx.error ?? request.error ?? new Error("Unable to release durable outbox lease"))
      tx.onerror = () => reject(tx.error ?? new Error("Unable to release durable outbox lease"))
    })
  } finally {
    db.close()
  }
}

async function processWithDurableLease(owner: QueueOwner) {
  const key = `owner-lease:${ownerKey(owner)}`
  if (!(await acquireDurableLease(key))) return getQueueForOwner(owner)
  const heartbeat = setInterval(() => { void renewDurableLease(key) }, Math.max(5_000, Math.floor(LEASE_MS / 3)))
  try {
    return await processOwnerQueue(owner)
  } finally {
    clearInterval(heartbeat)
    await releaseDurableLease(key)
  }
}

export async function processQueue(owner: QueueOwner) {
  await migrateLegacyQueueOnce()
  const locks = (typeof navigator !== "undefined" ? (navigator as NavigatorWithLocks).locks : undefined)
  if (locks) {
    let result: QueuedOperation[] | null = null
    await locks.request(`fieldone-outbox:${ownerKey(owner)}`, { ifAvailable: true, mode: "exclusive" }, async (lock) => {
      if (!lock) return
      result = await processOwnerQueue(owner)
    })
    return result ?? getQueueForOwner(owner)
  }
  return processWithDurableLease(owner)
}

export async function retryOperation(id: string, owner: QueueOwner) {
  const operation = await storageGet<QueuedOperation>(outbox, id)
  if (!operation || !sameOwner(operation, owner)) return
  if (operation.state === "conflict") throw new Error("Conflict commands require explicit reconciliation and cannot be blindly retried")
  if (operation.state === "blocked" && operation.lastError?.kind !== "authorization") throw new Error("Permanently blocked command requires correction before retry")
  await putOperation({ ...operation, state: "queued", nextAttemptAt: null, lastError: null, leaseOwner: null, leaseExpiresAt: null })
}

/** Keep-server resolution preserves the local command record as cancelled audit history. */
export async function acceptServerVersion(id: string, owner: QueueOwner) {
  const operation = await storageGet<QueuedOperation>(outbox, id)
  if (!operation || !sameOwner(operation, owner) || operation.state !== "conflict") return
  await putOperation({
    ...operation,
    state: "cancelled",
    leaseOwner: null,
    leaseExpiresAt: null,
    nextAttemptAt: null,
    lastError: operation.lastError ?? { kind: "conflict", code: "USER_ACCEPTED_SERVER", message: "Local conflicting command cancelled after user accepted server state.", at: new Date().toISOString() },
  })
}


async function authoritativeSnapshotFor(operation: QueuedOperation): Promise<{ revision: number; stockPreconditions?: StockRevisionPrecondition[] }> {
  if (!operation.documentId) throw new Error("Conflict command has no authoritative document to rebase")
  if (operation.kind === "transfer_line_capture" || operation.kind === "transfer_receive" || operation.kind === "transfer_ship" || operation.kind === "transfer_exception_disposition") {
    const doc = await fetchTransferDocument(operation.documentId)
    if (!doc) throw new Error("Transfer no longer exists")
    return { revision: doc.revision, stockPreconditions: operation.kind === "transfer_receive" || operation.kind === "transfer_ship" ? doc.stockPreconditions : undefined }
  }
  if (operation.kind === "sales_line_capture" || operation.kind === "sales_backorder" || operation.kind === "sales_dispatch") {
    const doc = await fetchSalesOrderDocument(operation.documentId)
    if (!doc) throw new Error("Sales order no longer exists")
    return { revision: doc.revision, stockPreconditions: operation.kind === "sales_dispatch" ? doc.stockPreconditions : undefined }
  }
  if (operation.kind === "count_observation" || operation.kind === "count_variance_reason" || operation.kind === "count_decision" || operation.kind === "count_finalize") {
    const doc = await fetchCountSessionDocument(operation.documentId)
    if (!doc) throw new Error("Count session no longer exists")
    return { revision: doc.revision, stockPreconditions: operation.kind === "count_finalize" ? doc.stockPreconditions : undefined }
  }
  throw new Error(`Command kind ${operation.kind} does not support conflict rebasing`)
}

/**
 * Keep-local conflict resolution never mutates a conflicted command in place. It
 * creates a new stable command identity against the latest authoritative document
 * revision and preserves the old command as cancelled audit history. Server-side
 * validation and delta derivation still decide whether the successor may execute.
 */
export async function rebaseConflictOperation(id: string, owner: QueueOwner) {
  const operation = await storageGet<QueuedOperation>(outbox, id)
  if (!operation || !sameOwner(operation, owner) || operation.state !== "conflict") return null
  const snapshot = await authoritativeSnapshotFor(operation)
  const revision = snapshot.revision
  const successorId = crypto.randomUUID()
  const payload = { ...(operation.payload as Record<string, unknown>), expectedRevision: revision } as any
  if (snapshot.stockPreconditions) payload.stockPreconditions = snapshot.stockPreconditions
  if ("commandId" in payload) payload.commandId = successorId

  const successor = await enqueueCommand({
    id: successorId,
    owner,
    kind: operation.kind,
    ref: operation.ref,
    label: `${operation.label} (rebased)`,
    documentId: operation.documentId,
    clientRecordedAt: operation.clientRecordedAt,
    payload: payload as never,
    dependencyIds: [],
  })

  if (operation.documentId) {
    await replaceWorkflowCommandReference(owner, operation.documentId, operation.id, successorId)
  }

  await putOperation({
    ...operation,
    state: "cancelled",
    leaseOwner: null,
    leaseExpiresAt: null,
    nextAttemptAt: null,
    serverResult: { resolution: "rebased", successorId, authoritativeRevision: revision, previousServerResult: operation.serverResult },
    lastError: operation.lastError ?? { kind: "conflict", code: "USER_REBASED_LOCAL", message: "Conflicting local command was preserved and replaced by an explicit successor command.", at: new Date().toISOString() },
  })
  return successor
}

export const resolveConflict = acceptServerVersion
