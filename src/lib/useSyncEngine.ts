import { useState, useEffect, useCallback, useRef, useMemo } from "react"
import {
  acceptServerVersion,
  getQueueForOwner,
  processQueue,
  rebaseConflictOperation,
  retryOperation,
  subscribeOutbox,
  type QueueOwner,
  type QueuedOperation,
} from "./syncEngine"
import { checkOfflineStorageHealth, getSyncFreshness } from "./offlineStore"
import { getStorageHealth, subscribeStorageHealth, type StorageHealth } from "./durableStorage"
import { probeBackendReachability } from "./reachability"
import { useQueryClient } from "@tanstack/react-query"

export function useSyncEngine(owner: QueueOwner) {
  const stableOwner = useMemo(() => owner, [owner.authUserId, owner.companyId, owner.locationId])
  const [isOnline, setIsOnline] = useState(false)
  const [isSyncing, setIsSyncing] = useState(false)
  const [queue, setQueue] = useState<QueuedOperation[]>([])
  const [lastConfirmedAt, setLastConfirmedAt] = useState<string | null>(null)
  const [storageHealth, setStorageHealth] = useState<StorageHealth>(() => getStorageHealth())
  const queryClient = useQueryClient()
  const runningRef = useRef(false)
  const mountedRef = useRef(true)

  const loadQueue = useCallback(async () => {
    try {
      const [nextQueue, freshness] = await Promise.all([getQueueForOwner(stableOwner), getSyncFreshness(stableOwner)])
      if (!mountedRef.current) return
      setQueue(nextQueue)
      setLastConfirmedAt(freshness.lastConfirmedAt)
    } catch {
      // Durable-storage wrapper publishes the structured health failure. We fail
      // closed here rather than replacing durable state with an in-memory queue.
      if (mountedRef.current) setStorageHealth(getStorageHealth())
    }
  }, [stableOwner])

  const invalidateAuthoritativeData = useCallback(async () => {
    await queryClient.invalidateQueries({
      predicate: (query) => ["items", "item", "item-bins", "item-movements", "warehouse-work", "transfer-document", "sales-order-document", "count-session-document"].includes(String(query.queryKey[0])),
    })
  }, [queryClient])

  const refreshReachability = useCallback(async () => {
    const reachable = await probeBackendReachability()
    if (mountedRef.current) setIsOnline(reachable)
    return reachable
  }, [])

  const runSync = useCallback(async () => {
    if (runningRef.current || !storageHealth.available) return
    const reachable = await refreshReachability()
    if (!reachable) return
    runningRef.current = true
    setIsSyncing(true)
    try {
      const remaining = await processQueue(stableOwner)
      if (mountedRef.current) setQueue(remaining)
      await invalidateAuthoritativeData()
      const freshness = await getSyncFreshness(stableOwner)
      if (mountedRef.current) setLastConfirmedAt(freshness.lastConfirmedAt)
    } finally {
      runningRef.current = false
      if (mountedRef.current) setIsSyncing(false)
    }
  }, [invalidateAuthoritativeData, stableOwner, refreshReachability, storageHealth.available])

  useEffect(() => {
    mountedRef.current = true
    setQueue([])
    void checkOfflineStorageHealth().then((health) => {
      if (!mountedRef.current) return
      setStorageHealth(health)
      return loadQueue().then(() => void runSync())
    })
    const unsubscribeOutbox = subscribeOutbox(stableOwner, () => void loadQueue())
    const unsubscribeStorage = subscribeStorageHealth((health) => {
      if (mountedRef.current) setStorageHealth(health)
    })
    return () => {
      mountedRef.current = false
      unsubscribeOutbox()
      unsubscribeStorage()
    }
  }, [loadQueue, stableOwner, runSync])

  useEffect(() => {
    if (storageHealth.available) return
    const interval = window.setInterval(() => {
      void checkOfflineStorageHealth().then((health) => {
        if (!mountedRef.current) return
        setStorageHealth(health)
        if (health.available) void loadQueue().then(() => void runSync())
      })
    }, 5_000)
    return () => window.clearInterval(interval)
  }, [loadQueue, runSync, storageHealth.available])

  useEffect(() => {
    const handleNetworkHint = () => { void refreshReachability().then((reachable) => { if (reachable) void runSync() }) }
    window.addEventListener("online", handleNetworkHint)
    window.addEventListener("offline", handleNetworkHint)
    const interval = window.setInterval(() => { void refreshReachability() }, 30_000)
    return () => {
      window.removeEventListener("online", handleNetworkHint)
      window.removeEventListener("offline", handleNetworkHint)
      window.clearInterval(interval)
    }
  }, [refreshReachability, runSync])

  const refreshQueue = useCallback(async () => {
    await loadQueue()
    await runSync()
  }, [loadQueue, runSync])

  const retry = useCallback(async (id: string) => {
    await retryOperation(id, owner)
    await loadQueue()
    await runSync()
  }, [loadQueue, owner, runSync])

  const keepServer = useCallback(async (id: string) => {
    await acceptServerVersion(id, owner)
    await loadQueue()
    await invalidateAuthoritativeData()
  }, [invalidateAuthoritativeData, loadQueue, owner])

  const keepLocal = useCallback(async (id: string) => {
    const successor = await rebaseConflictOperation(id, owner)
    await loadQueue()
    if (successor) await runSync()
    return successor
  }, [loadQueue, owner, runSync])

  return {
    isOnline,
    isSyncing,
    queue,
    lastConfirmedAt,
    storageAvailable: storageHealth.available,
    storageError: storageHealth.message,
    runSync,
    refreshQueue,
    retryOperation: retry,
    acceptServerVersion: keepServer,
    rebaseConflictOperation: keepLocal,
  }
}
