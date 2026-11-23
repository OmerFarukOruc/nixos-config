export type Run =
  | { kind: 'idle' }
  | { kind: 'running'; runId: string; copyId: string }
  | { kind: 'ready'; copyId: string; record: RunRecord<Enhanced>; restore: string; isFilled: boolean }
  | { kind: 'failed'; reason: string; notes: string; draft: string }

export type Receiver = 'this-conversation' | 'new-session'

export type Enhanced = { kind: 'enhanced'; prompt: string; notes: string }

export type RunOutcome =
  | Enhanced
  | { kind: 'failed'; reason: string; notes: string }
  | { kind: 'dismissed' }
  | { kind: 'cancelled' }

export type Session = { id: string; cwd: string; model: string; receiver: Receiver }

export type RunRecord<Outcome extends RunOutcome = RunOutcome> = {
  version: 1
  id: string
  startedAt: string
  seconds: number
  session: Session | null
  draft: string
  outcome: Outcome
}

declare module 'claude-code' {
  interface PluginState {
    enhance: { run: Shaped<Run> }
  }
}
