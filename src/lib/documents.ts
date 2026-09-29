import { useQuery } from "@tanstack/react-query"
import { supabase } from "./supabase"
import { useOperationalContext } from "./auth"
import { loadSnapshot, saveSnapshot, type OfflineOwner } from "./offlineStore"
import { probeBackendReachability } from "./reachability"

export type WorkKind = "receive" | "dispatch" | "count"

export type StockRevisionPrecondition = {
  locationId: string
  binId: string
  productId: string
  inventoryStatus: "AVAILABLE" | "DAMAGED" | "BLOCKED"
  physicalRevision: number
  binReservationRevision: number
  locationReservationRevision: number
}
export type WarehouseWorkItem = {
  id: string
  kind: WorkKind
  ref: string
  title: string
  where: string
  dueAt: string | null
  priority: "normal" | "high"
  status: string
  revision: number
  done: number
  total: number
}

export type TransferLineDocument = {
  id: string
  lineNumber: number
  productId: string
  productName: string
  sku: string
  unitId: string
  unitCode: string
  sourceBinId: string
  sourceBinCode: string
  destinationBinId: string
  destinationBinCode: string
  expectedBaseQuantity: number
  shippedBaseQuantity: number
  capturedReceivedBaseQuantity: number
  postedBaseQuantity: number
  remainingExpectedBaseQuantity: number
  lineStatus: string
  exceptionCode: string | null
  exceptionNotes: string | null
  disposition: TransferReceiptDisposition | null
  dispositionStatus: "RESOLVED" | "APPLIED" | null
  revision: number
  clientRecordedAt: string | null
}

export type TransferDocument = {
  id: string
  ref: string
  status: string
  revision: number
  sourceLocationId: string
  sourceName: string
  destinationLocationId: string
  destinationName: string
  dueAt: string | null
  lines: TransferLineDocument[]
  stockPreconditions: StockRevisionPrecondition[]
}

export type SalesOrderLineDocument = {
  id: string
  lineNumber: number
  productId: string
  productName: string
  sku: string
  unitId: string
  unitCode: string
  sourceBinId: string
  sourceBinCode: string
  requestedBaseQuantity: number
  capturedPickedBaseQuantity: number
  postedBaseQuantity: number
  backorderedBaseQuantity: number
  remainingBaseQuantity: number
  lineStatus: string
  exceptionCode: string | null
  exceptionNotes: string | null
  revision: number
  clientRecordedAt: string | null
}

export type SalesOrderDocument = {
  id: string
  ref: string
  status: string
  revision: number
  sourceLocationId: string
  sourceName: string
  destinationLocationId: string | null
  destinationName: string
  customerName: string
  priority: "NORMAL" | "HIGH"
  dueAt: string | null
  lines: SalesOrderLineDocument[]
  stockPreconditions: StockRevisionPrecondition[]
}

export type CountLineDocument = {
  id: string
  lineNumber: number
  productId: string
  productName: string
  sku: string
  binId: string
  binCode: string
  unitId: string
  unitCode: string
  expectedBaseQuantity: number | null
  expectedPhysicalRevision: number | null
  lineStatus: string
  revision: number
  latestObservationId: string | null
  observedBaseQuantity: number | null
  varianceBaseQuantity: number | null
  reasonCode: string | null
  approvalDecision: "APPROVED" | "REJECTED" | "RECOUNT" | null
}

export type CountSessionDocument = {
  id: string
  ref: string
  status: string
  revision: number
  locationId: string
  locationName: string
  zone: string
  policy: string
  dueAt: string | null
  lines: CountLineDocument[]
  stockPreconditions: StockRevisionPrecondition[]
}

type JsonRecord = Record<string, unknown>
const asRecord = (value: unknown): JsonRecord => {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid authoritative document response")
  return value as JsonRecord
}
const str = (r: JsonRecord, key: string, nullable = false): string | null => {
  const value = r[key]
  if (value == null && nullable) return null
  if (typeof value !== "string") throw new Error(`Invalid authoritative document field: ${key}`)
  return value
}
const num = (r: JsonRecord, key: string, nullable = false): number | null => {
  const value = r[key]
  if (value == null && nullable) return null
  const parsed = typeof value === "number" ? value : Number(value)
  if (!Number.isFinite(parsed)) throw new Error(`Invalid authoritative numeric field: ${key}`)
  return parsed
}
const array = (r: JsonRecord, key: string): unknown[] => {
  const value = r[key]
  if (!Array.isArray(value)) throw new Error(`Invalid authoritative document array: ${key}`)
  return value
}

