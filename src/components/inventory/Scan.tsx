import { useEffect, useMemo, useRef, useState } from "react"
import Icon from "../ui/Icon"
import { Button } from "../ui/primitives"
import type { Nav, ScanContext } from "./types"
import { useItems } from "../../lib/queries"
import { resolveInventoryIdentifier, useSalesOrderDocument, useTransferDocument, type IdentifierCandidate } from "../../lib/documents"
import { enqueueCommand } from "../../lib/syncEngine"
import { ProductionScanner, type ScannerLifecycle } from "../../lib/scanner"

type ScanState = "ready" | "manual" | "starting" | "denied" | "unsupported" | "success" | "invalid" | "unknown" | "duplicate" | "ambiguous" | "reported"

const contextCopy: Record<ScanContext, { verb: string; hint: string; action: string }> = {
  browse: { verb: "Look up", hint: "Scan any item to view stock", action: "View item" },
  receive: { verb: "Receive", hint: "Scan the item on this transfer", action: "Receive line" },
  dispatch: { verb: "Pick", hint: "Scan the item on this order", action: "Confirm pick" },
}

export default function Scan({ nav }: { nav: Nav }) {
  const ctx = nav.scanContext
  const copy = contextCopy[ctx]
  const [state, setState] = useState<ScanState>("ready")
  const [torch, setTorch] = useState(false)
  const [entry, setEntry] = useState("")
  const [message, setMessage] = useState("")
  const [resolvedSku, setResolvedSku] = useState<string | null>(null)
  const [candidates, setCandidates] = useState<IdentifierCandidate[]>([])
  const [selected, setSelected] = useState<IdentifierCandidate | null>(null)
  const [lastCode, setLastCode] = useState("")
  const videoRef = useRef<HTMLVideoElement | null>(null)
  const scannerRef = useRef<ProductionScanner | null>(null)
  const { data: items = [] } = useItems()
  const task = nav.workItems.find((candidate) => candidate.id === nav.activeTaskId)
  const documentId = ctx === "browse" ? null : nav.activeTaskId
  const transfer = useTransferDocument(ctx === "receive" ? documentId : null)
  const order = useSalesOrderDocument(ctx === "dispatch" ? documentId : null)

  const owner = useMemo(() => ({ authUserId: nav.authUserId, companyId: nav.companyId, locationId: nav.locationId }), [nav.authUserId, nav.companyId, nav.locationId])

  const stopCamera = () => scannerRef.current?.stopCamera()

  const resolveCode = async (raw: string) => {
    const code = raw.trim()
    if (!code) { setState("invalid"); return }
    setLastCode(code)
    setMessage("")
    try {
      const result = await resolveInventoryIdentifier({ locationId: nav.locationId, code, context: ctx, documentId })
      setResolvedSku(result.sku)
      setCandidates(result.candidates)
      if (result.status === "unknown" || result.status === "non_actionable") { setState("unknown"); return }
      if (result.status === "invalid") { setState("invalid"); return }
      if (result.status === "ambiguous") { setSelected(null); setState("ambiguous"); return }
      if (ctx === "browse") { setSelected(null); setState("success"); return }
      const candidate = result.candidates[0]
      if (!candidate) { setState("unknown"); return }
      setSelected(candidate); setState("success")
    } catch (error) {
      // Offline fallback is intentionally exact and document-local; barcode aliases require server/snapshot authority.
      const normalized = code.replace(/\s+/g, "").toLowerCase()
      if (!nav.online && ctx !== "browse") {
        const rawLines = ctx === "receive" ? transfer.data?.lines ?? [] : order.data?.lines ?? []
        const exact = rawLines.filter((line) => line.sku.replace(/\s+/g, "").toLowerCase() === normalized && ["OPEN", "IN_PROGRESS", "EXCEPTION", "READY_TO_POST"].includes(line.lineStatus))
        const mapped = exact.map((line) => ({
          lineId: line.id, lineNumber: line.lineNumber, productId: line.productId, productName: line.productName, sku: line.sku,
          binId: ctx === "receive" ? (line as import("../../lib/documents").TransferLineDocument).destinationBinId : (line as import("../../lib/documents").SalesOrderLineDocument).sourceBinId,
          binCode: ctx === "receive" ? (line as import("../../lib/documents").TransferLineDocument).destinationBinCode : (line as import("../../lib/documents").SalesOrderLineDocument).sourceBinCode,
          lineStatus: line.lineStatus,
        }))
        if (mapped.length === 1) { setSelected(mapped[0]); setResolvedSku(mapped[0].sku); setState("success"); return }
        if (mapped.length > 1) { setCandidates(mapped); setState("ambiguous"); return }
      }
      setMessage(error instanceof Error ? error.message : String(error))
      setState("unknown")
    }
  }

  useEffect(() => {
    const scanner = new ProductionScanner(
      (decode) => void resolveCode(decode.code),
      (lifecycle: ScannerLifecycle, detail) => {
        if (lifecycle === "starting") setState("starting")
        if (lifecycle === "active") setState("ready")
        if (lifecycle === "denied") { setMessage(detail ?? "Camera permission denied"); setState("denied") }
        if (lifecycle === "unsupported") { setMessage(detail ?? "Camera barcode detection unsupported"); setState("unsupported") }
        if (lifecycle === "error") { setMessage(detail ?? "Camera error"); setState("unsupported") }
      },
      () => setState("duplicate"),
    )
    scanner.attachHardwareScanner()
    scannerRef.current = scanner
    return () => { scanner.destroy(); scannerRef.current = null }
  }, [ctx, documentId, nav.locationId])

  const startCamera = async () => { if (videoRef.current) await scannerRef.current?.startCamera(videoRef.current) }
  const toggleTorch = async () => { const next = !torch; if (await scannerRef.current?.setTorch(next)) setTorch(next) }

  const continueResolved = () => {
    stopCamera()
    if (ctx === "browse") {
      const local = items.find((item) => item.sku.toLowerCase() === (resolvedSku ?? "").toLowerCase())
      if (local) nav.openItem(local.id)
      else if (resolvedSku) nav.openItem(resolvedSku)
    } else if (selected) nav.enterFlowExecuting(ctx, selected.lineId)
  }

  const reportUnknown = async () => {
    const rawCode = lastCode.trim()
    if (!rawCode) return
    const id = crypto.randomUUID()
    await enqueueCommand({
      id, owner, kind: "unknown_scan_report", ref: task?.ref ?? "UNKNOWN-SCAN", label: "Unknown scan report", documentId,
      clientRecordedAt: new Date().toISOString(), dependencyIds: [],
      payload: { rawCode, context: ctx, documentType: ctx === "receive" ? "TRANSFER" : ctx === "dispatch" ? "SALES_ORDER" : null, documentId },
    })
    await nav.refreshQueue()
    setState("reported")
  }

  if (ctx !== "browse" && !task) return <DarkMissing nav={nav} />

  return <div className="fo-screen flex min-h-full flex-col bg-[#0c1033] pb-6 text-white">
    <div className="flex items-center justify-between px-5 pb-3 pt-3">
      <button onClick={() => { stopCamera(); nav.go(ctx === "browse" ? "home" : ctx) }} className="grid h-9 w-9 place-items-center rounded-full bg-white/10"><Icon name="x" className="h-5 w-5" /></button>
      <div className="text-center"><p className="text-[15px] font-bold">{copy.verb} · Scan</p><p className="text-[13px] uppercase tracking-wide text-white/50">{ctx} mode</p></div>
      <button onClick={() => void toggleTorch()} className={`grid h-9 w-9 place-items-center rounded-full ${torch ? "bg-warning" : "bg-white/10"}`}><Icon name={torch ? "flash" : "flash-off"} className="h-5 w-5" /></button>
    </div>

    <div className="relative mx-5 flex-1 overflow-hidden rounded-3xl border border-white/10 bg-black/40">
      <video ref={videoRef} muted className="absolute inset-0 h-full w-full object-cover opacity-70" />
      <div className="absolute inset-0 bg-[radial-gradient(120%_80%_at_50%_0%,rgba(68,76,250,0.2),transparent_60%)]" />
      {state === "success" ? <StateOverlay icon="package-check" tone="success" title="Exact match" body={selected ? `${selected.productName} · ${selected.sku} · Bin ${selected.binCode}` : `${resolvedSku ?? "Item"}`} primary={{ label: copy.action, onClick: continueResolved }} secondary={{ label: "Scan next", onClick: () => setState("ready") }} />
      : state === "ambiguous" ? <div className="absolute inset-0 overflow-auto p-5"><div className="mt-10 rounded-2xl bg-[#161b49]/95 p-4"><p className="font-bold">Choose the exact document line</p><p className="mt-1 text-[13px] text-white/65">This identifier matches multiple actionable lines. Bin and line identity are required.</p><div className="mt-4 space-y-2">{candidates.map((candidate) => <button key={candidate.lineId} onClick={() => { setSelected(candidate); setState("success") }} className="w-full rounded-xl border border-white/15 bg-white/10 p-3 text-left"><b>Line {candidate.lineNumber} · Bin {candidate.binCode}</b><p className="text-[13px] text-white/60">{candidate.productName} · {candidate.sku}</p></button>)}</div></div></div>
      : state === "unknown" ? <StateOverlay icon="alert" tone="warning" title="Unknown or non-actionable identifier" body={message || "No exact product/actionable document line matches this identifier."} primary={{ label: "Report unknown", onClick: () => void reportUnknown() }} secondary={{ label: "Scan again", onClick: () => setState("ready") }} />
      : state === "reported" ? <StateOverlay icon="check-circle" tone="success" title="Unknown scan saved" body="The event is durably queued with actor, warehouse, document context and timestamp." primary={{ label: "Scan next", onClick: () => setState("ready") }} />
      : state === "invalid" ? <StateOverlay icon="x-circle" tone="danger" title="Invalid code" body="Enter or scan a non-empty exact identifier." primary={{ label: "Try again", onClick: () => setState("ready") }} />
      : state === "denied" || state === "unsupported" ? <StateOverlay icon="cloud-off" tone="warning" title={state === "denied" ? "Camera access needed" : "Camera scanner unavailable"} body={message || "Use a supported hardware scanner or exact manual entry."} primary={{ label: "Enter manually", onClick: () => setState("manual") }} />
      : state === "duplicate" ? <StateOverlay icon="alert" tone="warning" title="Duplicate scan suppressed" body="The same code was decoded again inside the duplicate-suppression window; no second warehouse action was accepted." primary={{ label: "Continue scanning", onClick: () => setState("ready") }} />
      : state === "manual" ? <div className="absolute inset-0 flex flex-col justify-center gap-4 p-6"><div className="flex items-center gap-2 text-white/70"><Icon name="keyboard" className="h-5 w-5" /><span className="text-[13px] font-semibold">Exact manual identifier</span></div><input autoFocus value={entry} onChange={(event)=>setEntry(event.target.value)} placeholder="Exact SKU / barcode / GTIN" className="w-full rounded-xl border border-white/15 bg-white/10 px-4 py-3.5 text-[15px] text-white placeholder:text-white/40" /><div className="flex gap-2.5"><button onClick={()=>setState("ready")} className="h-12 flex-1 rounded-xl border border-white/15 text-[14px] font-semibold">Back</button><button onClick={()=>void resolveCode(entry)} className="h-12 flex-1 rounded-xl bg-brand text-[14px] font-semibold">Resolve exact</button></div></div>
      : <div className="absolute inset-0 flex flex-col items-center justify-center"><div className="relative h-52 w-56">{["left-0 top-0 border-l-2 border-t-2 rounded-tl-xl","right-0 top-0 border-r-2 border-t-2 rounded-tr-xl","left-0 bottom-0 border-l-2 border-b-2 rounded-bl-xl","right-0 bottom-0 border-r-2 border-b-2 rounded-br-xl"].map((className)=><span key={className} className={`absolute h-9 w-9 border-brand ${className}`} />)}<div className="fo-scanline absolute left-3 right-3 h-0.5 rounded bg-brand" /></div><p className="mt-6 text-[13px] text-white/70">{state === "starting" ? "Starting camera…" : copy.hint}</p></div>}
    </div>

    <div className="space-y-3 px-5 pt-4"><div className="flex gap-2.5"><FooterBtn icon="scan" label="Start camera" onClick={() => void startCamera()} /><FooterBtn icon="keyboard" label="Manual" onClick={()=>setState("manual")} /></div><p className="text-center text-[11px] text-white/45">USB/Bluetooth keyboard-wedge scanners are accepted automatically. Transactional matching is exact only.</p></div>
  </div>
}

