import { supabase } from "./supabase"

type JsonRecord = Record<string, unknown>
const record = (value: unknown): JsonRecord => {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid ledger response")
  return value as JsonRecord
}
const text = (r: JsonRecord, key: string, nullable = false): string | null => {
  const value = r[key]
  if (value == null && nullable) return null
  if (typeof value !== "string") throw new Error(`Invalid ledger field: ${key}`)
  return value
}
const number = (r: JsonRecord, key: string): number => {
  const value = r[key]
  const parsed = typeof value === "number" ? value : Number(value)
  if (!Number.isFinite(parsed)) throw new Error(`Invalid ledger numeric field: ${key}`)
  return parsed
}

export type MovementReversalState = {
  movementId: string
  movementType: string
  originalBaseQuantity: number
  reversedBaseQuantity: number
  remainingReversibleBaseQuantity: number
  eligible: boolean
  reason: string | null
}

export type LedgerCommandResult = {
  success: boolean
  outcome: string
  clientCommandId: string
  serverCommandId: string
  code: string | null
  message: string | null
  reversalMovementId: string | null
  remainingReversibleBaseQuantity: number | null
}

const parseReversalState = (value: unknown): MovementReversalState => {
  const r = record(value)
  if (typeof r.eligible !== "boolean") throw new Error("Invalid reversal eligibility")
  return {
    movementId: text(r, "movement_id")!,
    movementType: text(r, "movement_type")!,
    originalBaseQuantity: number(r, "original_base_quantity"),
    reversedBaseQuantity: number(r, "reversed_base_quantity"),
    remainingReversibleBaseQuantity: number(r, "remaining_reversible_base_quantity"),
    eligible: r.eligible,
    reason: text(r, "reason", true),
  }
}

const parseCommand = (value: unknown): LedgerCommandResult => {
  const r = record(value)
  if (typeof r.success !== "boolean") throw new Error("Invalid ledger command success field")
  const remaining = r.remaining_reversible_base_quantity
  return {
    success: r.success,
    outcome: text(r, "outcome")!,
    clientCommandId: text(r, "client_command_id")!,
    serverCommandId: text(r, "server_command_id")!,
    code: text(r, "code", true),
    message: text(r, "message", true),
    reversalMovementId: text(r, "reversal_movement_id", true),
    remainingReversibleBaseQuantity: remaining == null ? null : number(r, "remaining_reversible_base_quantity"),
  }
}

export async function getMovementReversalState(movementId: string): Promise<MovementReversalState | null> {
  const { data, error } = await supabase.rpc("get_movement_reversal_state", { p_movement_id: movementId })
  if (error) throw error
  return data == null ? null : parseReversalState(data)
}

export async function reverseInventoryMovement(input: {
  movementId: string
  baseQuantity: number
  clientCommandId: string
  reason: string
  clientRecordedAt: string
}): Promise<LedgerCommandResult> {
  const { data, error } = await supabase.rpc("reverse_inventory_movement", {
    p_movement_id: input.movementId,
    p_base_quantity: input.baseQuantity,
    p_client_command_id: input.clientCommandId,
    p_reason_text: input.reason,
    p_client_recorded_at: input.clientRecordedAt,
  })
  if (error) throw error
  return parseCommand(data)
}