function parseWorkItem(value: unknown): WarehouseWorkItem {
  const r = asRecord(value)
  const kind = str(r, "kind")
  if (kind !== "receive" && kind !== "dispatch" && kind !== "count") throw new Error("Invalid work kind")
  const priority = str(r, "priority")?.toLowerCase()
  return {
    id: str(r, "id")!,
    kind,
    ref: str(r, "ref")!,
    title: str(r, "title")!,
    where: str(r, "where")!,
    dueAt: str(r, "due_at", true),
    priority: priority === "high" ? "high" : "normal",
    status: str(r, "status")!,
    revision: num(r, "revision")!,
    done: num(r, "done")!,
    total: num(r, "total")!,
  }
}

function parseTransfer(value: unknown): TransferDocument {
  const r = asRecord(value)
  return {
    id: str(r, "id")!, ref: str(r, "ref")!, status: str(r, "status")!, revision: num(r, "revision")!,
    sourceLocationId: str(r, "source_location_id")!, sourceName: str(r, "source_name")!,
    destinationLocationId: str(r, "destination_location_id")!, destinationName: str(r, "destination_name")!,
    dueAt: str(r, "due_at", true),
    stockPreconditions: [],
    lines: array(r, "lines").map((entry) => {
      const l = asRecord(entry)
      return {
        id: str(l, "id")!, lineNumber: num(l, "line_number")!, productId: str(l, "product_id")!, productName: str(l, "product_name")!, sku: str(l, "sku")!,
        unitId: str(l, "unit_id")!, unitCode: str(l, "unit_code")!, sourceBinId: str(l, "source_bin_id")!, sourceBinCode: str(l, "source_bin_code")!,
        destinationBinId: str(l, "destination_bin_id")!, destinationBinCode: str(l, "destination_bin_code")!,
        expectedBaseQuantity: num(l, "expected_base_quantity")!, shippedBaseQuantity: num(l, "shipped_base_quantity")!, capturedReceivedBaseQuantity: num(l, "captured_received_base_quantity")!,
        postedBaseQuantity: num(l, "posted_base_quantity")!, remainingExpectedBaseQuantity: num(l, "remaining_expected_base_quantity")!,
        lineStatus: str(l, "line_status")!, exceptionCode: str(l, "exception_code", true), exceptionNotes: str(l, "exception_notes", true),
        disposition: null, dispositionStatus: null,
        revision: num(l, "revision")!, clientRecordedAt: str(l, "client_recorded_at", true),
      }
    }),
  }
}

function parseSalesOrder(value: unknown): SalesOrderDocument {
  const r = asRecord(value)
  const priority = str(r, "priority")
  if (priority !== "NORMAL" && priority !== "HIGH") throw new Error("Invalid sales-order priority")
  return {
    id: str(r, "id")!, ref: str(r, "ref")!, status: str(r, "status")!, revision: num(r, "revision")!,
    sourceLocationId: str(r, "source_location_id")!, sourceName: str(r, "source_name")!, destinationLocationId: str(r, "destination_location_id", true),
    destinationName: str(r, "destination_name")!, customerName: str(r, "customer_name")!, priority, dueAt: str(r, "due_at", true),
    stockPreconditions: [],
    lines: array(r, "lines").map((entry) => {
      const l = asRecord(entry)
      return {
        id: str(l, "id")!, lineNumber: num(l, "line_number")!, productId: str(l, "product_id")!, productName: str(l, "product_name")!, sku: str(l, "sku")!,
        unitId: str(l, "unit_id")!, unitCode: str(l, "unit_code")!, sourceBinId: str(l, "source_bin_id")!, sourceBinCode: str(l, "source_bin_code")!,
        requestedBaseQuantity: num(l, "requested_base_quantity")!, capturedPickedBaseQuantity: num(l, "captured_picked_base_quantity")!,
        postedBaseQuantity: num(l, "posted_base_quantity")!, backorderedBaseQuantity: num(l, "backordered_base_quantity")!, remainingBaseQuantity: num(l, "remaining_base_quantity")!,
        lineStatus: str(l, "line_status")!, exceptionCode: str(l, "exception_code", true), exceptionNotes: str(l, "exception_notes", true),
        revision: num(l, "revision")!, clientRecordedAt: str(l, "client_recorded_at", true),
      }
    }),
  }
}

