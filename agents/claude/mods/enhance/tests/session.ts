import { mock } from 'claude-code/testing'
import type { On } from 'claude-code'

import type { RunRecord } from '../types'

export const SESSION_ID = '11111111-1111-4111-8111-111111111111'
export const RUNS_DIR = '/home/t/.local/state/enhance/runs'

export type Script = {
  replies: readonly string[]
  box?: string
  turns?: number
  answers?: readonly (string | null)[]
  exists?: (path: string) => boolean
  files?: Readonly<Record<string, string>>
}

export type Seen = {
  spawned: { argv: readonly string[]; input: string | undefined }[]
  ran: (readonly string[])[]
  copied: string[]
  written: Map<string, string>
  toasts: string[]
  notified: string[]
  submitted: string[]
  box: { text: string }
  clock: ReturnType<typeof mock.clock>
}

export function resultLine(text: string): string {
  return `${JSON.stringify({ type: 'result', is_error: false, result: text })}\n`
}

export function stubSession(on: On, script: Script): Seen {
  const replies = [...script.replies]
  const answers = [...(script.answers ?? [])]
  const seen: Seen = {
    spawned: [],
    ran: [],
    copied: [],
    written: new Map(Object.entries(script.files ?? {})),
    toasts: [],
    notified: [],
    submitted: [],
    box: { text: script.box ?? '' },
    clock: mock.clock(on, { now: Date.UTC(2026, 10, 23, 12) }),
  }
  mock.env(on, { HOME: '/home/t' })
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('command.register', (_, e) => ({ value: { command: e.name } }))
  on('session.id', () => ({ value: SESSION_ID }))
  on('session.cwd', () => ({ value: '/work' }))
  on('session.model', () => ({ value: 'claude-test-1' }))
  on('session.turns', () => ({ value: script.turns ?? 0 }))
  on('settings.read', () => ({ value: {} }))
  on('fs.exists', (_, e) => ({ value: script.exists?.(e.path) ?? (e.path === '/work' || e.path === RUNS_DIR) }))
  on('fs.write', (_, e) => {
    seen.written.set(e.path, e.text)
    return { value: undefined }
  })
  on('fs.read', (_, e) => {
    const text = seen.written.get(e.path)

    return text === undefined ? { deny: `no file ${e.path}` } : { value: text }
  })
  on('fs.list', (_, e) => ({
    value: [...seen.written.keys()].flatMap(path => {
      const name = path.startsWith(`${e.path}/`) ? path.slice(e.path.length + 1) : '/'
      return name.includes('/') ? [] : [{ name, kind: 'file' as const, size: 1, mtimeMs: 0, isLink: false }]
    }),
  }))
  on('process.run', (_, e) => {
    seen.ran.push(e.argv)

    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('process.spawn', async function* (_, e) {
    seen.spawned.push({ argv: e.argv, input: e.input })
    yield { stream: 'stdout', text: replies.shift() ?? '' }

    return { value: { code: 0, signal: null } }
  })
  on('prompt.read', () => ({ value: { text: seen.box.text, cursor: 0 } }))
  on('prompt.fill', (_, e) => {
    seen.box.text = e.text

    return { isFilled: true }
  })
  on('prompt.submit', (_, e) => {
    seen.submitted.push(e.text)

    return { text: e.text }
  })
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('ui.close', () => ({ value: undefined }))
  on('ui.toast', (_, e) => {
    seen.toasts.push(e.text)

    return { value: undefined }
  })
  on('ui.notify', (_, e) => {
    seen.notified.push(e.text)

    return { value: { isSent: true, channel: 'terminal_bell' } }
  })
  on('ui.copy', (_, e) => {
    seen.copied.push(e.text)

    return { value: { isCopied: true } }
  })
  on('tool.call', { tool: 'AskUserQuestion' }, (_, e) => {
    const answer = answers.shift() ?? null
    if (answer === null) {
      throw new Error('dismissed')
    }

    return { result: { answers: Object.fromEntries(e.questions.map(asked => [asked.question, answer])) } }
  })

  return seen
}

export function lastRecord(seen: Seen): RunRecord {
  const records = [...seen.written].flatMap(([path, text]) => (path.includes('/enhance/runs/') ? [text] : []))

  return JSON.parse(records.at(-1) ?? 'null') as RunRecord
}