function DarkMissing({nav}:{nav:Nav}){return <div className="fo-screen flex min-h-full items-center justify-center bg-[#0c1033] px-7 text-center text-white"><div><p className="font-bold">No authoritative work item selected</p><button onClick={() => nav.go("work")} className="mt-4 rounded-xl bg-brand px-4 py-3 text-[14px] font-semibold">Back to work</button></div></div>}
function FooterBtn({icon,label,onClick}:{icon:Parameters<typeof Icon>[0]["name"];label:string;onClick:()=>void}){return <button onClick={onClick} className="flex h-12 flex-1 items-center justify-center gap-2 rounded-xl border border-white/15 bg-white/10 text-[14px] font-semibold"><Icon name={icon} className="h-4.5 w-4.5" />{label}</button>}
function StateOverlay({icon,tone,title,body,primary,secondary}:{icon:Parameters<typeof Icon>[0]["name"];tone:"success"|"danger"|"warning";title:string;body:string;primary:{label:string;onClick:()=>void};secondary?:{label:string;onClick:()=>void}}){const ring=tone==="success"?"bg-success/15 text-success":tone==="danger"?"bg-danger/15 text-danger":"bg-warning/15 text-warning";return <div className="fo-screen absolute inset-0 flex flex-col items-center justify-center gap-4 p-7 text-center"><span className={`grid h-16 w-16 place-items-center rounded-2xl ${ring}`}><Icon name={icon} className="h-8 w-8" /></span><div><p className="text-[17px] font-bold">{title}</p><p className="mx-auto mt-1 max-w-[18rem] text-[13px] text-white/65">{body}</p></div><div className="mt-1 w-full max-w-[16rem] space-y-2"><Button onClick={primary.onClick}>{primary.label}</Button>{secondary&&<button onClick={secondary.onClick} className="h-11 w-full rounded-2xl text-[14px] font-semibold text-white/70">{secondary.label}</button>}</div></div>}