function parseCountSession(value: unknown): CountSessionDocument {
  const r = asRecord(value)
  return {
    id: str(r, "id")!, ref: str(r, "ref")!, status: str(r, "status")!, revision: num(r, "revision")!,
    locationId: str(r, "location_id")!, locationName: str(r, "location_name")!, zone: str(r, "zone")!, policy: str(r, "policy")!, dueAt: str(r, "due_at", true),
    stockPreconditions: [],
    lines: array(r, "lines").map((entry) => {
      const l = asRecord(entry)
      const decision = str(l, "approval_decision", true)
      if (decision !== null && decision !== "APPROVED" && decision !== "REJECTED" && decision !== "RECOUNT") throw new Error("Invalid count approval decision")
      return {
        id: str(l, "id")!, lineNumber: num(l, "line_number")!, productId: str(l, "product_id")!, productName: str(l, "product_name")!, sku: str(l, "sku")!,
        binId: str(l, "bin_id")!, binCode: str(l, "bin_code")!, unitId: str(l, "unit_id")!, unitCode: str(l, "unit_code")!,
        expectedBaseQuantity: num(l, "expected_base_quantity", true), expectedPhysicalRevision: num(l, "expected_physical_revision", true),
        lineStatus: str(l, "line_status")!, revision: num(l, "revision")!, latestObservationId: str(l, "latest_observation_id", true),
        observedBaseQuantity: num(l, "observed_base_quantity", true), varianceBaseQuantity: num(l, "variance_base_quantity", true),
        reasonCode: str(l, "reason_code", true), approvalDecision: decision,
      }
    }),
  }
}

const RPC_TIMEOUT_MS = 20_000

async function rpcJson(name: string, args: Record<string, unknown>): Promise<unknown> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), RPC_TIMEOUT_MS)
  try {
    const { data, error } = await supabase.rpc(name, args).abortSignal(controller.signal)
    if (error) throw error
    return data
  } catch (error) {
    if (controller.signal.aborted) throw new Error(`RPC timeout after ${RPC_TIMEOUT_MS}ms: ${name}`)
    throw error
  } finally {
    clearTimeout(timeout)
  }
}

function ownerFromContext(input: { userId: string | null; companyId: string | null; locationId: string | null }): OfflineOwner | null {
  if (!input.userId || !input.companyId || !input.locationId) return null
  return { authUserId: input.userId, companyId: input.companyId, locationId: input.locationId }
}

async function snapshotFallback<T>(
  owner: OfflineOwner | null,
  kind: "warehouse-work" | "transfer-document" | "sales-order-document" | "count-session-document",
  key: string,
  loadRemote: () => Promise<T>,
): Promise<T> {
  if (owner && !(await probeBackendReachability())) {
    const cached = await loadSnapshot<T>(owner, kind, key)
    if (cached) return cached.value
    throw new Error(`FieldOne backend is unreachable and no ${kind} snapshot is available`)
  }
  try {
    const value = await loadRemote()
    if (owner) {
      await saveSnapshot({ schemaVersion: 1, owner, kind, key, capturedAt: new Date().toISOString(), value })
    }
    return value
  } catch (error) {
    if (owner) {
      const cached = await loadSnapshot<T>(owner, kind, key)
      if (cached) return cached.value
    }
    throw error
  }
}

