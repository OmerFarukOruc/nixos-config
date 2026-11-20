export type Run =
  | { kind: 'idle' }
  | { kind: 'running'; runId: string; copyId: string }
  | { kind: 'ready'; restore: string; prompt: string; notes: string; isFilled: boolean }
  | { kind: 'failed'; reason: string; notes: string; draft: string }

export type Receiver = 'this-conversation' | 'new-session'

export type RunOutcome =
  | { kind: 'enhanced'; prompt: string; notes: string }
  | { kind: 'failed'; reason: string; notes: string }
  | { kind: 'dismissed' }
  | { kind: 'cancelled' }

export type Session = { id: string; cwd: string; model: string; receiver: Receiver }

export type RunRecord = {
  version: 1
  id: string
  startedAt: string
  seconds: number
  session: Session | null
  draft: string
  outcome: RunOutcome
}

declare module 'claude-code' {
  interface PluginState {
    enhance: { run: Shaped<Run> }
  }
}
