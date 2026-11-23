import type { Color } from 'claude-code'

import type { RunSummary } from '../types'

export type Mark = { glyph: string; color: Color }

const RUN_MARKS = new Map<string, Mark>([
  ['enhanced', { glyph: '✓', color: 'success' }],
  ['failed', { glyph: '✗', color: 'error' }],
])
const OTHER_MARK: Mark = { glyph: '○', color: 'inactive' }
const AGE_UNITS = [
  { ms: 86_400_000, name: 'd' },
  { ms: 3_600_000, name: 'h' },
  { ms: 60_000, name: 'min' },
] as const
const SMALLEST_SHOWN_USD = 0.005

export function markOf(outcome: string): Mark {
  return RUN_MARKS.get(outcome) ?? OTHER_MARK
}

export function dollars(costUsd: number): string {
  return costUsd > 0 && costUsd < SMALLEST_SHOWN_USD ? '<$0.01' : `$${costUsd.toFixed(2)}`
}

function agoOf(now: number, startedAt: string): string | null {
  const elapsed = now - Date.parse(startedAt)
  if (Number.isNaN(elapsed) || elapsed < 0) {
    return null
  }
  const unit = AGE_UNITS.find(({ ms }) => elapsed >= ms)

  return unit === undefined ? 'just now' : `${Math.floor(elapsed / unit.ms)} ${unit.name} ago`
}

export function factsOf(past: RunSummary, now: number): string {
  const seconds = past.seconds === null ? null : `${past.seconds} s`
  const cost = past.costUsd === null || past.costUsd === 0 ? null : dollars(past.costUsd)

  return [agoOf(now, past.startedAt), seconds, cost].filter(fact => fact !== null).join(' · ')
}
