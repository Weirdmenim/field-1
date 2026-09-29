import { useEffect, useMemo } from "react"
import { ScreenHeader } from "../PhoneFrame"
import Icon from "../ui/Icon"
import { Button, ProgressBar, QtyStepper, ReasonSelector, StatusChip, StickyBar, SyncBadge } from "../ui/primitives"
import type { Nav } from "./types"
import { useCountSessionDocument } from "../../lib/documents"
import { enqueueCommand } from "../../lib/syncEngine"
import { useDurableWorkflowDraft } from "../../lib/useDurableWorkflowDraft"
import { useItems } from "../../lib/queries"
import { itemById as dataItemById } from "./models"

type Step = "assignment" | "count" | "reason" | "approval" | "complete"
type CountLineDraft = { observed: number | null; touched: boolean; observationCommandId: string | null; reason: string | null; reasonCommandId: string | null; decisionCommandId: string | null }
type CountDraftState = Record<string, unknown> & { step: Step; selectedLineId: string | null; lines: Record<string, CountLineDraft>; commandIds: string[]; finalQueued: boolean }
const reasons = ["Shortage", "Overage", "Damaged", "Misplaced", "Recount required"]

export default function CycleCount({ nav }: { nav: Nav }) {
  const documentId = nav.activeTaskId
  const { data: doc, isLoading, error } = useCountSessionDocument(documentId)
  const owner = useMemo(() => ({ authUserId: nav.authUserId, companyId: nav.companyId, locationId: nav.locationId }), [nav.authUserId, nav.companyId, nav.locationId])
  const initialState: CountDraftState = useMemo(() => ({ step: "assignment", selectedLineId: null, lines: {}, commandIds: [], finalQueued: false }), [documentId])
  const draft = useDurableWorkflowDraft<CountDraftState>({ owner, kind: "count", documentId, documentRef: doc?.ref ?? "", serverRevision: doc?.revision ?? 0, initialState })
  const { data: items = [] } = useItems()

  useEffect(() => {
    if (!draft.hydrated || !doc || draft.state.selectedLineId) return
    const reasonNeeded = doc.lines.find((line) => line.varianceBaseQuantity != null && line.varianceBaseQuantity !== 0 && (!line.reasonCode || line.reasonCode === "PENDING_REASON"))
    const approvalNeeded = doc.lines.find((line) => line.lineStatus === "PENDING_APPROVAL" && line.reasonCode && line.reasonCode !== "PENDING_REASON")
    const open = doc.lines.find((line) => ["OPEN", "RECOUNT_REQUIRED", "REJECTED"].includes(line.lineStatus))
    const selected = reasonNeeded ?? approvalNeeded ?? open ?? doc.lines[0]
    if (selected) draft.updateState((current) => ({ ...current, selectedLineId: selected.id, step: reasonNeeded ? "reason" : approvalNeeded && nav.can("inventory.count.approve") ? "approval" : "assignment" }))
  }, [doc, draft.hydrated, draft.state.selectedLineId, draft.updateState, nav])

  if (!documentId) return <Missing nav={nav} message="No authoritative count session is selected." />
  if (isLoading && !doc) return <Missing nav={nav} message="Loading count session…" />
  if (error && !doc) return <Missing nav={nav} message="Count session is unavailable and no offline snapshot is stored." />
  if (!doc) return <Missing nav={nav} message="Count session not found." />

  const line = doc.lines.find((entry) => entry.id === draft.state.selectedLineId) ?? doc.lines[0]
  if (!line) return <Missing nav={nav} message="Count session has no lines." />
  const item = dataItemById(line.productId, items)
  const local = draft.state.lines[line.id]
  const recounting = line.lineStatus === "RECOUNT_REQUIRED" || line.lineStatus === "REJECTED"
  const observed = local?.observed ?? (recounting ? 0 : line.observedBaseQuantity ?? 0)
  const touched = local?.touched ?? (!recounting && line.observedBaseQuantity != null)
  const reason = local?.reason ?? (recounting ? null : line.reasonCode && line.reasonCode !== "PENDING_REASON" ? line.reasonCode : null)
  const pendingReasonLines = doc.lines.filter((entry) => entry.varianceBaseQuantity != null && entry.varianceBaseQuantity !== 0 && (!entry.reasonCode || entry.reasonCode === "PENDING_REASON"))
  const pendingApprovalLines = doc.lines.filter((entry) => entry.lineStatus === "PENDING_APPROVAL" && entry.reasonCode && entry.reasonCode !== "PENDING_REASON")
  const locallyObserved = (lineId: string) => Boolean(draft.state.lines[lineId]?.observationCommandId) || !["OPEN", "RECOUNT_REQUIRED", "REJECTED"].includes(doc.lines.find((entry) => entry.id === lineId)?.lineStatus ?? "")
  const observedCount = doc.lines.filter((entry) => locallyObserved(entry.id)).length
  const allObserved = doc.lines.length > 0 && doc.lines.every((entry) => locallyObserved(entry.id))
  const finalizable = doc.lines.length > 0 && doc.lines.every((entry) => ["READY_TO_POST", "APPROVED", "FINALIZED", "CANCELLED"].includes(entry.lineStatus))
  const stockRevisionReady = Boolean(doc.stockPreconditions?.length)

  const setLineDraft = (patch: Partial<CountLineDraft>) => {
    draft.updateState((current) => ({ ...current, lines: { ...current.lines, [line.id]: { observed, touched, observationCommandId: local?.observationCommandId ?? null, reason: local?.reason ?? null, reasonCommandId: local?.reasonCommandId ?? null, decisionCommandId: local?.decisionCommandId ?? null, ...patch } } }))
  }
  const appendCommandId = (id: string) => draft.updateState((current) => ({ ...current, commandIds: current.commandIds.includes(id) ? current.commandIds : [...current.commandIds, id] }))

  const queueObservation = async () => {
    if (!touched || local?.observationCommandId || (!recounting && line.observedBaseQuantity != null)) return
    const id = crypto.randomUUID()
    const clientRecordedAt = new Date().toISOString()
    const previous = draft.state.commandIds[draft.state.commandIds.length - 1]
    await enqueueCommand({
      id,
      owner,
      kind: "count_observation",
      ref: doc.ref,
      label: "Blind count observation",
      documentId: doc.id,
      clientRecordedAt,
      dependencyIds: previous ? [previous] : [],
      payload: { lineId: line.id, documentId: doc.id, expectedRevision: draft.localRevision, observedQuantity: observed, unitId: line.unitId, reasonCode: "PENDING_REASON", notes: null, clientRecordedAt },
    })
    setLineDraft({ observed, touched: true, observationCommandId: id })
    appendCommandId(id)
    draft.advanceRevision()
    await nav.refreshQueue()
    const next = doc.lines.find((entry) => entry.id !== line.id && !locallyObserved(entry.id))
    draft.updateState((current) => ({ ...current, selectedLineId: next?.id ?? line.id, step: next ? "count" : "complete" }))
  }

  const queueReason = async () => {
    if (!reason || !line.latestObservationId || line.varianceBaseQuantity == null || line.varianceBaseQuantity === 0 || (line.reasonCode && line.reasonCode !== "PENDING_REASON")) return
    const id = local?.reasonCommandId ?? crypto.randomUUID()
    const previous = draft.state.commandIds[draft.state.commandIds.length - 1]
    await enqueueCommand({
      id,
      owner,
      kind: "count_variance_reason",
      ref: doc.ref,
      label: "Count variance reason",
      documentId: doc.id,
      clientRecordedAt: new Date().toISOString(),
      dependencyIds: previous ? [previous] : [],
      payload: { observationId: line.latestObservationId, documentId: doc.id, expectedRevision: draft.localRevision, reasonCode: reason, notes: null },
    })
    setLineDraft({ reason, reasonCommandId: id })
    appendCommandId(id)
    draft.advanceRevision()
    await nav.refreshQueue()
    draft.updateState((current) => ({ ...current, step: nav.can("inventory.count.approve") ? "approval" : "complete" }))
  }

  const queueDecision = async (decision: "APPROVED" | "REJECTED" | "RECOUNT") => {
    if (!nav.can("inventory.count.approve") || !line.latestObservationId) return
    const id = local?.decisionCommandId ?? crypto.randomUUID()
    const previous = draft.state.commandIds[draft.state.commandIds.length - 1]
    await enqueueCommand({
      id,
      owner,
      kind: "count_decision",
      ref: doc.ref,
      label: `Count variance ${decision.toLowerCase()}`,
      documentId: doc.id,
      clientRecordedAt: new Date().toISOString(),
      dependencyIds: previous ? [previous] : [],
      payload: { observationId: line.latestObservationId, documentId: doc.id, expectedRevision: draft.localRevision, decision, reason: null },
    })
    setLineDraft(decision === "RECOUNT" ? { observed: null, touched: false, observationCommandId: null, reason: null, reasonCommandId: null, decisionCommandId: id } : { decisionCommandId: id })
    appendCommandId(id)
    draft.advanceRevision()
    await nav.refreshQueue()
    draft.updateState((current) => ({ ...current, step: "complete" }))
  }

  const queueFinalize = async () => {
    if (!finalizable || !stockRevisionReady) return
    const commandId = await draft.ensureFinalCommandId()
    const clientRecordedAt = new Date().toISOString()
    await enqueueCommand({
      id: commandId,
      owner,
      kind: "count_finalize",
      ref: doc.ref,
      label: "Finalize cycle count",
      documentId: doc.id,
      clientRecordedAt,
      dependencyIds: draft.state.commandIds,
      payload: { documentId: doc.id, expectedRevision: draft.localRevision, commandId, clientRecordedAt, stockPreconditions: doc.stockPreconditions },
    })
    draft.updateState((current) => ({ ...current, finalQueued: true, step: "complete" }))
    await nav.refreshQueue()
  }

  const finalOp = draft.finalCommandId ? nav.syncOps.find((operation) => operation.id === draft.finalCommandId) : undefined
  const step = draft.state.step
  const completeTitle = finalOp?.state === "confirmed" ? "Count finalized" : pendingReasonLines.length > 0 ? "Reason required" : pendingApprovalLines.length > 0 ? "Approval required" : finalizable ? "Ready to finalize" : nav.online ? "Observations queued" : "Saved locally"

  return <div className="fo-screen flex min-h-full flex-col pb-2">
    <ScreenHeader title={step === "complete" ? completeTitle : "Cycle Count"} subtitle={`${doc.ref} · ${doc.zone}`} onBack={() => step === "assignment" ? nav.go("work") : draft.updateState((current) => ({ ...current, step: "assignment" }))} />

    {step === "assignment" && <><div className="space-y-4 px-5"><div className="rounded-2xl border border-hairline bg-white p-4"><div className="flex items-center justify-between"><b>{doc.ref}</b><StatusChip tone="brand">{doc.status}</StatusChip></div><p className="mt-2 text-[13px] text-ink-faint">{doc.zone} · {doc.policy}</p><div className="mt-2 rounded-lg bg-brand-soft px-2.5 py-1.5 text-[13px] font-semibold text-brand">Expected quantities remain hidden until the server records your observation.</div></div><div className="rounded-2xl border border-hairline bg-white p-4"><div className="flex justify-between text-[13px]"><b>Observations</b><b className="text-brand">{observedCount}/{doc.lines.length}</b></div><ProgressBar className="mt-2.5" value={doc.lines.length ? (observedCount/doc.lines.length)*100 : 0} /></div>{doc.lines.map((entry)=>{const done=locallyObserved(entry.id);return <button key={entry.id} onClick={()=>draft.updateState((current)=>({...current,selectedLineId:entry.id,step: entry.varianceBaseQuantity != null && entry.varianceBaseQuantity !== 0 && (!entry.reasonCode || entry.reasonCode === "PENDING_REASON") ? "reason" : entry.lineStatus === "PENDING_APPROVAL" && nav.can("inventory.count.approve") ? "approval" : "count"}))} className="flex w-full items-center justify-between rounded-2xl border border-hairline bg-white p-3.5 text-left"><div><p className="text-[14px] font-semibold">{entry.productName}</p><p className="text-[13px] text-ink-faint">{entry.sku} · Bin {entry.binCode}</p></div><StatusChip tone={done?"success":"neutral"}>{entry.lineStatus}</StatusChip></button>})}</div><StickyBar><Button onClick={()=>draft.updateState((current)=>({...current,step:"count"}))}>{allObserved?"Review count state":"Continue counting"}</Button></StickyBar></>}

    {step === "count" && <div className="flex flex-1 flex-col"><div className="space-y-4 px-5"><div className="rounded-2xl border border-hairline bg-white p-4"><p className="text-[15px] font-bold">{line.productName}</p><p className="text-[13px] text-ink-faint">{line.sku} · Bin {line.binCode} · {line.unitCode}</p>{line.expectedBaseQuantity == null && <p className="mt-2 text-[13px] font-semibold text-brand">Blind count: expected quantity is not present on this client.</p>}</div><div className="rounded-2xl border border-hairline bg-white p-5"><p className="mb-3 text-center text-[13px] font-bold">Physical quantity counted</p><QtyStepper value={observed} onChange={(value)=>setLineDraft({observed:value,touched:true})} unit={line.unitCode} step={item.quantityStep} scale={item.quantityScale} autoFocus /></div></div><StickyBar><Button onClick={()=>void queueObservation()} className={touched?"":"pointer-events-none opacity-50"}>{touched?"Save observation":"Enter or confirm a count first"}</Button></StickyBar></div>}

    {step === "reason" && <div className="flex flex-1 flex-col"><div className="space-y-4 px-5"><div className="rounded-2xl border border-warning/25 bg-warning-soft p-4"><p className="font-bold">Server detected a variance</p><p className="mt-1 text-[13px]">Observed {line.observedBaseQuantity} {line.unitCode}; variance {line.varianceBaseQuantity! > 0 ? "+" : ""}{line.varianceBaseQuantity}. Stock is unchanged until approval and finalization.</p></div><ReasonSelector reasons={reasons} value={reason ?? ""} onChange={(value)=>setLineDraft({reason:value})} label="Variance reason" /><p className="text-[12px] text-ink-faint">Select a reason deliberately for this observation; no default is preselected.</p></div><StickyBar><Button onClick={()=>void queueReason()} className={reason ? "" : "pointer-events-none opacity-50"}>Save variance reason</Button></StickyBar></div>}

    {step === "approval" && <div className="flex flex-1 flex-col"><div className="space-y-4 px-5"><div className="rounded-2xl border border-warning/25 bg-warning-soft p-4"><p className="font-bold">Supervisor decision</p><p className="mt-1 text-[13px]">Variance {line.varianceBaseQuantity}. Reason: {line.reasonCode ?? reason}.</p></div></div><StickyBar><div className="space-y-2"><Button onClick={()=>void queueDecision("APPROVED")}>Approve variance</Button><Button variant="secondary" onClick={()=>void queueDecision("RECOUNT")}>Require recount</Button></div></StickyBar></div>}

    {step === "complete" && <div className="flex flex-1 flex-col items-center justify-center px-7 text-center"><span className="grid h-20 w-20 place-items-center rounded-3xl bg-brand-soft text-brand"><Icon name={finalOp?.state === "confirmed"?"check-circle":"cloud-sync"} className="h-10 w-10" /></span><h2 className="mt-5 text-[20px] font-extrabold">{completeTitle}</h2><p className="mt-2 max-w-[18rem] text-[14px] text-ink-soft">{pendingReasonLines.length>0?`${pendingReasonLines.length} variance reason${pendingReasonLines.length===1?"":"s"} must be recorded after sync.`:pendingApprovalLines.length>0?`${pendingApprovalLines.length} variance${pendingApprovalLines.length===1?"":"s"} await supervisor approval.`:finalizable?"Every line is ready for the atomic Phase 4 finalization command.":"Durable observations are preserved and will reconcile when connectivity returns."}</p>{finalOp && <div className="mt-4"><SyncBadge state={finalOp.state === "confirmed"?"confirmed":finalOp.state === "failed"?"failed":finalOp.state === "conflict"?"conflict":"queued"} /></div>}<div className="mt-8 w-full space-y-2.5">{finalizable && stockRevisionReady && !draft.state.finalQueued && <Button onClick={()=>void queueFinalize()}>Queue finalization</Button>}<Button variant="secondary" onClick={()=>nav.go("sync")}>View Sync Center</Button><Button variant="secondary" onClick={()=>nav.go("home")}>Back to home</Button></div></div>}
  </div>
}

function Missing({nav,message}:{nav:Nav;message:string}){return <div className="fo-screen"><ScreenHeader title="Cycle Count" subtitle="Unable to load count session" onBack={()=>nav.go("work")} /><div className="px-5"><div className="rounded-2xl border border-warning/25 bg-warning-soft p-4 text-[14px]">{message}</div></div></div>}
