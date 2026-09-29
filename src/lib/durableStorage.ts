// import type { LocalForage } from "localforage"

export type StorageFailureCode = "QUOTA" | "UNAVAILABLE" | "CORRUPT" | "UNKNOWN"
export type StorageHealth = {
  available: boolean
  code: StorageFailureCode | null
  message: string | null
  checkedAt: string
}

export class DurableStorageError extends Error {
  readonly code: StorageFailureCode
  readonly operation: string
  constructor(operation: string, cause: unknown) {
    const source = cause instanceof Error ? cause.message : String(cause)
    const lower = source.toLowerCase()
    const code: StorageFailureCode = lower.includes("quota") || lower.includes("full")
      ? "QUOTA"
      : lower.includes("indexeddb") || lower.includes("storage") || lower.includes("unavailable") || lower.includes("denied")
        ? "UNAVAILABLE"
        : lower.includes("corrupt") || lower.includes("parse")
          ? "CORRUPT"
          : "UNKNOWN"
    super(`Durable storage ${operation} failed: ${source}`)
    this.name = "DurableStorageError"
    this.code = code
    this.operation = operation
  }
}

let lastHealth: StorageHealth = { available: true, code: null, message: null, checkedAt: new Date(0).toISOString() }
const listeners = new Set<(health: StorageHealth) => void>()

function publish(health: StorageHealth) {
  lastHealth = health
  for (const listener of listeners) listener(health)
}

export function getStorageHealth() {
  return lastHealth
}

export function subscribeStorageHealth(listener: (health: StorageHealth) => void) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

function storeLabel(store: any) {
  return (store as any)._config?.storeName ?? "store"
}

async function retryOnce<T>(operation: string, fn: () => Promise<T>): Promise<T> {
  try {
    const value = await fn()
    publish({ available: true, code: null, message: null, checkedAt: new Date().toISOString() })
    return value
  } catch (first) {
    await new Promise((resolve) => setTimeout(resolve, 40))
    try {
      const value = await fn()
      publish({ available: true, code: null, message: null, checkedAt: new Date().toISOString() })
      return value
    } catch (second) {
      const error = new DurableStorageError(operation, second ?? first)
      publish({ available: false, code: error.code, message: error.message, checkedAt: new Date().toISOString() })
      throw error
    }
  }
}

export function storageGet<T>(store: any, key: string) {
  return retryOnce(`read:${storeLabel(store)}`, () => store.getItem(key) as Promise<T | null>)
}

export function storageSet<T>(store: any, key: string, value: T) {
  return retryOnce(`write:${storeLabel(store)}`, () => store.setItem(key, value))
}

export function storageRemove(store: any, key: string) {
  return retryOnce(`remove:${storeLabel(store)}`, () => store.removeItem(key))
}

export function storageIterate<T>(store: any, iterator: (value: T, key: string, iterationNumber: number) => void) {
  return retryOnce(`iterate:${storeLabel(store)}`, () => store.iterate((value: T, key: string, iterationNumber: number) => iterator(value, key, iterationNumber)))
}

export async function probeDurableStorage(store: any): Promise<StorageHealth> {
  const key = `__fieldone_probe__:${crypto.randomUUID()}`
  try {
    await storageSet(store, key, { at: new Date().toISOString() })
    const roundTrip = await storageGet<{ at?: string }>(store, key)
    await storageRemove(store, key)
    if (!roundTrip?.at) throw new DurableStorageError("probe", new Error("Durable storage probe did not round-trip"))
    return getStorageHealth()
  } catch (error) {
    if (error instanceof DurableStorageError) return getStorageHealth()
    const wrapped = new DurableStorageError("probe", error)
    const health = { available: false, code: wrapped.code, message: wrapped.message, checkedAt: new Date().toISOString() } satisfies StorageHealth
    publish(health)
    return health
  }
}
