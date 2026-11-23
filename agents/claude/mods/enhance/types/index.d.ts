export type Run =
  | { kind: 'idle' }
  | { kind: 'running'; runId: string; copyId: string; seconds: number; progress: string | null }
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

export type Tokens = { input: number; output: number; cacheRead: number; cacheCreation: number }

export type Spent = { costUsd: number | null; turns: number; tokens: Tokens }

export type RunRecord<Outcome extends RunOutcome = RunOutcome> = Spent & {
  version: 2
  model: string | null
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
