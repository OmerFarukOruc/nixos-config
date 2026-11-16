import { atom, read, update } from 'claude-code'
import type { Elements, EngineInterface, Register, RenderSurface } from 'claude-code'

import type { Run, Seat } from '../types'
import { closeSeat, forgetCopy, headlessCopy, herdrCopy, isHerdrRunning, withDraftFile } from './copies'
import type { Cancel, Copy, CopyPlan } from './copies'
import { parseReply } from './reply'

const NOTES_PANE = 'enhance-notes'
const IDLE: Run = { kind: 'idle' }
const BULLET_LABEL = /^([-*+] )([^:*\n]{1,40}):(?= )/gm

const run = atom({ plugin: 'enhance', key: 'run' } as const, IDLE, { shape: 'run-4' })

type ActiveRun = { id: string; cancel: Cancel; copy: Copy | null; boxAtStart: string; isBoxTouched: boolean; done: Promise<void> }

type Outcome =
  | { kind: 'enhanced'; prompt: string; notes: string }
  | { kind: 'failed'; reason: string; notes: string }
  | { kind: 'dismissed' }
  | { kind: 'cancelled' }

const SESSION_END_WAIT_MS = 1200

let active: ActiveRun | null = null

function reasonOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

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

async function converse($: EngineInterface, copy: Copy, copyId: string, draft: string): Promise<Outcome> {
  const model = await $.session.model()
  let turn = await withDraftFile($, copyId, draft, path => copy.send(`/enhance-prompt for ${model}, destination chat, the file ${path} holds the draft`))
  for (;;) {
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
    turn = await copy.send(`Answer: ${answer}`)
  }
}

async function recordSeat($: EngineInterface, me: ActiveRun, copyId: string, seat: Seat): Promise<void> {
  const seated: Run = { kind: 'running', runId: me.id, copyId, seat }
  await update($, run, cur => (cur.kind === 'running' && cur.runId === me.id ? seated : cur))
}

function restoreOf(boxText: string, fallback: string): string {
  return boxText.trim() === '' ? fallback : boxText
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
    await commit($, me, { ...outcome, draft })
    return
  }

  const box = await $.prompt.read()
  if (!(await isCurrent($, me))) {
    return
  }
  const restore = restoreOf(box.text, draft)
  const isUntouched = !me.isBoxTouched && box.text === me.boxAtStart
  const isFilled = isUntouched && (await $.prompt.fill({ text: outcome.prompt })).isFilled
  if (await commit($, me, { kind: 'ready', restore, prompt: outcome.prompt, notes: outcome.notes, isFilled })) {
    await openNotes($)
  }
}

async function closeCopy($: EngineInterface, copy: Copy): Promise<void> {
  try {
    await copy.close()
  } catch (error) {
    $.ui.toast(reasonOf(error))
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
    await settle($, me, draft, await converse($, me.copy, copyId, draft))
  } catch (error) {
    await commit($, me, { kind: 'failed', reason: reasonOf(error), notes: '', draft })
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
    $.ui.toast(reasonOf(error))
  }
  await setRun($, IDLE)
}

async function transition<From extends Run>(
  $: EngineInterface,
  pick: (cur: Run) => From | null,
  to: (from: From) => Run,
): Promise<From | null> {
  const taken: { from: From | null } = { from: null }
  await update($, run, cur => {
    taken.from = pick(cur)
    return taken.from === null ? cur : to(taken.from)
  })

  return taken.from
}

type Ready = Extract<Run, { kind: 'ready' }>
type Failed = Extract<Run, { kind: 'failed' }>

async function moveBox($: EngineInterface, isFilled: boolean, textOf: (ready: Ready) => string): Promise<void> {
  const box = await $.prompt.read()
  const from = await transition(
    $,
    cur => (cur.kind === 'ready' && cur.isFilled !== isFilled ? cur : null),
    ready => ({ ...ready, isFilled, restore: isFilled ? restoreOf(box.text, ready.restore) : ready.restore }),
  )
  if (from === null || (await $.prompt.fill({ text: textOf(from) })).isFilled) {
    return
  }
  $.ui.toast('The prompt box is not available right now')
  await transition(
    $,
    cur => (cur.kind === 'ready' ? cur : null),
    () => from,
  )
}

