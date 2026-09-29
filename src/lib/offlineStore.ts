import localforage from "localforage"
import { probeDurableStorage, storageGet, storageIterate, storageRemove, storageSet } from "./durableStorage"

export type OfflineOwner = {
  authUserId: string
  companyId: string
  locationId: string
}

export type WorkflowKind = "receive" | "dispatch" | "count"

export type WorkflowDraft = {
  schemaVersion: 1
  owner: OfflineOwner
  kind: WorkflowKind
  documentId: string
  documentRef: string
  documentRevision: number
  updatedAt: string
  state: Record<string, unknown>
  finalCommandId?: string | null
}

export type PersistedSnapshot<T = unknown> = {
  schemaVersion: 1
  owner: OfflineOwner
  kind: "warehouse-work" | "transfer-document" | "sales-order-document" | "count-session-document" | "inventory-items" | "inventory-item" | "item-bins" | "item-movements"
  key: string
  capturedAt: string
  value: T
}

export type SyncFreshness = {
  schemaVersion: 1
  owner: OfflineOwner
  lastConfirmedAt: string | null
}

const drafts = localforage.createInstance({ name: "FieldOneOffline", storeName: "WorkflowDraftsV1" })
const snapshots = localforage.createInstance({ name: "FieldOneOffline", storeName: "ServerSnapshotsV1" })
const freshness = localforage.createInstance({ name: "FieldOneOffline", storeName: "SyncFreshnessV1" })
const operationalContext = localforage.createInstance({ name: "FieldOneOffline", storeName: "OperationalContextV1" })

export function ownerKey(owner: OfflineOwner) {
  return `${owner.authUserId}:${owner.companyId}:${owner.locationId}`
}

function draftKey(owner: OfflineOwner, kind: WorkflowKind, documentId: string) {
  return `${ownerKey(owner)}:${kind}:${documentId}`
}

function snapshotKey(owner: OfflineOwner, kind: PersistedSnapshot["kind"], key: string) {
  return `${ownerKey(owner)}:${kind}:${key}`
}

export async function saveWorkflowDraft(draft: WorkflowDraft) {
  await storageSet(drafts, draftKey(draft.owner, draft.kind, draft.documentId), draft)
  return draft
}

export async function loadWorkflowDraft(owner: OfflineOwner, kind: WorkflowKind, documentId: string) {
  return storageGet<WorkflowDraft>(drafts, draftKey(owner, kind, documentId))
}

export async function deleteWorkflowDraft(owner: OfflineOwner, kind: WorkflowKind, documentId: string) {
  await storageRemove(drafts, draftKey(owner, kind, documentId))
}

export async function listWorkflowDrafts(owner: OfflineOwner) {
  const prefix = `${ownerKey(owner)}:`
  const result: WorkflowDraft[] = []
  await storageIterate<WorkflowDraft>(drafts, (value, key) => {
    if (key.startsWith(prefix) && value?.schemaVersion === 1) result.push(value)
  })
  return result.sort((a, b) => a.updatedAt.localeCompare(b.updatedAt))
}

export async function saveSnapshot<T>(snapshot: PersistedSnapshot<T>) {
  await storageSet(snapshots, snapshotKey(snapshot.owner, snapshot.kind, snapshot.key), snapshot)
  return snapshot
}

export async function loadSnapshot<T>(owner: OfflineOwner, kind: PersistedSnapshot["kind"], key: string) {
  return storageGet<PersistedSnapshot<T>>(snapshots, snapshotKey(owner, kind, key))
}

export async function setLastConfirmedAt(owner: OfflineOwner, timestamp: string) {
  const value: SyncFreshness = { schemaVersion: 1, owner, lastConfirmedAt: timestamp }
  await storageSet(freshness, ownerKey(owner), value)
  return value
}

export async function getSyncFreshness(owner: OfflineOwner): Promise<SyncFreshness> {
  return (await storageGet<SyncFreshness>(freshness, ownerKey(owner))) ?? {
    schemaVersion: 1,
    owner,
    lastConfirmedAt: null,
  }
}

export async function checkOfflineStorageHealth() {
  return probeDurableStorage(drafts)
}

export type CachedOperationalContext<T = unknown> = {
  schemaVersion: 1
  authUserId: string
  capturedAt: string
  value: T
}

export async function saveOperationalContextSnapshot<T>(authUserId: string, value: T) {
  const snapshot: CachedOperationalContext<T> = { schemaVersion: 1, authUserId, capturedAt: new Date().toISOString(), value }
  await storageSet(operationalContext, authUserId, snapshot)
  return snapshot
}

export async function loadOperationalContextSnapshot<T>(authUserId: string) {
  const snapshot = await storageGet<CachedOperationalContext<T>>(operationalContext, authUserId)
  if (!snapshot || snapshot.schemaVersion !== 1 || snapshot.authUserId !== authUserId) return null
  return snapshot
}

export async function clearOperationalContextSnapshot(authUserId: string) {
  await storageRemove(operationalContext, authUserId)
}

function replaceCommandIdDeep(value: unknown, oldId: string, newId: string): unknown {
  if (value === oldId) return newId
  if (Array.isArray(value)) return value.map((entry) => replaceCommandIdDeep(entry, oldId, newId))
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([key, entry]) => [key, replaceCommandIdDeep(entry, oldId, newId)]))
  }
  return value
}

export async function replaceWorkflowCommandReference(owner: OfflineOwner, documentId: string, oldId: string, newId: string) {
  const matches = (await listWorkflowDrafts(owner)).filter((draft) => draft.documentId === documentId)
  for (const draft of matches) {
    const next: WorkflowDraft = {
      ...draft,
      state: replaceCommandIdDeep(draft.state, oldId, newId) as Record<string, unknown>,
      finalCommandId: draft.finalCommandId === oldId ? newId : draft.finalCommandId,
      updatedAt: new Date().toISOString(),
    }
    await saveWorkflowDraft(next)
  }
}