function parseStockPreconditions(value: unknown): StockRevisionPrecondition[] {
  if (!Array.isArray(value)) throw new Error("Invalid stock revision precondition response")
  return value.map((entry) => {
    const r = asRecord(entry)
    const status = str(r, "inventoryStatus")
    if (status !== "AVAILABLE" && status !== "DAMAGED" && status !== "BLOCKED") throw new Error("Invalid inventory status precondition")
    return {
      locationId: str(r, "locationId")!, binId: str(r, "binId")!, productId: str(r, "productId")!, inventoryStatus: status,
      physicalRevision: num(r, "physicalRevision")!, binReservationRevision: num(r, "binReservationRevision")!,
      locationReservationRevision: num(r, "locationReservationRevision")!,
    }
  })
}

async function fetchStockPreconditions(commandType: "TRANSFER_SHIP" | "TRANSFER_RECEIVE" | "SALES_DISPATCH" | "COUNT_FINALIZE", documentId: string) {
  const value = await rpcJson("phase9_get_document_stock_preconditions", { p_command_type: commandType, p_document_id: documentId })
  return parseStockPreconditions(value)
}

export async function fetchWarehouseWork(locationId: string): Promise<WarehouseWorkItem[]> {
  const value = await rpcJson("list_my_warehouse_work", { p_location_id: locationId })
  if (!Array.isArray(value)) throw new Error("Invalid authoritative work response")
  return value.map(parseWorkItem)
}

export async function fetchTransferDocument(documentId: string): Promise<TransferDocument | null> {
  const value = await rpcJson("get_transfer_document", { p_document_id: documentId })
  if (value == null) return null
  const document = parseTransfer(value)
  const stockPreconditions = await fetchStockPreconditions("TRANSFER_RECEIVE", documentId)
  const { data, error } = await supabase
    .from("inventory_transfer_receipt_dispositions")
    .select("transfer_line_id,disposition,applied_at")
    .eq("transfer_id", documentId)
  if (error) throw error
  const dispositions = new Map(
    (data ?? []).map((row) => [
      String(row.transfer_line_id),
      {
        disposition: row.disposition as TransferReceiptDisposition,
        dispositionStatus: row.applied_at ? "APPLIED" as const : "RESOLVED" as const,
      },
    ]),
  )
  return {
    ...document,
    stockPreconditions,
    lines: document.lines.map((line) => ({ ...line, ...(dispositions.get(line.id) ?? {}) })),
  }
}

export async function fetchSalesOrderDocument(documentId: string): Promise<SalesOrderDocument | null> {
  const value = await rpcJson("get_sales_order_document", { p_document_id: documentId })
  if (value == null) return null
  return { ...parseSalesOrder(value), stockPreconditions: await fetchStockPreconditions("SALES_DISPATCH", documentId) }
}

export async function fetchCountSessionDocument(documentId: string): Promise<CountSessionDocument | null> {
  const value = await rpcJson("get_count_session_document", { p_document_id: documentId })
  if (value == null) return null
  return { ...parseCountSession(value), stockPreconditions: await fetchStockPreconditions("COUNT_FINALIZE", documentId) }
}

export function useWarehouseWork() {
  const { user, activeCompanyId, activeLocationId } = useOperationalContext()
  const owner = ownerFromContext({ userId: user?.id ?? null, companyId: activeCompanyId, locationId: activeLocationId })
  return useQuery({
    queryKey: ["warehouse-work", activeCompanyId, activeLocationId],
    enabled: Boolean(activeCompanyId && activeLocationId),
    queryFn: async () => {
      if (!activeLocationId) return [] as WarehouseWorkItem[]
      return snapshotFallback(owner, "warehouse-work", activeLocationId, () => fetchWarehouseWork(activeLocationId))
    },
    staleTime: 15_000,
  })
}

export function useTransferDocument(documentId: string | null) {
  const { user, activeCompanyId, activeLocationId } = useOperationalContext()
  const owner = ownerFromContext({ userId: user?.id ?? null, companyId: activeCompanyId, locationId: activeLocationId })
  return useQuery({
    queryKey: ["transfer-document", activeCompanyId, activeLocationId, documentId],
    enabled: Boolean(activeCompanyId && activeLocationId && documentId),
    queryFn: async () => {
      if (!documentId) return null
      return snapshotFallback(owner, "transfer-document", documentId, () => fetchTransferDocument(documentId))
    },
  })
}

