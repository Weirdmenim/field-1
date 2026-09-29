import { useCallback, useMemo, useState } from "react"
import PhoneFrame from "./components/PhoneFrame"
import BottomNav, { type Tab } from "./components/inventory/BottomNav"
import InventoryHome from "./components/inventory/InventoryHome"
import Work from "./components/inventory/Work"
import Scan from "./components/inventory/Scan"
import ReceiveTransfer from "./components/inventory/ReceiveTransfer"
import Dispatch from "./components/inventory/Dispatch"
import CycleCount from "./components/inventory/CycleCount"
import InventorySearch from "./components/inventory/InventorySearch"
import ItemDetail from "./components/inventory/ItemDetail"
import SyncCenter from "./components/inventory/SyncCenter"
import TransactionHistory from "./components/inventory/TransactionHistory"
import type { Task } from "./components/inventory/models"
import { useSyncEngine } from "./lib/useSyncEngine"
import { useOperationalContext, type InventoryPermission } from "./lib/auth"
import { useWarehouseWork, type WarehouseWorkItem } from "./lib/documents"
import type { Nav, Screen, ScanContext } from "./components/inventory/types"

const tabToScreen: Record<Exclude<Tab, "scan">, Screen> = {
  home: "home",
  work: "work",
  inventory: "search",
  sync: "sync",
}

const tabScreens: Screen[] = ["home", "work", "search", "sync"]

function screenToTab(s: Screen): Tab {
  if (s === "search" || s === "item") return "inventory"
  if (s === "work") return "work"
  if (s === "sync") return "sync"
  return "home"
}

const kindToScreen: Record<Task["kind"], Screen> = { receive: "receive", dispatch: "dispatch", count: "cycle" }

function dueLabel(dueAt: string | null) {
  if (!dueAt) return "No due time"
  const due = new Date(dueAt)
  if (Number.isNaN(due.getTime())) return "Due date unavailable"
  return `Due ${due.toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}`
}

function authoritativeTask(item: WarehouseWorkItem): Task {
  const now = Date.now()
  const dueTime = item.dueAt ? new Date(item.dueAt).getTime() : null
  const completed = item.status === "COMPLETED"
  const attention = !completed && (item.status === "PARTIAL" || item.status === "EXCEPTION" || item.status === "PENDING_APPROVAL" || (dueTime != null && dueTime < now))
  const group: Task["group"] = attention ? "attention" : dueTime != null && dueTime > now + 24 * 60 * 60 * 1000 ? "upcoming" : "today"
  const status: Task["status"] = completed ? "completed" : attention ? "overdue" : item.done > 0 ? "in-progress" : "assigned"
  return {
    id: item.id,
    kind: item.kind,
    ref: item.ref,
    title: item.title,
    where: item.where,
    due: dueLabel(item.dueAt),
    priority: item.priority,
    done: item.done,
    total: item.total,
    status,
    group,
  }
}

