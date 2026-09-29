import type { InventoryPermission } from "../../lib/auth"
import type { QueuedOperation } from "../../lib/syncEngine"
import type { Task } from "./models"

export type Screen =
  | "home"
  | "work"
  | "scan"
  | "receive"
  | "dispatch"
  | "cycle"
  | "search"
  | "item"
  | "sync"
  | "history"

export type ScanContext = "browse" | "receive" | "dispatch"

export type Nav = {
  go: (screen: Screen) => void
  openItem: (id: string) => void
  openTask: (taskId: string) => void
  activeTaskId: string | null
  workItems: Task[]
  openScan: (context: ScanContext) => void
  enterFlowExecuting: (context: Exclude<ScanContext, "browse">, lineId: string) => void
  scanContext: ScanContext
  scanLineId: string | null
  authUserId: string
  profileId: string
  companyId: string
  locationId: string
  actorName: string
  role: string
  locationName: string
  locationCode: string
  can: (permission: InventoryPermission) => boolean
  online: boolean
  syncing: boolean
  synced: boolean
  lastConfirmedAt: string | null
  storageAvailable: boolean
  storageError: string | null
  runSync: () => void
  refreshQueue: () => Promise<void>
  retryOperation: (id: string) => Promise<void>
  acceptServerVersion: (id: string) => Promise<void>
  rebaseConflictOperation: (id: string) => Promise<QueuedOperation | null>
  syncOps: QueuedOperation[]
  progressFor: (task: Task) => { done: number; total: number }
}
