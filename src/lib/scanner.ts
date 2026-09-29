export type ScannerLifecycle = "idle" | "starting" | "active" | "denied" | "unsupported" | "error" | "stopped"
export type ScannerDecode = { code: string; source: "camera" | "hardware"; at: number }

type BarcodeDetectorLike = {
  detect(source: CanvasImageSource): Promise<Array<{ rawValue?: string }>>
}
type BarcodeDetectorCtor = new (options?: { formats?: string[] }) => BarcodeDetectorLike

const normalize = (value: string) => value.trim().replace(/\s+/g, "").toLowerCase()
export const normalizeScannedCode = normalize

export class DuplicateDecodeGuard {
  private seen = new Map<string, number>()
  constructor(private readonly windowMs = 1500) {}
  accept(code: string, now = Date.now()) {
    const key = normalize(code)
    if (!key) return false
    const previous = this.seen.get(key)
    this.seen.set(key, now)
    for (const [candidate, at] of this.seen) if (now - at > this.windowMs * 4) this.seen.delete(candidate)
    return previous == null || now - previous > this.windowMs
  }
}

export class ProductionScanner {
  private stream: MediaStream | null = null
  private video: HTMLVideoElement | null = null
  private detector: BarcodeDetectorLike | null = null
  private frame = 0
  private stopped = true
  private guard = new DuplicateDecodeGuard()
  private keyboard = ""
  private keyboardAt = 0
  private keyHandler: ((event: KeyboardEvent) => void) | null = null
  private visibilityHandler: (() => void) | null = null

  constructor(private readonly onDecode: (decode: ScannerDecode) => void, private readonly onLifecycle?: (state: ScannerLifecycle, message?: string) => void, private readonly onDuplicate?: (decode: ScannerDecode) => void) {}

  attachHardwareScanner(target: Window = window) {
    if (this.keyHandler) return
    this.keyHandler = (event) => {
      if (event.ctrlKey || event.altKey || event.metaKey) return
      const now = performance.now()
      if (now - this.keyboardAt > 80) this.keyboard = ""
      this.keyboardAt = now
      if (event.key === "Enter") {
        const code = this.keyboard.trim()
        this.keyboard = ""
        if (code.length >= 3) this.emit(code, "hardware")
        return
      }
      if (event.key.length === 1) this.keyboard += event.key
    }
    target.addEventListener("keydown", this.keyHandler, true)
  }

  detachHardwareScanner(target: Window = window) {
    if (this.keyHandler) target.removeEventListener("keydown", this.keyHandler, true)
    this.keyHandler = null
  }

  async startCamera(video: HTMLVideoElement) {
    this.onLifecycle?.("starting")
    if (!navigator.mediaDevices?.getUserMedia) { this.onLifecycle?.("unsupported", "Camera capture is not supported by this browser."); return }
    const Detector = (globalThis as typeof globalThis & { BarcodeDetector?: BarcodeDetectorCtor }).BarcodeDetector
    if (!Detector) { this.onLifecycle?.("unsupported", "BarcodeDetector is not supported by this browser; use a hardware scanner or exact manual entry."); return }
    try {
      this.stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: "environment" } }, audio: false })
      this.video = video
      video.srcObject = this.stream
      video.setAttribute("playsinline", "true")
      await video.play()
      this.detector = new Detector({ formats: ["code_128", "code_39", "ean_13", "ean_8", "upc_a", "upc_e", "qr_code", "data_matrix"] })
      this.stopped = false
      this.onLifecycle?.("active")
      this.visibilityHandler = () => { if (document.hidden) this.stopCamera(); }
      document.addEventListener("visibilitychange", this.visibilityHandler)
      this.scanFrame()
    } catch (error) {
      const name = error instanceof DOMException ? error.name : ""
      this.onLifecycle?.(name === "NotAllowedError" || name === "SecurityError" ? "denied" : "error", error instanceof Error ? error.message : String(error))
      this.stopCamera()
    }
  }

  async setTorch(enabled: boolean) {
    const track = this.stream?.getVideoTracks()[0]
    if (!track) return false
    try {
      await track.applyConstraints({ advanced: [{ torch: enabled } as MediaTrackConstraintSet] })
      return true
    } catch { return false }
  }

  stopCamera() {
    this.stopped = true
    cancelAnimationFrame(this.frame)
    this.stream?.getTracks().forEach((track) => track.stop())
    if (this.video) this.video.srcObject = null
    this.stream = null; this.video = null; this.detector = null
    if (this.visibilityHandler) document.removeEventListener("visibilitychange", this.visibilityHandler)
    this.visibilityHandler = null
    this.onLifecycle?.("stopped")
  }

  destroy() { this.stopCamera(); this.detachHardwareScanner() }

  private emit(raw: string, source: ScannerDecode["source"]) {
    const code = raw.trim()
    if (!code) return
    const decode = { code, source, at: Date.now() } as ScannerDecode
    if (this.guard.accept(code)) this.onDecode(decode)
    else this.onDuplicate?.(decode)
  }

  private scanFrame = async () => {
    if (this.stopped || !this.detector || !this.video) return
    try {
      if (this.video.readyState >= 2) {
        const results = await this.detector.detect(this.video)
        for (const result of results) if (result.rawValue) this.emit(result.rawValue, "camera")
      }
    } catch { /* transient decode errors do not terminate acquisition */ }
    if (!this.stopped) this.frame = requestAnimationFrame(this.scanFrame)
  }
}
