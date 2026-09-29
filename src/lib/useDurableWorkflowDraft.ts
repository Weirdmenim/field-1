import { useCallback, useEffect, useRef, useState } from "react"
import {
  deleteWorkflowDraft,
  loadWorkflowDraft,
  saveWorkflowDraft,
  type OfflineOwner,
  type WorkflowKind,
  type WorkflowDraft,
} from "./offlineStore"

export function useDurableWorkflowDraft<T extends Record<string, unknown>>(input: {
  owner: OfflineOwner
  kind: WorkflowKind
  documentId: string | null
  documentRef: string
  serverRevision: number
  initialState: T
}) {
  const [state, setState] = useState<T>(input.initialState)
  const [localRevision, setLocalRevision] = useState(input.serverRevision)
  const [finalCommandId, setFinalCommandIdState] = useState<string | null>(null)
  const [hydrated, setHydrated] = useState(false)
  const currentRef = useRef({ state: input.initialState, revision: input.serverRevision, finalCommandId: null as string | null })

  const persist = useCallback(async (next?: Partial<{ state: T; revision: number; finalCommandId: string | null }>) => {
    if (!input.documentId) return
    const merged = {
      state: next?.state ?? currentRef.current.state,
      revision: next?.revision ?? currentRef.current.revision,
      finalCommandId: next?.finalCommandId === undefined ? currentRef.current.finalCommandId : next.finalCommandId,
    }
    currentRef.current = merged
    const draft: WorkflowDraft = {
      schemaVersion: 1,
      owner: input.owner,
      kind: input.kind,
      documentId: input.documentId,
      documentRef: input.documentRef,
      documentRevision: merged.revision,
      updatedAt: new Date().toISOString(),
      state: merged.state,
      finalCommandId: merged.finalCommandId,
    }
    await saveWorkflowDraft(draft)
  }, [input.documentId, input.documentRef, input.kind, input.owner])

  useEffect(() => {
    let cancelled = false
    setHydrated(false)
    if (!input.documentId) {
      setHydrated(true)
      return
    }
    void loadWorkflowDraft(input.owner, input.kind, input.documentId).then((draft) => {
      if (cancelled) return
      if (draft) {
        const nextState = draft.state as T
        setState(nextState)
        setLocalRevision(Math.max(input.serverRevision, draft.documentRevision))
        setFinalCommandIdState(draft.finalCommandId ?? null)
        currentRef.current = { state: nextState, revision: Math.max(input.serverRevision, draft.documentRevision), finalCommandId: draft.finalCommandId ?? null }
      } else {
        setState(input.initialState)
        setLocalRevision(input.serverRevision)
        setFinalCommandIdState(null)
        currentRef.current = { state: input.initialState, revision: input.serverRevision, finalCommandId: null }
      }
      setHydrated(true)
    })
    return () => { cancelled = true }
  }, [input.documentId, input.kind, input.owner.authUserId, input.owner.companyId, input.owner.locationId])


  useEffect(() => {
    if (!hydrated || input.serverRevision <= currentRef.current.revision) return
    currentRef.current.revision = input.serverRevision
    setLocalRevision(input.serverRevision)
    void persist({ revision: input.serverRevision })
  }, [hydrated, input.serverRevision, persist])

  const updateState = useCallback((update: T | ((current: T) => T)) => {
    setState((current) => {
      const next = typeof update === "function" ? (update as (current: T) => T)(current) : update
      currentRef.current.state = next
      void persist({ state: next })
      return next
    })
  }, [persist])

  const advanceRevision = useCallback((by = 1) => {
    const next = currentRef.current.revision + by
    currentRef.current.revision = next
    setLocalRevision(next)
    void persist({ revision: next })
    return next
  }, [persist])

  const ensureFinalCommandId = useCallback(async () => {
    if (currentRef.current.finalCommandId) return currentRef.current.finalCommandId
    const id = crypto.randomUUID()
    currentRef.current.finalCommandId = id
    setFinalCommandIdState(id)
    await persist({ finalCommandId: id })
    return id
  }, [persist])

  const clear = useCallback(async () => {
    if (!input.documentId) return
    await deleteWorkflowDraft(input.owner, input.kind, input.documentId)
  }, [input.documentId, input.kind, input.owner])

  return { state, updateState, localRevision, advanceRevision, finalCommandId, ensureFinalCommandId, hydrated, clearDraft: clear, persistDraft: persist }
}
