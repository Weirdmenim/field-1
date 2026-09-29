export function roundQuantity(value: number, scale = 0): number {
  if (!Number.isFinite(value)) return 0
  const factor = 10 ** Math.max(0, Math.min(scale, 6))
  return Math.round((value + Number.EPSILON) * factor) / factor
}

export function clampQuantity(value: number, scale = 0, min = 0, max?: number): number {
  const bounded = Math.max(min, max == null ? value : Math.min(value, max))
  return roundQuantity(bounded, scale)
}

export function formatQuantity(value: number, scale = 0): string {
  const normalized = roundQuantity(value, scale)
  if (scale <= 0) return String(Math.trunc(normalized))
  return normalized.toFixed(scale).replace(/(?:\.0+|(?:(\.[0-9]*?)0+))$/, '$1')
}
