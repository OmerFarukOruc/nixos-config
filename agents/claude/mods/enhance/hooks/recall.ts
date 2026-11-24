import type { EngineInterface } from 'claude-code'

let offered: string | null = null
let ticket = 0

export function forgetRecall(): void {
  offered = null
  ticket += 1
}

export function recallTicket(): number {
  return ticket
}

export async function offerDraft($: EngineInterface, held: number, draft: string): Promise<void> {
  const box = await $.prompt.read()
  if (held === ticket) {
    offered = box.text.trim() === draft.trim() ? null : draft
  }
}

export async function recallDraft($: EngineInterface, shown: string): Promise<void> {
  const draft = offered
  forgetRecall()
  if (draft === null || draft === shown) {
    return
  }
  if (!(await $.prompt.fill({ text: draft })).isFilled) {
    $.ui.toast('The draft could not go back in the box; /enhance-runs has it under Put draft in box')
  }
}

export function forgetRecallIfShown(shown: string): void {
  if (offered !== null && shown.trim() === offered.trim()) {
    forgetRecall()
  }
}
