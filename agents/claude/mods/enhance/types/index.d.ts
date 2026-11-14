export type Seat = { kind: 'pane' | 'workspace'; id: string; pane: string }

export type Run =
  | { kind: 'idle' }
  | { kind: 'running'; runId: string; copyId: string; seat: Seat | null }
  | { kind: 'ready'; restore: string; prompt: string; notes: string; isFilled: boolean }
  | { kind: 'failed'; reason: string; notes: string }

declare module 'claude-code' {
  interface PluginState {
    enhance: { run: Shaped<Run>; hasDraft: boolean }
  }
}
