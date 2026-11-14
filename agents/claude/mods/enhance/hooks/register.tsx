import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Run, Seat } from '../types'
import { closeSeat, forgetCopy, headlessCopy, herdrCopy, isHerdrRunning } from './copies'
import type { Cancel, Copy, CopyPlan } from './copies'
import { parseReply } from './reply'

const NOTES_PANE = 'enhance-notes'
const IDLE: Run = { kind: 'idle' }

const run = atom({ plugin: 'enhance', key: 'run' } as const, IDLE, { shape: 'run-3' })
const hasDraft = atom({ plugin: 'enhance', key: 'hasDraft' } as const, false)

type ActiveRun = { id: string; cancel: Cancel; copy: Copy | null; boxAtStart: string; isBoxTouched: boolean; done: Promise<void> }

type Outcome =
  | { kind: 'enhanced'; prompt: string; notes: string }
  | { kind: 'failed'; reason: string; notes: string }
  | { kind: 'dismissed' }
  | { kind: 'cancelled' }

const SESSION_END_WAIT_MS = 1200

let active: ActiveRun | null = null

function setRun($: EngineInterface, value: Run): Promise<Run> {
  return update($, run, () => value)
}

async function commit($: EngineInterface, me: ActiveRun, next: Run): Promise<boolean> {
  const after = await update($, run, cur => (cur.kind === 'running' && cur.runId === me.id && !me.cancel.isCancelled ? next : cur))

  return after === next
}

async function isCurrent($: EngineInterface, me: ActiveRun): Promise<boolean> {
  const state = await read($, run)

  return !me.cancel.isCancelled && state.kind === 'running' && state.runId === me.id
}

async function openCopy($: EngineInterface, plan: CopyPlan): Promise<Copy> {
  if ((await $.env.get('HERDR_ENV')) === '1') {
    return herdrCopy($, plan, 'beside-session')
  }

  return (await isHerdrRunning($)) ? herdrCopy($, plan, 'new-workspace') : headlessCopy($, plan)
}

async function ask($: EngineInterface, question: string, options: readonly string[]): Promise<string | null> {
  try {
    return options.length >= 2
      ? await $.ui.ask(question, { options: options.slice(0, 4), header: 'Enhance' })
      : await $.ui.ask(`${question} Type the answer under Other.`)
  } catch {
    return null
  }
}

async function converse($: EngineInterface, copy: Copy, draft: string): Promise<Outcome> {
  let text = `/enhance-prompt for ${await $.session.model()}, destination chat: ${draft}`
  for (;;) {
    const turn = await copy.send(text)
    if (turn.kind !== 'reply') {
      return turn
    }

    const reply = parseReply(turn.text)
    if (reply.kind === 'unusable') {
      return { kind: 'failed', reason: reply.reason, notes: turn.text }
    }
    if (reply.kind === 'prompt') {
      return { kind: 'enhanced', prompt: reply.prompt, notes: reply.notes }
    }

    const answer = await ask($, reply.question, reply.options)
    if (answer === null) {
      return { kind: 'dismissed' }
    }
    text = `Answer: ${answer}`
  }
}

async function recordSeat($: EngineInterface, me: ActiveRun, copyId: string, seat: Seat): Promise<void> {
  const seated: Run = { kind: 'running', runId: me.id, copyId, seat }
  await update($, run, cur => (cur.kind === 'running' && cur.runId === me.id ? seated : cur))
}

async function settle($: EngineInterface, me: ActiveRun, draft: string, outcome: Outcome): Promise<void> {
  if (outcome.kind === 'cancelled') {
    return
  }
  if (outcome.kind === 'dismissed') {
    await commit($, me, IDLE)
    return
  }
  if (outcome.kind === 'failed') {
    await commit($, me, outcome)
    return
  }

  const box = await $.prompt.read()
  if (!(await isCurrent($, me))) {
    return
  }
  const restore = box.text.trim() === '' ? draft : box.text
  const isUntouched = !me.isBoxTouched && box.text === me.boxAtStart
  const isFilled = isUntouched && (await $.prompt.fill({ text: outcome.prompt })).isFilled
  await commit($, me, { kind: 'ready', restore, prompt: outcome.prompt, notes: outcome.notes, isFilled })
}

async function closeCopy($: EngineInterface, copy: Copy): Promise<void> {
  try {
    await copy.close()
  } catch (error) {
    $.ui.toast(error instanceof Error ? error.message : String(error))
  }
}

async function runCopy($: EngineInterface, me: ActiveRun, copyId: string, draft: string): Promise<void> {
  try {
    await setRun($, { kind: 'running', runId: me.id, copyId, seat: null })
    const parentId = (await $.session.turns()) > 0 ? await $.session.id() : null
    me.copy = await openCopy($, {
      sessionId: copyId,
      parentId,
      cwd: await $.session.cwd(),
      cancel: me.cancel,
      onSeat: seat => recordSeat($, me, copyId, seat),
    })
    await settle($, me, draft, await converse($, me.copy, draft))
  } catch (error) {
    await commit($, me, { kind: 'failed', reason: error instanceof Error ? error.message : String(error), notes: '' })
  } finally {
    if (active === me) {
      active = null
    }
    if (me.copy !== null) {
      await closeCopy($, me.copy)
    }
  }
}