export default function App() {
  const [screen, setScreen] = useState<Screen>("home")
  const [itemId, setItemId] = useState<string>("")
  const [scanContext, setScanContext] = useState<ScanContext>("browse")
  const [scanLineId, setScanLineId] = useState<string | null>(null)
  const [postScan, setPostScan] = useState<Exclude<ScanContext, "browse"> | null>(null)
  const [activeTaskId, setActiveTaskId] = useState<string | null>(null)

  const { user, profile, activeCompany, activeWarehouse, can } = useOperationalContext()
  const { data: warehouseWork = [] } = useWarehouseWork()
  const workItems = useMemo(() => warehouseWork.map(authoritativeTask), [warehouseWork])

  const queueOwner = useMemo(() => ({
    authUserId: user!.id,
    companyId: activeCompany!.id,
    locationId: activeWarehouse!.id,
  }), [activeCompany, activeWarehouse, user])

  const {
    isOnline: online,
    isSyncing: syncing,
    queue: syncOps,
    lastConfirmedAt,
    storageAvailable,
    storageError,
    runSync,
    refreshQueue,
    retryOperation,
    acceptServerVersion,
    rebaseConflictOperation,
  } = useSyncEngine(queueOwner)

  const activeSync = syncOps.filter((operation) => !["confirmed", "cancelled"].includes(operation.state))
  const synced = online && activeSync.length === 0 && !syncing

  const progressFor = useCallback((task: Task) => ({ done: task.done, total: task.total }), [])

  const taskPermission = (kind: Task["kind"]): InventoryPermission =>
    kind === "receive" ? "inventory.receive" : kind === "dispatch" ? "inventory.dispatch" : "inventory.count"

  const nav: Nav = {
    go: (s) => {
      setPostScan(null)
      setScanLineId(null)
      setScreen(s)
    },
    openItem: (id) => {
      setPostScan(null)
      setItemId(id)
      setScreen("item")
    },
    openTask: (taskId) => {
      const task = workItems.find((entry) => entry.id === taskId)
      if (!task || !can(taskPermission(task.kind))) return
      setActiveTaskId(taskId)
      setPostScan(null)
      setScanLineId(null)
      setScreen(kindToScreen[task.kind])
    },
    activeTaskId,
    workItems,
    openScan: (ctx) => {
      if (ctx === "receive" && !can("inventory.receive")) return
      if (ctx === "dispatch" && !can("inventory.dispatch")) return
      setScanContext(ctx)
      setScreen("scan")
    },
    enterFlowExecuting: (ctx, lineId) => {
      if (ctx === "receive" && !can("inventory.receive")) return
      if (ctx === "dispatch" && !can("inventory.dispatch")) return
      setScanLineId(lineId)
      setPostScan(ctx)
      setScreen(ctx)
    },
    scanContext,
    scanLineId,
    authUserId: user!.id,
    profileId: profile!.id,
    companyId: activeCompany!.id,
    locationId: activeWarehouse!.id,
    actorName: profile!.fullName,
    role: activeCompany!.role,
    locationName: activeWarehouse!.name,
    locationCode: activeWarehouse!.code,
    can,
    online,
    syncing,
    synced,
    lastConfirmedAt,
    storageAvailable,
    storageError,
    runSync,
    refreshQueue,
    retryOperation,
    acceptServerVersion,
    rebaseConflictOperation,
    syncOps,
    progressFor,
  }

  const onTab = (t: Tab) => {
    if (t === "scan") {
      setScanContext("browse")
      setScreen("scan")
      return
    }
    setScreen(tabToScreen[t])
  }

  const showNav = tabScreens.includes(screen)
  const pending = activeSync.length

  return (
    <div className="min-h-screen w-full bg-canvas text-ink">
      {!storageAvailable && <div className="fixed inset-x-3 top-3 z-50 mx-auto max-w-[430px] rounded-2xl border border-danger/25 bg-danger-soft px-4 py-3 shadow-lg"><p className="text-[13px] font-extrabold text-danger">Durable storage unavailable</p><p className="mt-1 text-[12px] text-ink-soft">{storageError ?? "FieldOne cannot prove that new offline work is durable. Sync and new durable writes remain fail-closed until browser storage recovers."}</p></div>}
      <main className="flex min-h-screen items-center justify-center p-3 sm:p-6">
        <PhoneFrame bottomBar={showNav ? <BottomNav active={screenToTab(screen)} onSelect={onTab} pending={pending} /> : undefined}>
          {screen === "home" && <InventoryHome nav={nav} />}
          {screen === "work" && <Work nav={nav} />}
          {screen === "scan" && <Scan nav={nav} />}
          {screen === "receive" && <ReceiveTransfer nav={nav} startExecuting={postScan === "receive"} />}
          {screen === "dispatch" && <Dispatch nav={nav} startExecuting={postScan === "dispatch"} />}
          {screen === "cycle" && <CycleCount nav={nav} />}
          {screen === "search" && <InventorySearch nav={nav} />}
          {screen === "item" && <ItemDetail nav={nav} itemId={itemId} />}
          {screen === "sync" && <SyncCenter nav={nav} />}
          {screen === "history" && <TransactionHistory nav={nav} />}
        </PhoneFrame>
      </main>
    </div>
  )
}
