const CACHE_VERSION = "fieldone-shell-v1"
const CORE = ["/", "/index.html", "/manifest.webmanifest", "/fieldone-icon.svg", "/product-placeholder.svg", "/avatar-placeholder.svg"]

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_VERSION).then((cache) => cache.addAll(CORE)).then(() => self.skipWaiting()))
})

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys()
    await Promise.all(keys.filter((key) => key.startsWith("fieldone-shell-") && key !== CACHE_VERSION).map((key) => caches.delete(key)))
    await self.clients.claim()
  })())
})

self.addEventListener("message", (event) => {
  const data = event.data
  if (!data || data.type !== "CACHE_URLS" || !Array.isArray(data.urls)) return
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_VERSION)
    const urls = [...new Set(data.urls)].filter((value) => {
      try { return new URL(value, self.location.origin).origin === self.location.origin } catch { return false }
    })
    await Promise.all(urls.map(async (value) => {
      try {
        const url = new URL(value, self.location.origin)
        const response = await fetch(url.toString(), { cache: "reload" })
        if (response.ok) await cache.put(url.pathname + url.search, response.clone())
      } catch { /* shell warming is best effort; runtime fetch fallback still applies */ }
    }))
  })())
})

self.addEventListener("fetch", (event) => {
  const request = event.request
  if (request.method !== "GET") return
  const url = new URL(request.url)
  if (url.origin !== self.location.origin) return

  if (request.mode === "navigate") {
    event.respondWith((async () => {
      try {
        const response = await fetch(request)
        if (response.ok) {
          const cache = await caches.open(CACHE_VERSION)
          await cache.put("/index.html", response.clone())
        }
        return response
      } catch {
        return (await caches.match("/index.html")) || (await caches.match("/")) || Response.error()
      }
    })())
    return
  }

  event.respondWith((async () => {
    const cached = await caches.match(request)
    if (cached) return cached
    try {
      const response = await fetch(request)
      if (response.ok && ["script", "style", "image", "font", "worker"].includes(request.destination)) {
        const cache = await caches.open(CACHE_VERSION)
        await cache.put(request, response.clone())
      }
      return response
    } catch {
      return cached || Response.error()
    }
  })())
})