function usePrompt($: EngineInterface): Promise<void> {
  return moveBox($, true, ready => ready.prompt)
}

function restoreDraft($: EngineInterface): Promise<void> {
  return moveBox($, false, ready => ready.restore)
}

async function copyPrompt($: EngineInterface, prompt: string, surface: RenderSurface): Promise<void> {
  try {
    const result = await $.ui.copy({ text: prompt, surface })
    $.ui.toast(result.isCopied ? 'Copied the enhanced prompt' : `Could not copy the enhanced prompt: ${result.reason}`)
  } catch (error) {
    $.ui.toast(`Could not copy the enhanced prompt: ${reasonOf(error)}`)
  }
}

async function retry($: EngineInterface): Promise<void> {
  const box = await $.prompt.read()
  const current = await read($, run)
  if (current.kind === 'failed') {
    enhance($, current.draft, box.text)
  }
}

async function cancel($: EngineInterface): Promise<void> {
  await cancelActive()
  await transition(
    $,
    cur => (cur.kind === 'running' ? cur : null),
    () => IDLE,
  )
}

async function openNotes($: EngineInterface): Promise<void> {
  try {
    await $.ui.open({ id: NOTES_PANE, title: 'Enhance notes' })
  } catch (error) {
    $.ui.toast(reasonOf(error))
  }
}

async function clear($: EngineInterface): Promise<void> {
  const from = await transition(
    $,
    cur => (cur.kind === 'ready' || cur.kind === 'failed' ? cur : null),
    () => IDLE,
  )
  if (from === null) {
    return
  }
  try {
    await $.ui.close({ id: NOTES_PANE })
  } catch (error) {
    $.ui.toast(reasonOf(error))
  }
}

type Ui = Pick<Elements[RenderSurface], 'Box' | 'Button' | 'Markdown' | 'Text'>
type Site = 'band' | 'pane'

function runningRow({ Box, Button, Text }: Ui, $: EngineInterface) {
  return (
    <Box columnGap={1}>
      <Text>Enhancing the draft…</Text>
      <Button key="cancel" label="Cancel" onPress={() => cancel($)} />
    </Box>
  )
}

function dismissButton({ Button }: Ui, $: EngineInterface, site: Site) {
  return <Button key={`${site}-dismiss`} label="Dismiss" role="dismiss" onPress={() => clear($)} />
}

function retryButton({ Button }: Ui, $: EngineInterface, site: Site) {
  return <Button key={`${site}-retry`} label="Retry" variant="primary" onPress={() => retry($)} />
}

function readyActions({ Button, Text }: Ui, $: EngineInterface, ready: Ready, site: Site) {
  return [
    <Text color="success">✓</Text>,
    <Text>{ready.isFilled ? 'Enhanced prompt is in the box' : 'Enhanced prompt is ready'}</Text>,
    !ready.isFilled && <Button key={`${site}-use`} label="Use prompt" variant="primary" onPress={() => usePrompt($)} />,
    <Button
      key={`${site}-copy`}
      label="Copy prompt"
      variant={ready.isFilled ? 'primary' : 'secondary'}
      onPress={press => copyPrompt($, ready.prompt, press.surface)}
    />,
    ready.isFilled && <Button key={`${site}-restore`} label="Restore draft" onPress={() => restoreDraft($)} />,
  ]
}

function readyRow(ui: Ui, $: EngineInterface, ready: Ready) {
  const { Box, Button } = ui

  return (
    <Box flexWrap="wrap" columnGap={1}>
      {readyActions(ui, $, ready, 'band')}
      <Button key="notes" label="Notes" onPress={() => openNotes($)} />
      {dismissButton(ui, $, 'band')}
    </Box>
  )
}

