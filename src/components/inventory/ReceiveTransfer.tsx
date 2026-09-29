import { useEffect, useMemo } from "react"
import { ScreenHeader } from "../PhoneFrame"
import Icon from "../ui/Icon"
import { Button, ConnState, ProgressBar, QtyStepper, ReasonSelector, StatusChip, StickyBar, SyncBadge } from "../ui/primitives"
import type { Nav } from "./types"
import { useTransferDocument } from "../../lib/documents"
import { enqueueCommand } from "../../lib/syncEngine"
import { useDurableWorkflowDraft } from "../../lib/useDurableWorkflowDraft"
import { useItems } from "../../lib/queries"
import { itemById as dataItemById } from "./models"

type Step = "overview" | "execute" | "exception" | "review" | "complete"
type LineDraft = { received: number; exceptionCode: string | null; note: string; commandId: string | null; dispositionCommandId: string | null }
type ReceiveDraftState = Record<string, unknown> & {
  step: Step
  selectedLineId: string | null
  lines: Record<string, LineDraft>
  commandIds: string[]
  finalQueued: boolean
}

const exceptionReasons = ["Shortage", "Overage", "Damaged", "Wrong item", "Extra / unexpected"]
const shortageCodes = new Set(["Shortage", "SHORTAGE", "SHORT_RECEIPT"])

function dispositionForException(code: string | null) {
  if (!code || shortageCodes.has(code)) return null
  const normalized = code.trim().toUpperCase().replace(/\s+/g, "_")
  if (normalized === "DAMAGED") return "ACCEPT_DAMAGED" as const
  if (normalized === "WRONG_ITEM" || normalized === "WRONG") return "REJECT_WRONG_ITEM" as const
  if (normalized === "OVERAGE") return "ACCEPT_EXPECTED_REJECT_OVERAGE" as const
  if (["EXTRA_/_UNEXPECTED", "EXTRA_UNEXPECTED", "UNEXPECTED"].includes(normalized)) return "REJECT_UNEXPECTED" as const
  return null
}

