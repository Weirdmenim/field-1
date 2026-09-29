export async function registerOfflineShell() {
  if (!("serviceWorker" in navigator) || import.meta.env.DEV) return
  try {
    const registration = await navigator.serviceWorker.register("/sw.js", { scope: "/" })
    await navigator.serviceWorker.ready
    const resources = performance
      .getEntriesByType("resource")
      .map((entry) => entry.name)
      .filter((url) => {
        try { return new URL(url).origin === window.location.origin } catch { return false }
      })
    registration.active?.postMessage({ type: "CACHE_URLS", urls: [window.location.href, ...resources] })
  } catch (error) {
    console.warn("FieldOne offline shell registration failed", error)
  }
}
