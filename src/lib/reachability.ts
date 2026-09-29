import { supabaseAnonKey, supabaseUrl } from "./supabase"

export type BackendReachability = "unknown" | "reachable" | "unreachable"
const PROBE_TIMEOUT_MS = 4_000
const PROBE_CACHE_MS = 2_000
let lastProbeAt = 0
let lastProbeResult = false
let inFlight: Promise<boolean> | null = null

async function performProbe(): Promise<boolean> {
  if (typeof fetch === "undefined") return false
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS)
  try {
    // Any HTTP response from the configured Supabase auth service proves route reachability.
    // Authorization/business failures are intentionally not interpreted as offline state.
    await fetch(`${supabaseUrl.replace(/\/$/, "")}/auth/v1/health`, {
      method: "GET",
      cache: "no-store",
      headers: { apikey: supabaseAnonKey },
      signal: controller.signal,
    })
    return true
  } catch {
    return false
  } finally {
    clearTimeout(timeout)
  }
}

export async function probeBackendReachability(force = false): Promise<boolean> {
  const now = Date.now()
  if (!force && lastProbeAt > 0 && now - lastProbeAt < PROBE_CACHE_MS) return lastProbeResult
  if (inFlight) return inFlight
  inFlight = performProbe().then((result) => {
    lastProbeResult = result
    lastProbeAt = Date.now()
    return result
  }).finally(() => { inFlight = null })
  return inFlight
}