export default function ReceiveTransfer({ nav, startExecuting }: { nav: Nav; startExecuting?: boolean }) {
  const documentId = nav.activeTaskId
  const { data: doc, isLoading, error } = useTransferDocument(documentId)
  const owner = useMemo(() => ({ authUserId: nav.authUserId, companyId: nav.companyId, locationId: nav.locationId }), [nav.authUserId, nav.companyId, nav.locationId])
  const initialState: ReceiveDraftState = useMemo(() => ({ step: startExecuting ? "execute" : "overview", selectedLineId: nav.scanLineId, lines: {}, commandIds: [], finalQueued: false }), [documentId])
  const draft = useDurableWorkflowDraft<ReceiveDraftState>({ owner, kind: "receive", documentId, documentRef: doc?.ref ?? "", serverRevision: doc?.revision ?? 0, initialState })
  const { data: items = [] } = useItems()

  useEffect(() => {
    if (!draft.hydrated || !doc || draft.state.selectedLineId) return
    const next = doc.lines.find((line) => line.lineStatus === "OPEN" || line.lineStatus === "IN_PROGRESS" || line.lineStatus === "EXCEPTION") ?? doc.lines[0]
    if (next) draft.updateState((current) => ({ ...current, selectedLineId: next.id }))
  }, [doc, draft.hydrated, draft.state.selectedLineId, draft.updateState])

  if (!documentId) return <Missing nav={nav} message="No authoritative transfer is selected." />
  if (isLoading && !doc) return <Missing nav={nav} message="Loading transfer…" />
  if (error && !doc) return <Missing nav={nav} message="Transfer is unavailable and no offline snapshot is stored." />
  if (!doc) return <Missing nav={nav} message="Transfer not found." />

  const selectedLine = doc.lines.find((line) => line.id === draft.state.selectedLineId) ?? doc.lines[0]
  if (!selectedLine) return <Missing nav={nav} message="Transfer has no lines." />
  const item = dataItemById(selectedLine.productId, items)
  const saved = draft.state.lines[selectedLine.id]
  const received = saved?.received ?? selectedLine.capturedReceivedBaseQuantity ?? selectedLine.expectedBaseQuantity
  const reason = saved?.exceptionCode ?? exceptionReasons[0]
  const note = saved?.note ?? selectedLine.exceptionNotes ?? ""
  const variance = received - selectedLine.expectedBaseQuantity

  const lineCaptureTerminal = (lineId: string) => Boolean(draft.state.lines[lineId]?.commandId) || !["OPEN", "IN_PROGRESS"].includes(doc.lines.find((line) => line.id === lineId)?.lineStatus ?? "")
  const lineBusinessResolved = (lineId: string) => {
    if (!lineCaptureTerminal(lineId)) return false
    const line = doc.lines.find((candidate) => candidate.id === lineId)
    const local = draft.state.lines[lineId]
    const code = local?.exceptionCode ?? line?.exceptionCode ?? null
    if (code && !shortageCodes.has(code)) return Boolean(local?.dispositionCommandId || line?.dispositionStatus)
    return true
  }
  const done = doc.lines.filter((line) => lineBusinessResolved(line.id)).length
  const allTerminal = doc.lines.length > 0 && doc.lines.every((line) => lineBusinessResolved(line.id))
  const pending = doc.lines.length - done
  const unresolvedExceptions = doc.lines.filter((entry) => {
    const local = draft.state.lines[entry.id]
    const code = local?.exceptionCode ?? entry.exceptionCode
    const needsDisposition = Boolean(code && !shortageCodes.has(code))
    const resolved = Boolean(local?.dispositionCommandId || entry.dispositionStatus)
    return needsDisposition && !resolved
  })
  const stockRevisionReady = Boolean(doc.stockPreconditions?.length)
  const receiptReady = allTerminal && unresolvedExceptions.length === 0 && stockRevisionReady

  const setLineDraft = (patch: Partial<LineDraft>) => {
    draft.updateState((current) => ({
      ...current,
      lines: {
        ...current.lines,
        [selectedLine.id]: {
          received,
          exceptionCode: saved?.exceptionCode ?? null,
          note,
          commandId: saved?.commandId ?? null,
          dispositionCommandId: saved?.dispositionCommandId ?? null,
          ...patch,
        },
      },
    }))
  }

  const selectLine = (lineId: string) => {
    if (lineCaptureTerminal(lineId)) return
    draft.updateState((current) => ({ ...current, selectedLineId: lineId, step: "execute" }))
  }

  const queueCapture = async (exceptionCode: string | null, exceptionNotes: string | null) => {
    if (lineCaptureTerminal(selectedLine.id)) return
    const commandId = saved?.commandId ?? crypto.randomUUID()
    const disposition = dispositionForException(exceptionCode)
    if (exceptionCode && !shortageCodes.has(exceptionCode) && !disposition) throw new Error("Unsupported receipt exception disposition")
    const dispositionCommandId = disposition ? (saved?.dispositionCommandId ?? crypto.randomUUID()) : null
    const clientRecordedAt = new Date().toISOString()
    const previous = draft.state.commandIds[draft.state.commandIds.length - 1]
    await enqueueCommand({
      id: commandId,
      owner,
      kind: "transfer_line_capture",
      ref: doc.ref,
      label: "Receipt line capture",
      documentId: doc.id,
      clientRecordedAt,
      dependencyIds: previous ? [previous] : [],
      payload: {
        lineId: selectedLine.id,
        documentId: doc.id,
        expectedRevision: draft.localRevision,
        receivedQuantity: received,
        unitId: selectedLine.unitId,
        destinationBinId: selectedLine.destinationBinId,
        exceptionCode,
        exceptionNotes,
        clientRecordedAt,
      },
    })
    if (disposition && dispositionCommandId) {
      await enqueueCommand({
        id: dispositionCommandId,
        owner,
        kind: "transfer_exception_disposition",
        ref: doc.ref,
        label: "Resolve receipt exception",
        documentId: doc.id,
        clientRecordedAt,
        dependencyIds: [commandId],
        payload: {
          lineId: selectedLine.id,
          documentId: doc.id,
          expectedRevision: draft.localRevision + 1,
          commandId: dispositionCommandId,
          disposition,
          reasonText: exceptionNotes?.trim() || exceptionCode || "Receipt exception disposition",
          clientRecordedAt,
        },
      })
    }
    setLineDraft({ received, exceptionCode, note: exceptionNotes ?? "", commandId, dispositionCommandId })
    draft.updateState((current) => {
      const ids = [commandId, ...(dispositionCommandId ? [dispositionCommandId] : [])]
      return { ...current, commandIds: [...current.commandIds, ...ids.filter((id) => !current.commandIds.includes(id))] }
    })
    draft.advanceRevision(dispositionCommandId ? 2 : 1)
    await nav.refreshQueue()

    const next = doc.lines.find((line) => line.id !== selectedLine.id && !lineCaptureTerminal(line.id))
    draft.updateState((current) => ({ ...current, selectedLineId: next?.id ?? selectedLine.id, step: next ? "execute" : "review" }))
  }

  const queueExistingDisposition = async (lineId: string) => {
    const line = doc.lines.find((candidate) => candidate.id === lineId)
    if (!line || line.dispositionStatus) return
    const disposition = dispositionForException(line.exceptionCode)
    if (!disposition) return
    const existing = draft.state.lines[line.id]
    const commandId = existing?.dispositionCommandId ?? crypto.randomUUID()
    const clientRecordedAt = new Date().toISOString()
    const previous = draft.state.commandIds[draft.state.commandIds.length - 1]
    await enqueueCommand({
      id: commandId,
      owner,
      kind: "transfer_exception_disposition",
      ref: doc.ref,
      label: "Resolve receipt exception",
      documentId: doc.id,
      clientRecordedAt,
      dependencyIds: previous ? [previous] : [],
      payload: {
        lineId: line.id,
        documentId: doc.id,
        expectedRevision: draft.localRevision,
        commandId,
        disposition,
        reasonText: line.exceptionNotes?.trim() || line.exceptionCode || "Receipt exception disposition",
        clientRecordedAt,
      },
    })
    draft.updateState((current) => ({
      ...current,
      lines: {
        ...current.lines,
        [line.id]: {
          received: existing?.received ?? line.capturedReceivedBaseQuantity,
          exceptionCode: existing?.exceptionCode ?? line.exceptionCode,
          note: existing?.note ?? line.exceptionNotes ?? "",
          commandId: existing?.commandId ?? null,
          dispositionCommandId: commandId,
        },
      },
      commandIds: current.commandIds.includes(commandId) ? current.commandIds : [...current.commandIds, commandId],
    }))
    draft.advanceRevision()
    await nav.refreshQueue()
  }

  const queueFinal = async () => {
    if (!receiptReady) return
    const commandId = await draft.ensureFinalCommandId()
    const clientRecordedAt = new Date().toISOString()
    await enqueueCommand({
      id: commandId,
      owner,
      kind: "transfer_receive",
      ref: doc.ref,
      label: "Receive transfer",
      documentId: doc.id,
      clientRecordedAt,
      dependencyIds: draft.state.commandIds,
      payload: { documentId: doc.id, expectedRevision: draft.localRevision, commandId, allowPartial: true, clientRecordedAt, stockPreconditions: doc.stockPreconditions },
    })
    draft.updateState((current) => ({ ...current, finalQueued: true, step: "complete" }))
    await nav.refreshQueue()
  }

  const step = draft.state.step
  const back = () => {
    if (step === "overview") nav.go("work")
    else draft.updateState((current) => ({ ...current, step: step === "review" ? "overview" : step === "exception" ? "execute" : "overview" }))
  }
  const finalOp = draft.finalCommandId ? nav.syncOps.find((operation) => operation.id === draft.finalCommandId) : undefined
  const completeTitle = finalOp?.state === "confirmed" ? "Receipt confirmed" : finalOp?.state === "conflict" || finalOp?.state === "blocked" ? "Receipt needs attention" : nav.online ? "Queued for sync" : "Saved locally"

  return (
    <div className="fo-screen flex min-h-full flex-col pb-2">
      <ScreenHeader title={step === "review" ? "Review & queue" : step === "complete" ? completeTitle : "Receive Transfer"} subtitle={`${doc.ref} · ${doc.destinationName}`} onBack={back} />
      {step === "overview" && <>
        <div className="space-y-4 px-5">
          <div className="rounded-2xl border border-hairline bg-white p-4">
            <div className="flex items-center justify-between"><span className="font-extrabold">{doc.ref}</span><StatusChip tone="brand">{doc.status}</StatusChip></div>
            <p className="mt-2 text-[13px] text-ink-faint">{doc.sourceName} → {doc.destinationName}</p>
          </div>
          <div className="rounded-2xl border border-hairline bg-white p-4">
            <div className="flex justify-between text-[13px]"><b>Captured locally/server</b><b className="text-brand">{done}/{doc.lines.length}</b></div>
            <ProgressBar className="mt-2.5" value={doc.lines.length ? (done / doc.lines.length) * 100 : 0} />
            <p className="mt-2 text-[13px] text-ink-faint">{pending} required line{pending === 1 ? "" : "s"} remaining</p>
          </div>
          <ConnState online={nav.online} detail={nav.online ? "Server reachable when sync succeeds" : "Draft and commands are stored on this device"} />
          <div className="space-y-2.5">
            {doc.lines.map((line) => {
              const local = draft.state.lines[line.id]
              const terminal = lineCaptureTerminal(line.id)
              return <button key={line.id} disabled={terminal} onClick={() => selectLine(line.id)} className="flex w-full items-center justify-between rounded-2xl border border-hairline bg-white p-3.5 text-left disabled:opacity-70">
                <div><p className="text-[14px] font-semibold">{line.productName}</p><p className="text-[13px] text-ink-faint">{line.sku} · {line.destinationBinCode} · exp. {line.expectedBaseQuantity} {line.unitCode}</p></div>
                <StatusChip tone={lineBusinessResolved(line.id) ? "success" : terminal ? "warning" : "neutral"}>{local?.dispositionCommandId ? "Disposition saved" : terminal && !lineBusinessResolved(line.id) ? "Disposition needed" : local?.commandId ? "Saved" : terminal ? line.lineStatus : "Pending"}</StatusChip>
              </button>
            })}
          </div>
        </div>
        <StickyBar><div className="grid grid-cols-[1fr_auto] gap-2.5"><Button icon="scan" onClick={() => nav.openScan("receive")}>Scan to receive</Button><Button variant="secondary" className="!w-auto px-5" onClick={() => draft.updateState((current) => ({ ...current, step: "review" }))}>Review</Button></div></StickyBar>
      </>}

      {step === "execute" && <div className="flex flex-1 flex-col"><div className="space-y-4 px-5">
        <div className="rounded-2xl border border-hairline bg-white p-4"><p className="text-[15px] font-bold">{selectedLine.productName}</p><p className="text-[13px] text-ink-faint">{selectedLine.sku} · Bin {selectedLine.destinationBinCode} · UOM {selectedLine.unitCode}</p></div>
        <div className="rounded-2xl border border-hairline bg-white p-4"><div className="mb-3 flex justify-between text-[13px]"><span>Expected</span><b>{selectedLine.expectedBaseQuantity} {selectedLine.unitCode}</b></div><QtyStepper value={received} onChange={(value) => setLineDraft({ received: value })} unit={selectedLine.unitCode} step={item.quantityStep} scale={item.quantityScale} autoFocus />{variance !== 0 && <p className="mt-3 text-[13px] font-semibold text-danger">{variance < 0 ? `${Math.abs(variance)} short` : `${variance} over`} — record an exception.</p>}</div>
      </div><StickyBar><div className="space-y-2"><Button icon="check" onClick={() => void queueCapture(null, null)}>{variance === 0 ? "Save as accepted" : "Save quantity only"}</Button><Button variant="secondary" onClick={() => draft.updateState((current) => ({ ...current, step: "exception" }))}>Record condition / identity exception</Button></div></StickyBar></div>}

      {step === "exception" && <div className="flex flex-1 flex-col"><div className="space-y-4 px-5"><div className="rounded-2xl border border-danger/25 bg-danger-soft p-4"><p className="font-bold">Exception on {selectedLine.sku}</p><p className="text-[13px]">Expected {selectedLine.expectedBaseQuantity}; physically received {received}.</p></div><ReasonSelector reasons={exceptionReasons} value={reason} onChange={(value) => setLineDraft({ exceptionCode: value })} label="Exception reason" /><textarea value={note} onChange={(event) => setLineDraft({ note: event.target.value })} placeholder="Add note" className="min-h-24 w-full rounded-xl border border-hairline bg-white p-3 text-[14px]" /></div><StickyBar><Button onClick={() => void queueCapture(reason, note || null)}>Save exception</Button></StickyBar></div>}

      {step === "review" && <div className="flex flex-1 flex-col"><div className="space-y-4 px-5"><div className={`rounded-2xl border p-4 ${receiptReady ? "border-success/25 bg-success-soft" : "border-warning/25 bg-warning-soft"}`}><p className="font-bold">{receiptReady ? "Ready to queue authoritative receipt" : !stockRevisionReady ? "Reconnect to refresh stock revisions before final receipt" : unresolvedExceptions.length ? "Exception disposition required" : "Required lines are still pending"}</p><p className="mt-1 text-[13px] text-ink-soft">{done}/{doc.lines.length} lines captured. {unresolvedExceptions.length ? `${unresolvedExceptions.length} condition/identity exception(s) remain blocked from posting.` : ""}</p></div>{doc.lines.map((line) => {
          const local = draft.state.lines[line.id]
          const code = local?.exceptionCode ?? line.exceptionCode
          const needsDisposition = Boolean(code && !shortageCodes.has(code))
          const resolved = Boolean(local?.dispositionCommandId || line.dispositionStatus)
          return <div key={line.id} className="rounded-xl border border-hairline bg-white p-3 text-[13px]"><div className="flex justify-between"><span>{line.sku}</span><span>{local?.received ?? line.capturedReceivedBaseQuantity}/{line.expectedBaseQuantity}</span></div>{needsDisposition && <div className="mt-2 flex items-center justify-between gap-3"><span className={resolved ? "text-success" : "text-warning"}>{resolved ? `Disposition ${line.dispositionStatus === "APPLIED" ? "applied" : "queued/resolved"}` : "Disposition required"}</span>{!resolved && <Button variant="secondary" className="!w-auto px-3 py-2 text-[12px]" onClick={() => void queueExistingDisposition(line.id)}>Queue disposition</Button>}</div>}</div>
        })}</div><StickyBar><Button onClick={() => void queueFinal()} className={receiptReady ? "" : "pointer-events-none opacity-50"}>Queue receipt</Button></StickyBar></div>}

      {step === "complete" && <div className="flex flex-1 flex-col items-center justify-center px-7 text-center"><span className="grid h-20 w-20 place-items-center rounded-3xl bg-brand-soft text-brand"><Icon name={finalOp?.state === "confirmed" ? "check-circle" : "cloud-sync"} className="h-10 w-10" /></span><h2 className="mt-5 text-[20px] font-extrabold">{completeTitle}</h2><p className="mt-2 text-[14px] text-ink-soft">Stable command {draft.finalCommandId?.slice(0, 8)}… is preserved for every retry. The document is complete only after the server confirms it.</p><div className="mt-4"><SyncBadge state={finalOp?.state === "confirmed" ? "confirmed" : finalOp?.state === "failed" ? "failed" : finalOp?.state === "conflict" ? "conflict" : "queued"} /></div><div className="mt-8 w-full space-y-2.5"><Button onClick={() => nav.go("sync")}>View in Sync Center</Button><Button variant="secondary" onClick={() => nav.go("home")}>Back to home</Button></div></div>}
    </div>
  )
}

function Missing({ nav, message }: { nav: Nav; message: string }) {
  return <div className="fo-screen"><ScreenHeader title="Receive Transfer" subtitle="Unable to load transfer" onBack={() => nav.go("work")} /><div className="px-5"><div className="rounded-2xl border border-warning/25 bg-warning-soft p-4 text-[14px]">{message}</div></div></div>
}
