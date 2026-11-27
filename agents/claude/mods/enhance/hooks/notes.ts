import type { Enhanced, Receiver, RunRecord } from '../types'
import { dollars } from './facts'

const BULLET_LABEL = /^([-*+] )([^:*\n]{1,40}):(?= )/gm
const BULLET = /^[-*+] \*{0,2}([^:*\n]{1,40}):/
const NEXT_BULLET = /^[-*+] /

export const RECEIVER_WORDS: Record<Receiver, string> = { 'this-conversation': 'this conversation', 'new-session': 'a new session' }

export function bulletOf(notes: string, label: string): string | null {
  const bullet = notes.split('\n').find(line => BULLET.exec(line)?.[1] === label)

  return bullet === undefined ? null : bullet.slice(bullet.indexOf(':') + 1).replace(/^\*{0,2}\s*/, '').trim()
}

export function withNotes(outcome: Enhanced, lines: readonly string[]): Enhanced {
  return { ...outcome, notes: [outcome.notes, ...lines.map(line => `- ${line}`)].filter(part => part !== '').join('\n') }
}

export function withReading(outcome: Enhanced, reading: string): Enhanced {
  const lines = outcome.notes.split('\n')
  const goal = lines.findIndex(line => BULLET.exec(line)?.[1] === 'Understood goal')
  if (goal === -1) {
    return withNotes(outcome, [`Cold reader: ${reading}`])
  }
  const after = lines.findIndex((line, at) => at > goal && (line.trim() === '' || NEXT_BULLET.test(line)))
  const at = after === -1 ? lines.length : after

  return { ...outcome, notes: [...lines.slice(0, at), `- Cold reader: ${reading}`, ...lines.slice(at)].join('\n') }
}

export function shownNotes(record: RunRecord<Enhanced>): string {
  const cost = record.costUsd === null ? 'not reported' : dollars(record.costUsd)

  return withNotes(record.outcome, [`Cost: ${cost}, time: ${record.seconds} s`]).notes
}

export function withBoldLabels(notes: string): string {
  return notes.replace(BULLET_LABEL, '$1**$2:**')
}
