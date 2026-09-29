import { useEffect, useMemo } from "react"
import { ScreenHeader } from "../PhoneFrame"
import Icon from "../ui/Icon"
import { Button, ProgressBar, QtyStepper, ReasonSelector, StatusChip, StickyBar, SyncBadge } from "../ui/primitives"
import type { Nav } from "./types"
import { useSalesOrderDocument } from "../../lib/documents"
import { enqueueCommand } from "../../lib/syncEngine"
import { useDurableWorkflowDraft } from "../../lib/useDurableWorkflowDraft"
import { useItems } from "../../lib/queries"
import { itemById as dataItemById } from "./models"

type Step = "overview" | "pick" | "shortage" | "review" | "complete"
type LineDraft = { picked: number; exceptionCode: string | null; reasonText: string; captureCommandId: string | null; backorderCommandId: string | null }
type DispatchDraftState = Record<string, unknown> & { step: Step; selectedLineId: string | null; lines: Record<string, LineDraft>; commandIds: string[]; finalQueued: boolean }
const shortageReasons = ["Insufficient stock", "Damaged stock", "Missing from bin", "Customer partial fulfillment"]

export default function Dispatch({ nav, startExecuting }: { nav: Nav; startExecuting?: boolean }) {
  const documentId = nav.activeTaskId
  const { data: doc, isLoading, error } = useSalesOrderDocument(documentId)
  const owner = useMemo(() => ({ authUserId: nav.authUserId, companyId: nav.companyId, locationId: nav.locationId }), [nav.authUserId, nav.companyId, nav.locationId])
  const initialState: DispatchDraftState = useMemo(() => ({ step: startExecuting ? "pick" : "overview", selectedLineId: nav.scanLineId, lines: {}, commandIds: [], finalQueued: false }), [documentId])
  const draft = useDurableWorkflowDraft<DispatchDraftState>({ owner, kind: "dispatch", documentId, documentRef: doc?.ref ?? "", serverRevision: doc?.revision ?? 0, initialState })
  const { data: items = [] } = useItems()

  useEffect(() => {
    if (!draft.hydrated || !doc || draft.state.selectedLineId) return
    const next = doc.lines.find((line) => line.lineStatus === "OPEN" || line.lineStatus === "IN_PROGRESS" || line.lineStatus === "EXCEPTION") ?? doc.lines[0]
    if (next) draft.updateState((current) => ({ ...current, selectedLineId: next.id, step: startExecuting ? "pick" : current.step }))
  }, [doc, draft.hydrated, draft.state.selectedLineId, draft.updateState, startExecuting])

  if (!documentId) return <Missing nav={nav} message="No authoritative sales order is selected." />
  if (isLoading && !doc) return <Missing nav={nav} message="Loading sales order…" />
  if (error && !doc) return <Missing nav={nav} message="Sales order is unavailable and no offline snapshot is stored." />
  if (!doc) return <Missing nav={nav} message="Sales order not found." />

  const line = doc.lines.find((entry) => entry.id === draft.state.selectedLineId) ?? doc.lines[0]
  if (!line) return <Missing nav={nav} message="Sales order has no lines." />
  const item = dataItemById(line.productId, items)
  const saved = draft.state.lines[line.id]
  const picked = saved?.picked ?? line.capturedPickedBaseQuantity ?? 0
  const reason = saved?.exceptionCode ?? shortageReasons[0]
  const reasonText = saved?.reasonText ?? line.exceptionNotes ?? ""
  const remainingToAccount = Math.max(0, line.requestedBaseQuantity - picked)

  const lineLocalTerminal = (lineId: string) => {
    const local = draft.state.lines[lineId]
    if (local?.captureCommandId && (local.picked >= (doc.lines.find((entry) => entry.id === lineId)?.requestedBaseQuantity ?? 0) || local.backorderCommandId)) return true
    return !["OPEN", "IN_PROGRESS"].includes(doc.lines.find((entry) => entry.id === lineId)?.lineStatus ?? "")
  }
  const done = doc.lines.filter((entry) => lineLocalTerminal(entry.id)).length
  const allTerminal = doc.lines.length > 0 && doc.lines.every((entry) => lineLocalTerminal(entry.id))
  const stockRevisionReady = Boolean(doc.stockPreconditions?.length)

  const setLineDraft = (patch: Partial<LineDraft>) => {
    draft.updateState((current) => ({ ...current, lines: { ...current.lines, [line.id]: { picked, exceptionCode: saved?.exceptionCode ?? null, reasonText, captureCommandId: saved?.captureCommandId ?? null, backorderCommandId: saved?.backorderCommandId ?? null, ...patch } } }))
  }

  const selectLine = (lineId: string) => {
    if (lineLocalTerminal(lineId)) return
    draft.updateState((current) => ({ ...current, selectedLineId: lineId, step: "pick" }))
  }

  const appendCommandId = (commandId: string) => draft.updateState((current) => ({ ...current, commandIds: current.commandIds.includes(commandId) ? current.commandIds : [...current.commandIds, commandId] }))

  const queueLine = async (exceptionCode: string | null, note: string | null, createBackorder: boolean) => {
    if (lineLocalTerminal(line.id)) return
    const captureId = saved?.captureCommandId ?? crypto.randomUUID()
    const clientRecordedAt = new Date().toISOString()
    const previous = draft.state.commandIds[draft.state.commandIds.length - 1]
    await enqueueCommand({
      id: captureId,
      owner,
      kind: "sales_line_capture",
      ref: doc.ref,
      label: "Pick line capture",
      documentId: doc.id,
      clientRecordedAt,
      dependencyIds: previous ? [previous] : [],
      payload: { lineId: line.id, documentId: doc.id, expectedRevision: draft.localRevision, pickedQuantity: picked, unitId: line.unitId, sourceBinId: line.sourceBinId, exceptionCode, exceptionNotes: note, clientRecordedAt },
    })
    appendCommandId(captureId)
    setLineDraft({ picked, exceptionCode, reasonText: note ?? "", captureCommandId: captureId })
    draft.advanceRevision()

    let backorderId: string | null = saved?.backorderCommandId ?? null
    if (createBackorder && remainingToAccount > 0) {
      backorderId = backorderId ?? crypto.randomUUID()
      await enqueueCommand({
        id: backorderId,
        owner,
        kind: "sales_backorder",
        ref: doc.ref,
        label: "Backorder remainder",
        documentId: doc.id,
        clientRecordedAt,
        dependencyIds: [captureId],
        payload: { lineId: line.id, documentId: doc.id, expectedRevision: draft.localRevision + 1, baseQuantity: remainingToAccount, reasonCode: exceptionCode ?? "PARTIAL", reasonText: note },
      })
      appendCommandId(backorderId)
      setLineDraft({ picked, exceptionCode, reasonText: note ?? "", captureCommandId: captureId, backorderCommandId: backorderId })
      draft.advanceRevision()
    }
    await nav.refreshQueue()
    const next = doc.lines.find((entry) => entry.id !== line.id && !lineLocalTerminal(entry.id))
    draft.updateState((current) => ({ ...current, selectedLineId: next?.id ?? line.id, step: next ? "pick" : "review" }))
  }

  const queueFinal = async () => {
    if (!allTerminal || !stockRevisionReady) return
    const commandId = await draft.ensureFinalCommandId()
    const clientRecordedAt = new Date().toISOString()
    await enqueueCommand({
      id: commandId,
      owner,
      kind: "sales_dispatch",
      ref: doc.ref,
      label: "Dispatch sales order",
      documentId: doc.id,
      clientRecordedAt,
      dependencyIds: draft.state.commandIds,
      payload: { documentId: doc.id, expectedRevision: draft.localRevision, commandId, clientRecordedAt, stockPreconditions: doc.stockPreconditions },
    })
    draft.updateState((current) => ({ ...current, finalQueued: true, step: "complete" }))
    await nav.refreshQueue()
  }

  const step = draft.state.step
  const back = () => {
    if (step === "overview") nav.go("work")
    else draft.updateState((current) => ({ ...current, step: step === "review" ? "overview" : "overview" }))
  }
  const finalOp = draft.finalCommandId ? nav.syncOps.find((operation) => operation.id === draft.finalCommandId) : undefined
  const completeTitle = finalOp?.state === "confirmed" ? "Dispatch confirmed" : finalOp?.state === "conflict" || finalOp?.state === "blocked" ? "Dispatch needs attention" : nav.online ? "Queued for sync" : "Saved locally"

  return <div className="fo-screen flex min-h-full flex-col pb-2">
    <ScreenHeader title={step === "review" ? "Review dispatch" : step === "complete" ? completeTitle : "Dispatch"} subtitle={`${doc.ref} · ${doc.customerName}`} onBack={back} />
    {step === "overview" && <><div className="space-y-4 px-5">
      <div className="rounded-2xl border border-hairline bg-white p-4"><div className="flex items-center justify-between"><b>{doc.ref}</b><StatusChip tone={doc.priority === "HIGH" ? "danger" : "brand"}>{doc.status}</StatusChip></div><p className="mt-2 text-[13px] text-ink-faint">{doc.sourceName} → {doc.destinationName}</p></div>
      <div className="rounded-2xl border border-hairline bg-white p-4"><div className="flex justify-between text-[13px]"><b>Lines accounted</b><b className="text-brand">{done}/{doc.lines.length}</b></div><ProgressBar className="mt-2.5" value={doc.lines.length ? (done/doc.lines.length)*100 : 0} /></div>
      <div className="space-y-2.5">{doc.lines.map((entry) => { const terminal=lineLocalTerminal(entry.id); const local=draft.state.lines[entry.id]; return <button key={entry.id} disabled={terminal} onClick={() => selectLine(entry.id)} className="flex w-full items-center justify-between rounded-2xl border border-hairline bg-white p-3.5 text-left disabled:opacity-70"><div><p className="text-[14px] font-semibold">{entry.productName}</p><p className="text-[13px] text-ink-faint">{entry.sku} · {entry.sourceBinCode} · req. {entry.requestedBaseQuantity} {entry.unitCode}</p></div><StatusChip tone={terminal?"success":"neutral"}>{local?.captureCommandId?"Saved":terminal?entry.lineStatus:"Pending"}</StatusChip></button> })}</div>
    </div><StickyBar><div className="grid grid-cols-[1fr_auto] gap-2.5"><Button icon="scan" onClick={() => nav.openScan("dispatch")}>Scan to pick</Button><Button variant="secondary" className={`!w-auto px-5 ${allTerminal ? "" : "pointer-events-none opacity-50"}`} onClick={() => { if (allTerminal) draft.updateState((current)=>({...current,step:"review"})) }}>Review</Button></div></StickyBar></>}

    {step === "pick" && <div className="flex flex-1 flex-col"><div className="space-y-4 px-5"><div className="rounded-2xl border border-hairline bg-white p-4"><p className="text-[15px] font-bold">{line.productName}</p><p className="text-[13px] text-ink-faint">{line.sku} · Bin {line.sourceBinCode} · UOM {line.unitCode}</p></div><div className="rounded-2xl border border-hairline bg-white p-4"><div className="mb-3 flex justify-between text-[13px]"><span>Requested</span><b>{line.requestedBaseQuantity} {line.unitCode}</b></div><QtyStepper value={picked} onChange={(value)=>setLineDraft({picked:value})} unit={line.unitCode} step={item.quantityStep} scale={item.quantityScale} max={line.requestedBaseQuantity} autoFocus /></div></div><StickyBar>{picked === line.requestedBaseQuantity ? <Button icon="check" onClick={()=>void queueLine(null,null,false)}>Save pick</Button> : <Button onClick={()=>draft.updateState((current)=>({...current,step:"shortage"}))}>Record partial / shortage</Button>}</StickyBar></div>}

    {step === "shortage" && <div className="flex flex-1 flex-col"><div className="space-y-4 px-5"><div className="rounded-2xl border border-warning/25 bg-warning-soft p-4"><p className="font-bold">Partial fulfillment</p><p className="text-[13px]">Picked {picked} of {line.requestedBaseQuantity}; {remainingToAccount} will be backordered.</p></div><ReasonSelector reasons={shortageReasons} value={reason} onChange={(value)=>setLineDraft({exceptionCode:value})} label="Reason" /><textarea value={reasonText} onChange={(event)=>setLineDraft({reasonText:event.target.value})} placeholder="Optional detail" className="min-h-24 w-full rounded-xl border border-hairline bg-white p-3 text-[14px]" /></div><StickyBar><Button onClick={()=>void queueLine(reason,reasonText||null,true)}>Save partial & backorder</Button></StickyBar></div>}

    {step === "review" && <div className="flex flex-1 flex-col"><div className="space-y-4 px-5"><div className={`rounded-2xl border p-4 ${allTerminal && stockRevisionReady?"border-success/25 bg-success-soft":"border-warning/25 bg-warning-soft"}`}><p className="font-bold">{allTerminal && stockRevisionReady?"Ready to queue authoritative dispatch":!stockRevisionReady?"Reconnect to refresh stock revisions before final dispatch":"Required lines are still pending"}</p><p className="mt-1 text-[13px]">{done}/{doc.lines.length} lines are captured or durably queued.</p></div>{doc.lines.map((entry)=><div key={entry.id} className="flex justify-between rounded-xl border border-hairline bg-white p-3 text-[13px]"><span>{entry.sku}</span><span>{draft.state.lines[entry.id]?.picked ?? entry.capturedPickedBaseQuantity}/{entry.requestedBaseQuantity}</span></div>)}</div><StickyBar><Button onClick={()=>void queueFinal()} className={allTerminal && stockRevisionReady?"":"pointer-events-none opacity-50"}>Queue dispatch</Button></StickyBar></div>}

    {step === "complete" && <div className="flex flex-1 flex-col items-center justify-center px-7 text-center"><span className="grid h-20 w-20 place-items-center rounded-3xl bg-brand-soft text-brand"><Icon name={finalOp?.state === "confirmed"?"check-circle":"cloud-sync"} className="h-10 w-10" /></span><h2 className="mt-5 text-[20px] font-extrabold">{completeTitle}</h2><p className="mt-2 text-[14px] text-ink-soft">The stable dispatch command is retained through retry/restart. Completion is authoritative only after server confirmation.</p><div className="mt-4"><SyncBadge state={finalOp?.state === "confirmed"?"confirmed":finalOp?.state === "failed"?"failed":finalOp?.state === "conflict"?"conflict":"queued"} /></div><div className="mt-8 w-full space-y-2.5"><Button onClick={()=>nav.go("sync")}>View in Sync Center</Button><Button variant="secondary" onClick={()=>nav.go("home")}>Back to home</Button></div></div>}
  </div>
}

function Missing({nav,message}:{nav:Nav;message:string}){return <div className="fo-screen"><ScreenHeader title="Dispatch" subtitle="Unable to load sales order" onBack={()=>nav.go("work")} /><div className="px-5"><div className="rounded-2xl border border-warning/25 bg-warning-soft p-4 text-[14px]">{message}</div></div></div>}