export function useSalesOrderDocument(documentId: string | null) {
  const { user, activeCompanyId, activeLocationId } = useOperationalContext()
  const owner = ownerFromContext({ userId: user?.id ?? null, companyId: activeCompanyId, locationId: activeLocationId })
  return useQuery({
    queryKey: ["sales-order-document", activeCompanyId, activeLocationId, documentId],
    enabled: Boolean(activeCompanyId && activeLocationId && documentId),
    queryFn: async () => {
      if (!documentId) return null
      return snapshotFallback(owner, "sales-order-document", documentId, () => fetchSalesOrderDocument(documentId))
    },
  })
}

export function useCountSessionDocument(documentId: string | null) {
  const { user, activeCompanyId, activeLocationId } = useOperationalContext()
  const owner = ownerFromContext({ userId: user?.id ?? null, companyId: activeCompanyId, locationId: activeLocationId })
  return useQuery({
    queryKey: ["count-session-document", activeCompanyId, activeLocationId, documentId],
    enabled: Boolean(activeCompanyId && activeLocationId && documentId),
    queryFn: async () => {
      if (!documentId) return null
      return snapshotFallback(owner, "count-session-document", documentId, () => fetchCountSessionDocument(documentId))
    },
  })
}

export async function recordTransferReceiptLine(input: {
  lineId: string; documentRevision: number; receivedQuantity: number; unitId: string; destinationBinId: string;
  exceptionCode?: string | null; exceptionNotes?: string | null; clientRecordedAt: string
}) {
  return rpcJson("record_transfer_receipt_line", {
    p_line_id: input.lineId, p_expected_document_revision: input.documentRevision,
    p_received_entered_quantity: input.receivedQuantity, p_unit_id: input.unitId, p_destination_bin_id: input.destinationBinId,
    p_exception_code: input.exceptionCode ?? null, p_exception_notes: input.exceptionNotes ?? null, p_client_recorded_at: input.clientRecordedAt,
  })
}

export async function recordSalesOrderPickLine(input: {
  lineId: string; documentRevision: number; pickedQuantity: number; unitId: string; sourceBinId: string;
  exceptionCode?: string | null; exceptionNotes?: string | null; clientRecordedAt: string
}) {
  return rpcJson("record_sales_order_pick_line", {
    p_line_id: input.lineId, p_expected_document_revision: input.documentRevision,
    p_picked_entered_quantity: input.pickedQuantity, p_unit_id: input.unitId, p_source_bin_id: input.sourceBinId,
    p_exception_code: input.exceptionCode ?? null, p_exception_notes: input.exceptionNotes ?? null, p_client_recorded_at: input.clientRecordedAt,
  })
}

export async function createSalesOrderBackorder(input: { lineId: string; documentRevision: number; baseQuantity: number; reasonCode: string; reasonText?: string | null }) {
  return rpcJson("create_sales_order_backorder", {
    p_line_id: input.lineId, p_expected_document_revision: input.documentRevision, p_base_quantity: input.baseQuantity,
    p_reason_code: input.reasonCode, p_reason_text: input.reasonText ?? null,
  })
}

export async function recordCountObservation(input: {
  lineId: string; sessionRevision: number; observedQuantity: number; unitId: string;
  reasonCode?: string | null; notes?: string | null; clientRecordedAt: string
}) {
  return rpcJson("record_count_observation", {
    p_count_line_id: input.lineId, p_expected_session_revision: input.sessionRevision,
    p_observed_entered_quantity: input.observedQuantity, p_unit_id: input.unitId,
    p_reason_code: input.reasonCode ?? null, p_notes: input.notes ?? null, p_client_recorded_at: input.clientRecordedAt,
  })
}

export async function decideCountVariance(input: { observationId: string; sessionRevision: number; decision: "APPROVED" | "REJECTED" | "RECOUNT"; reason?: string | null }) {
  return rpcJson("decide_count_variance", {
    p_observation_id: input.observationId, p_expected_session_revision: input.sessionRevision,
    p_decision: input.decision, p_decision_reason: input.reason ?? null,
  })
}