function failedRow(ui: Ui, $: EngineInterface, failed: Failed) {
  const { Box, Button, Text } = ui

  return (
    <Box columnGap={1}>
      <Box flexShrink={1}>
        <Text color="error" wrap="truncate-end">
          ✗ Enhance failed: {failed.reason.replace(/\s+/g, ' ')}
        </Text>
      </Box>
      <Box flexShrink={0} columnGap={1}>
        {retryButton(ui, $, 'band')}
        <Button key="details" label="Details" onPress={() => openNotes($)} />
        {dismissButton(ui, $, 'band')}
      </Box>
    </Box>
  )
}

function withBoldLabels(notes: string): string {
  return notes.replace(BULLET_LABEL, '$1**$2:**')
}

function readyPane(ui: Ui, $: EngineInterface, ready: Ready) {
  const { Box, Markdown, Text } = ui

  return (
    <Box flexDirection="column" rowGap={1}>
      <Box flexWrap="wrap" columnGap={1}>
        {readyActions(ui, $, ready, 'pane')}
        {dismissButton(ui, $, 'pane')}
      </Box>
      <Box flexDirection="column">
        <Text weight="bold">Notes</Text>
        {ready.notes === '' ? <Text dimColor>The copy sent no notes with this prompt.</Text> : <Markdown text={withBoldLabels(ready.notes)} />}
      </Box>
      <Box flexDirection="column" borderStyle="round" borderColor="suggestion" paddingX={1}>
        <Text weight="bold" color="suggestion">
          Enhanced prompt
        </Text>
        <Text wrap="wrap">{ready.prompt}</Text>
      </Box>
    </Box>
  )
}

function failedPane(ui: Ui, $: EngineInterface, failed: Failed) {
  const { Box, Text } = ui

  return (
    <Box flexDirection="column" rowGap={1}>
      <Box flexDirection="column">
        <Text weight="bold" color="error">
          Enhance failed
        </Text>
        <Text wrap="wrap">{failed.reason}</Text>
      </Box>
      <Box columnGap={1}>
        {retryButton(ui, $, 'pane')}
        {dismissButton(ui, $, 'pane')}
      </Box>
      {failed.notes !== '' && (
        <Box flexDirection="column">
          <Text weight="bold">Reply from the copy</Text>
          <Text wrap="wrap">{failed.notes}</Text>
        </Box>
      )}
    </Box>
  )
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
      $.ui.toast('Type the draft after /enhance')
      return {}
    }

    enhance($, draft, '')

    return {}
  })

  on('prompt.edit', async ($, e, next) => {
    markTouched()

    return next(e)
  })

  on('prompt.change', async ($, e, next) => {
    const isOtherPlugin = e.origin.kind === 'plugin' && e.origin.name !== 'enhance'
    if (isOtherPlugin || e.origin.kind === 'history' || e.origin.kind === 'undo' || e.origin.kind === 'app' || e.origin.kind === 'engine') {
      markTouched()
    }

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
    await clear($)
    markTouched()

    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: NOTES_PANE }, async ($, e) => {
    const ui = $.ui.resolve(e)
    const current = await read($, run)
    if (current.kind === 'ready') {
      return readyPane(ui, $, current)
    }
    if (current.kind === 'failed') {
      return failedPane(ui, $, current)
    }

    return (
      <ui.Text dimColor wrap="wrap">
        {current.kind === 'running' ? 'Enhancing the draft. The notes show here when it ends.' : 'Notes show here after an enhancement.'}
      </ui.Text>
    )
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) {
      return next(e)
    }

    const ui = $.ui.resolve(e)
    const current = await read($, run)
    if (current.kind === 'running') {
      return runningRow(ui, $)
    }
    if (current.kind === 'ready') {
      return readyRow(ui, $, current)
    }
    if (current.kind === 'failed') {
      return failedRow(ui, $, current)
    }

    return next(e)
  })
}