function enhance($: EngineInterface, draft: string, boxAtStart: string): void {
  if (active !== null && !active.cancel.isCancelled) {
    $.ui.toast('An enhancement is already running')
    return
  }

  const me: ActiveRun = {
    id: crypto.randomUUID(),
    cancel: { isCancelled: false },
    copy: null,
    boxAtStart,
    isBoxTouched: false,
    done: Promise.resolve(),
  }
  active = me
  me.done = runCopy($, me, crypto.randomUUID(), draft)
}

async function cancelActive(): Promise<ActiveRun | null> {
  const me = active
  if (me === null) {
    return null
  }
  me.cancel.isCancelled = true
  await me.copy?.stop()

  return me
}

function markTouched(): void {
  if (active !== null) {
    active.isBoxTouched = true
  }
}

async function cleanUpLeftover($: EngineInterface): Promise<void> {
  const state = await read($, run)
  if (state.kind !== 'running') {
    return
  }
  try {
    if (state.seat !== null && !(await closeSeat($, state.seat))) {
      throw new Error(`herdr could not close the leftover copy's ${state.seat.kind} ${state.seat.id}; close it yourself`)
    }
    await forgetCopy($, state.copyId)
  } catch (error) {
    $.ui.toast(error instanceof Error ? error.message : String(error))
  }
  await setRun($, IDLE)
}

async function noteDraft($: EngineInterface, text: string): Promise<void> {
  const isTyped = text.trim() !== ''
  if (isTyped !== (await read($, hasDraft))) {
    await update($, hasDraft, () => isTyped)
  }
}

async function useText($: EngineInterface, text: string, next: Run) {
  const filled = await $.prompt.fill({ text })
  if (filled.isFilled) {
    await setRun($, next)
  } else {
    $.ui.toast('The prompt box is not available right now')
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await cleanUpLeftover($)
    await $.command.register({
      name: 'enhance',
      description: 'Enhance a draft with /enhance-prompt and put the result in the prompt box',
      argumentHint: '<draft>',
      immediate: true,
    })

    return next(e)
  })

  on('command.run', { command: 'enhance' }, async ($, e) => {
    const draft = e.args.trim()
    if (draft === '') {
      $.ui.toast('Type the draft after /enhance, or press Enhance above a typed draft')
      return {}
    }

    enhance($, draft, '')

    return {}
  })

  on('prompt.edit', async ($, e, next) => {
    markTouched()
    const box = await next(e)
    await noteDraft($, box.text)

    return box
  })

  on('prompt.change', async ($, e, next) => {
    if (e.origin.kind === 'history' || e.origin.kind === 'undo' || e.origin.kind === 'app' || e.origin.kind === 'engine') {
      markTouched()
    }
    await noteDraft($, e.text)

    return next(e)
  })

  on('session.end', async ($, e, next) => {
    const me = await cancelActive()
    if (me !== null) {
      await Promise.race([me.done, $.clock.sleep(SESSION_END_WAIT_MS)])
    }

    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    const current = await read($, run)
    if (current.kind === 'ready' || current.kind === 'failed') {
      await setRun($, IDLE)
    }
    markTouched()

    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: NOTES_PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const current = await read($, run)
    const notes = current.kind === 'ready' || current.kind === 'failed' ? current.notes : ''

    return (
      <Box flexDirection="column">
        <Text wrap="wrap">{notes === '' ? 'Notes show here after an enhancement.' : notes}</Text>
      </Box>
    )
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) {
      return next(e)
    }

    const current = await read($, run)
    const { Box, Button, Text } = $.ui.resolve(e)
    const openNotes = () => void $.ui.open({ id: NOTES_PANE, title: 'Enhance notes' })

    if (current.kind === 'running') {
      return (
        <Box>
          <Text dimColor>Enhancing the draft… </Text>
          <Button
            key="cancel"
            label="Cancel"
            onPress={async () => {
              await cancelActive()
              await setRun($, IDLE)
            }}
          />
        </Box>
      )
    }

    if (current.kind === 'ready') {
      return (
        <Box>
          <Text dimColor>{current.isFilled ? 'Enhanced prompt is in the box ' : 'Enhanced prompt is ready '}</Text>
          {current.isFilled ? (
            <Button key="undo" label="Undo" onPress={() => useText($, current.restore, IDLE)} />
          ) : (
            <Button key="use" label="Use" onPress={() => useText($, current.prompt, { ...current, isFilled: true })} />
          )}
          <Text> </Text>
          <Button key="notes" label="Notes" onPress={openNotes} />
        </Box>
      )
    }

    if (current.kind === 'failed') {
      return (
        <Box>
          <Text color="red" wrap="truncate-end">
            Enhance failed: {current.reason}{' '}
          </Text>
          <Button key="dismiss" label="Dismiss" onPress={() => setRun($, IDLE)} />
          {current.notes !== '' && <Text> </Text>}
          {current.notes !== '' && <Button key="notes" label="Reply" onPress={openNotes} />}
        </Box>
      )
    }

    if (!(await read($, hasDraft))) {
      return next(e)
    }

    return (
      <Box>
        <Button
          key="enhance"
          label="Enhance"
          onPress={async () => {
            const box = await $.prompt.read()
            if (box.text.trim() !== '') {
              enhance($, box.text, box.text)
            }
          }}
        />
      </Box>
    )
  })
}