export type IdentifierCandidate = {
  lineId: string
  lineNumber: number
  productId: string
  productName: string
  sku: string
  binId: string
  binCode: string
  lineStatus: string
}

export type IdentifierResolution = {
  status: "resolved" | "ambiguous" | "unknown" | "non_actionable" | "invalid"
  normalizedCode: string
  matchType: string | null
  productId: string | null
  productName: string | null
  sku: string | null
  candidates: IdentifierCandidate[]
}

function parseIdentifierResolution(value: unknown): IdentifierResolution {
  const r = asRecord(value)
  const status = str(r, "status")
  if (status !== "resolved" && status !== "ambiguous" && status !== "unknown" && status !== "non_actionable" && status !== "invalid") throw new Error("Invalid identifier resolution status")
  return {
    status, normalizedCode: str(r, "normalized_code", true) ?? "", matchType: str(r, "match_type", true),
    productId: str(r, "product_id", true), productName: str(r, "product_name", true), sku: str(r, "sku", true),
    candidates: Array.isArray(r.candidates) ? r.candidates.map((entry) => {
      const c = asRecord(entry)
      return { lineId: str(c, "line_id")!, lineNumber: num(c, "line_number")!, productId: str(c, "product_id")!, productName: str(c, "product_name")!, sku: str(c, "sku")!, binId: str(c, "bin_id")!, binCode: str(c, "bin_code")!, lineStatus: str(c, "line_status")! }
    }) : [],
  }
}

export async function resolveInventoryIdentifier(input: { locationId: string; code: string; context: "browse" | "receive" | "dispatch"; documentId?: string | null }) {
  return parseIdentifierResolution(await rpcJson("resolve_inventory_identifier", {
    p_location_id: input.locationId, p_code: input.code, p_context: input.context, p_document_id: input.documentId ?? null,
  }))
}

export async function reportUnknownInventoryScan(input: { clientEventId: string; locationId: string; rawCode: string; context: "browse" | "receive" | "dispatch"; documentType?: "TRANSFER" | "SALES_ORDER" | null; documentId?: string | null; clientRecordedAt: string }) {
  return rpcJson("report_unknown_inventory_scan", {
    p_client_event_id: input.clientEventId, p_location_id: input.locationId, p_raw_code: input.rawCode, p_context: input.context,
    p_document_type: input.documentType ?? null, p_document_id: input.documentId ?? null, p_client_recorded_at: input.clientRecordedAt,
  })
}

export type DocumentCommandOutcome =
  | "accepted"
  | "duplicate"
  | "conflict"
  | "validation_error"
  | "authorization_error"
  | "transient_error"
  | "processing"

export type DocumentCommandResult = {
  success: boolean
  outcome: DocumentCommandOutcome
  clientCommandId: string | null
  serverCommandId: string | null
  operationId: string | null
  documentId: string | null
  documentRevision: number | null
  documentStatus: string | null
  code: string | null
  message: string | null
  lines: unknown[]
  replayedResult: unknown | null
}

function parseDocumentCommandResult(value: unknown): DocumentCommandResult {
  const r = asRecord(value)
  const outcome = str(r, "outcome")
  if (
    outcome !== "accepted" && outcome !== "duplicate" && outcome !== "conflict" &&
    outcome !== "validation_error" && outcome !== "authorization_error" && outcome !== "transient_error" && outcome !== "processing"
  ) {
    throw new Error("Invalid document command outcome")
  }
  return {
    success: r.success === true,
    outcome,
    clientCommandId: str(r, "client_command_id", true),
    serverCommandId: str(r, "server_command_id", true),
    operationId: str(r, "operation_id", true),
    documentId: str(r, "document_id", true),
    documentRevision: num(r, "document_revision", true),
    documentStatus: str(r, "document_status", true),
    code: str(r, "code", true),
    message: str(r, "message", true),
    lines: Array.isArray(r.lines) ? r.lines : [],
    replayedResult: r.result ?? null,
  }
}

async function documentCommandRpc(name: string, args: Record<string, unknown>): Promise<DocumentCommandResult> {
  const value = await rpcJson(name, args)
  return parseDocumentCommandResult(value)
}

export async function getDocumentCommandResult(companyId: string, commandId: string) {
  const value = await rpcJson("get_document_command_result", { p_company_id: companyId, p_client_command_id: commandId })
  if (value == null) return null
  const r = asRecord(value)
  const status = str(r, "status")!
  return {
    clientCommandId: str(r, "client_command_id")!,
    serverCommandId: str(r, "server_command_id")!,
    commandType: str(r, "command_type")!,
    documentId: str(r, "document_id")!,
    status,
    result: r.result ?? null,
    errorCode: str(r, "error_code", true),
    errorMessage: str(r, "error_message", true),
    createdAt: str(r, "created_at")!,
    completedAt: str(r, "completed_at", true),
  }
}

/**
 * Command ids are created when the durable business action is created and MUST
 * be persisted/reused for every retry. This helper is only for creating a new
 * business action, never for retry-time regeneration.
 */
export function createDocumentCommandId() {
  return crypto.randomUUID()
}

export async function shipTransferDocument(input: {
  documentId: string
  documentRevision: number
  commandId: string
  clientRecordedAt: string
  stockPreconditions: StockRevisionPrecondition[]
}) {
  return documentCommandRpc("ship_transfer_document_v2", {
    p_document_id: input.documentId,
    p_expected_revision: input.documentRevision,
    p_client_command_id: input.commandId,
    p_expected_stock_revisions: input.stockPreconditions,
    p_client_recorded_at: input.clientRecordedAt,
  })
}

export async function receiveTransferDocument(input: {
  documentId: string
  documentRevision: number
  commandId: string
  allowPartial: boolean
  clientRecordedAt: string
  stockPreconditions: StockRevisionPrecondition[]
}) {
  return documentCommandRpc("receive_transfer_document_v2", {
    p_document_id: input.documentId,
    p_expected_revision: input.documentRevision,
    p_client_command_id: input.commandId,
    p_expected_stock_revisions: input.stockPreconditions,
    p_allow_partial: input.allowPartial,
    p_client_recorded_at: input.clientRecordedAt,
  })
}

export async function dispatchSalesOrder(input: {
  documentId: string
  documentRevision: number
  commandId: string
  clientRecordedAt: string
  stockPreconditions: StockRevisionPrecondition[]
}) {
  return documentCommandRpc("dispatch_sales_order_v2", {
    p_document_id: input.documentId,
    p_expected_revision: input.documentRevision,
    p_client_command_id: input.commandId,
    p_expected_stock_revisions: input.stockPreconditions,
    p_client_recorded_at: input.clientRecordedAt,
  })
}

export async function finalizeCountSession(input: {
  documentId: string
  documentRevision: number
  commandId: string
  clientRecordedAt: string
  stockPreconditions: StockRevisionPrecondition[]
}) {
  return documentCommandRpc("finalize_count_session_v2", {
    p_document_id: input.documentId,
    p_expected_revision: input.documentRevision,
    p_client_command_id: input.commandId,
    p_expected_stock_revisions: input.stockPreconditions,
    p_client_recorded_at: input.clientRecordedAt,
  })
}

export type TransferReceiptDisposition =
  | "ACCEPT_DAMAGED"
  | "REJECT_WRONG_ITEM"
  | "REJECT_UNEXPECTED"
  | "ACCEPT_EXPECTED_REJECT_OVERAGE"

export async function resolveTransferReceiptException(input: {
  lineId: string
  documentRevision: number
  commandId: string
  disposition: TransferReceiptDisposition
  reasonText: string
  clientRecordedAt: string
}) {
  return documentCommandRpc("resolve_transfer_receipt_exception", {
    p_line_id: input.lineId,
    p_expected_document_revision: input.documentRevision,
    p_client_command_id: input.commandId,
    p_disposition: input.disposition,
    p_reason_text: input.reasonText,
    p_client_recorded_at: input.clientRecordedAt,
  })
}
