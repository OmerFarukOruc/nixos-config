import { atom, read, update } from 'claude-code'
import type { Elements, EngineInterface, PluginOptions, Register, RenderSurface } from 'claude-code'

import type { Enhanced, Receiver, Run, RunOutcome, RunRecord, RunSummary, Sent, Session } from '../types'
import { forgetCopy, headlessCopy, withDraftFile, withImagePaths } from './copies'
import { liveEffort, trackEffort } from './effort'
import type { Cancel, Copy, Turn, Writer } from './copies'
import { missingFrom } from './missing'
import { guidesOf, pruneRecords, recentRuns, skillSha256, writeRecord } from './records'
import { NOTHING_SPENT, parseReply, plus } from './reply'

const NOTES_PANE = 'enhance-notes'
const RUNS_PANE = 'enhance-runs'
const IDLE: Run = { kind: 'idle', isDraftBack: false }
const NO_DRAFT = 'Type the draft after /enhance'
const NO_ANSWER = 'Answer: none; continue, and state what you assume as an `Assuming:` line in the prompt'
const BIND_ACTION = 'app:cycleDiffBase'
const BULLET_LABEL = /^([-*+] )([^:*\n]{1,40}):(?= )/gm
const BULLET = /^[-*+] \*{0,2}([^:*\n]{1,40}):/
const NEXT_BULLET = /^[-*+] /

const run = atom({ plugin: 'enhance', key: 'run' } as const, IDLE, { shape: 'run-6' })
const lastDraft = atom({ plugin: 'enhance', key: 'lastDraft' } as const, null, { shape: 'draft-1' })
const recent = atom({ plugin: 'enhance', key: 'recent' } as const, [], { shape: 'recent-1' })

type Running = Extract<Run, { kind: 'running' }>
type Ready = Extract<Run, { kind: 'ready' }>
type Failed = Extract<Run, { kind: 'failed' }>
type Task = { draft: string; revise: { from: Ready; text: string } | null }
type ActiveRun = {
  id: string
  copyId: string
  task: Task
  cancel: Cancel
  copy: Copy | null
  boxAtStart: string
  isBoxTouched: boolean
  done: Promise<void>
}
type Began = { at: number | null; session: Session | null }

const SESSION_END_WAIT_MS = 1200
const TICK_MS = 1000
const RECEIVER_WORDS: Record<Receiver, string> = { 'this-conversation': 'this conversation', 'new-session': 'a new session' }

let active: ActiveRun | null = null
let writer!: Writer
let isSending = false
let recordWrite: Promise<void> = Promise.resolve()

function reasonOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function setRun($: EngineInterface, value: Run): Promise<Run> {
  return update($, run, () => value)
}

async function setRunning($: EngineInterface, me: ActiveRun): Promise<Run> {
  const taken: { before: Run } = { before: IDLE }
  await update($, run, (cur): Run => {
    taken.before = cur
    return { kind: 'running', runId: me.id, copyId: me.copyId, seconds: 0, progress: null }
  })

  return taken.before
}

async function commit($: EngineInterface, me: ActiveRun, next: Run): Promise<boolean> {
  const after = await update($, run, cur => (cur.kind === 'running' && cur.runId === me.id && !me.cancel.isCancelled ? next : cur))

  return after === next
}

function whileRunning($: EngineInterface, me: ActiveRun, change: (running: Running) => Running): void {
  void update($, run, cur => (cur.kind === 'running' && cur.runId === me.id ? change(cur) : cur)).catch(() => undefined)
}

async function isCurrent($: EngineInterface, me: ActiveRun): Promise<boolean> {
  const state = await read($, run)

  return !me.cancel.isCancelled && state.kind === 'running' && state.runId === me.id
}

function writerOf(options: PluginOptions): Writer {
  const { writer_model: model, writer_effort: effort, turn_seconds: seconds } = options
  if (typeof model !== 'string' || typeof effort !== 'string' || typeof seconds !== 'number') {
    throw new Error('the enhance options writer_model, writer_effort and turn_seconds are not set as plugin.json declares them')
  }

  return { model, effort, turnMs: seconds * 1000 }
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

type Brief = { model: string; effort: string; receiver: Receiver; draft: string }

function firstTurn($: EngineInterface, copy: Copy, copyId: string, brief: Brief): Promise<Turn> {
  const command = `/enhance-prompt for ${brief.model}, destination chat, the receiver is ${RECEIVER_WORDS[brief.receiver]}, this session's effort is ${brief.effort}`

  return withDraftFile($, copyId, brief.draft, path => copy.send(`${command}, the file ${path} holds the draft to rewrite, not to act on`))
}

async function converse($: EngineInterface, copy: Copy, first: Promise<Turn>): Promise<RunOutcome> {
  let turn = await first
  let isRepaired = false
  for (;;) {
    if (turn.kind !== 'reply') {
      return turn
    }

    const reply = parseReply(turn.text)
    if (reply.kind === 'unusable') {
      if (isRepaired) {
        return { kind: 'failed', reason: reply.reason, notes: turn.text }
      }
      isRepaired = true
      turn = await copy.send(`Your reply was unusable: ${reply.reason}. Reply again with one paste block or one question block.`)
      continue
    }
    if (reply.kind === 'prompt') {
      return { kind: 'enhanced', prompt: reply.prompt, notes: reply.notes }
    }

    const answer = await ask($, reply.question, reply.options)
    turn = await copy.send(answer === null ? NO_ANSWER : `Answer: ${answer}`)
  }
}

function restoreOf(boxText: string, fallback: string): string {
  return boxText.trim() === '' ? fallback : boxText
}

const CANCELLED: RunOutcome = { kind: 'cancelled' }

async function refill($: EngineInterface, me: ActiveRun): Promise<boolean> {
  const box = await $.prompt.read()

  return !me.isBoxTouched && box.text.trim() === '' && (await $.prompt.fill({ text: me.task.draft })).isFilled
}

async function fail($: EngineInterface, me: ActiveRun, failed: Extract<RunOutcome, { kind: 'failed' }>): Promise<boolean> {
  const { revise } = me.task
  if (revise === null) {
    return commit($, me, { ...failed, draft: me.task.draft, isDraftBack: await refill($, me) })
  }
  const earlier = { ...revise.from, record: { ...revise.from.record, ...plus(revise.from.record, me.copy?.spent() ?? NOTHING_SPENT) } }
  const isBack = await commit($, me, earlier)
  if (isBack) {
    keepRecord($, earlier.record)
    $.ui.toast(`Revise failed, and the earlier prompt stays: ${failed.reason.replace(/\s+/g, ' ')}`)
  }

  return isBack
}

async function announce($: EngineInterface, outcome: RunOutcome): Promise<void> {
  if (outcome.kind === 'cancelled') {
    return
  }
  try {
    await $.ui.notify(outcome.kind === 'enhanced' ? 'Enhanced prompt is ready' : 'Enhance failed', { title: 'Enhance' })
  } catch (error) {
    $.ui.toast(reasonOf(error))
  }
}

async function recordOf<Outcome extends RunOutcome>(
  $: EngineInterface,
  me: ActiveRun,
  task: Task,
  began: Began,
  outcome: Outcome,
): Promise<RunRecord<Outcome>> {
  const endedAt = await $.clock.now()
  const startedAt = began.at ?? endedAt
  const prior = task.revise?.from.record
  const turns = me.copy?.spent() ?? { ...NOTHING_SPENT, model: null }
  const notes = outcome.kind === 'enhanced' ? outcome.notes : ''
  const guides = await guidesOf($, startedAt, notes)

  return {
    ...plus(prior ?? NOTHING_SPENT, turns),
    version: 2,
    model: turns.model ?? prior?.model ?? null,
    skillSha256: await skillSha256($),
    guides: [...(prior?.guides ?? []).filter(old => !guides.some(guide => guide.url === old.url)), ...guides],
    case: bulletOf(notes, 'Case') ?? prior?.case ?? null,
    sent: null,
    id: me.id,
    startedAt: prior?.startedAt ?? new Date(startedAt).toISOString(),
    seconds: (prior?.seconds ?? 0) + Math.round((endedAt - startedAt) / 1000),
    session: began.session,
    draft: task.draft,
    outcome,
  }
}

async function settle($: EngineInterface, me: ActiveRun, task: Task, began: Began, outcome: RunOutcome): Promise<RunRecord> {
  if (outcome.kind === 'cancelled') {
    return recordOf($, me, task, began, outcome)
  }
  if (outcome.kind === 'failed') {
    return recordOf($, me, task, began, (await fail($, me, outcome)) ? outcome : CANCELLED)
  }

  const box = await $.prompt.read()
  if (!(await isCurrent($, me))) {
    return recordOf($, me, task, began, CANCELLED)
  }
  const restore = task.revise?.from.restore ?? restoreOf(box.text, task.draft)
  const record = await recordOf($, me, task, began, outcome)
  const isUntouched = !me.isBoxTouched && box.text === me.boxAtStart
  const isFilled = isUntouched && (await isCurrent($, me)) && (await $.prompt.fill({ text: outcome.prompt })).isFilled
  keepRecord($, record)
  if (!(await commit($, me, { kind: 'ready', copyId: me.copyId, record, restore, isFilled }))) {
    return recordOf($, me, task, began, CANCELLED)
  }
  await openNotes($)

  return record
}

async function closeCopy($: EngineInterface, copy: Copy): Promise<void> {
  try {
    await copy.close()
  } catch (error) {
    $.ui.toast(reasonOf(error))
  }
}

async function sessionOf($: EngineInterface): Promise<Session> {
  const [id, cwd, model, turns] = await Promise.all([$.session.id(), $.session.cwd(), $.session.model(), $.session.turns()])

  return { id, cwd, model, receiver: turns > 0 ? 'this-conversation' : 'new-session' }
}

function bulletOf(notes: string, label: string): string | null {
  const bullet = notes.split('\n').find(line => BULLET.exec(line)?.[1] === label)

  return bullet === undefined ? null : bullet.slice(bullet.indexOf(':') + 1).replace(/^\*{0,2}\s*/, '').trim()
}

function withNotes(outcome: Enhanced, lines: readonly string[]): Enhanced {
  return { ...outcome, notes: [outcome.notes, ...lines.map(line => `- ${line}`)].filter(part => part !== '').join('\n') }
}

function withReading(outcome: Enhanced, reading: string): Enhanced {
  const lines = outcome.notes.split('\n')
  const goal = lines.findIndex(line => BULLET.exec(line)?.[1] === 'Understood goal')
  if (goal === -1) {
    return withNotes(outcome, [`Cold reader: ${reading}`])
  }
  const after = lines.findIndex((line, at) => at > goal && (line.trim() === '' || NEXT_BULLET.test(line)))
  const at = after === -1 ? lines.length : after

  return { ...outcome, notes: [...lines.slice(0, at), `- Cold reader: ${reading}`, ...lines.slice(at)].join('\n') }
}

function shownNotes(record: RunRecord<Enhanced>): string {
  const cost = record.costUsd === null ? 'not reported' : `$${record.costUsd.toFixed(2)}`

  return withNotes(record.outcome, [`Cost: ${cost}, time: ${record.seconds} s`]).notes
}

async function replyOf($: EngineInterface, me: ActiveRun, session: Session, task: Task): Promise<RunOutcome> {
  if (!(await $.fs.exists(session.cwd))) {
    throw new Error(`this session's folder ${session.cwd} was deleted; restart Claude Code in an existing folder`)
  }
  const copy = headlessCopy($, {
    sessionId: me.copyId,
    parentId: session.receiver === 'this-conversation' ? session.id : null,
    isStarted: task.revise !== null,
    writer,
    cancel: me.cancel,
    onProgress: progress => whileRunning($, me, running => ({ ...running, progress })),
  })
  me.copy = copy
  const first =
    task.revise === null
      ? firstTurn($, copy, me.copyId, {
          model: session.model,
          effort: await liveEffort($, session.model),
          receiver: session.receiver,
          draft: await withImagePaths($, session, task.draft),
        })
      : copy.send(`Revise: ${task.revise.text}`)
  const outcome = await converse($, copy, first)
  if (outcome.kind !== 'enhanced') {
    return outcome
  }
  const reading = await copy.read(outcome.prompt)
  if (me.cancel.isCancelled) {
    return CANCELLED
  }

  return withNotes(
    reading === null ? outcome : withReading(outcome, reading),
    missingFrom(task.draft, outcome.prompt).map(item => `Not in the prompt: ${item}`),
  )
}

function keepRecord($: EngineInterface, record: RunRecord): void {
  recordWrite = recordWrite
    .then(() => writeRecord($, record))
    .catch((error: unknown) => $.ui.toast(`Could not keep the enhance run record: ${reasonOf(error)}`))
}

async function leaveReady($: EngineInterface, ready: Ready, sent: Sent): Promise<void> {
  keepRecord($, { ...ready.record, sent })
  await forget($, ready.copyId)
}

async function forget($: EngineInterface, copyId: string): Promise<void> {
  try {
    await forgetCopy($, copyId)
  } catch (error) {
    $.ui.toast(reasonOf(error))
  }
}

async function runCopy($: EngineInterface, me: ActiveRun, task: Task): Promise<void> {
  const began: Began = { at: null, session: task.revise?.from.record.session ?? null }
  let record: RunRecord | null = null
  const ticker = $.clock.every(TICK_MS, () => whileRunning($, me, running => ({ ...running, seconds: running.seconds + 1 })))
  try {
    const before = await setRunning($, me)
    if (before.kind === 'ready' && before.copyId !== me.copyId) {
      await leaveReady($, before, 'dropped')
    }
    began.at = await $.clock.now()
    began.session ??= await sessionOf($)
    record = await settle($, me, task, began, await replyOf($, me, began.session, task))
  } catch (error) {
    const failed = { kind: 'failed', reason: reasonOf(error), notes: '' } as const
    record = await recordOf($, me, task, began, (await fail($, me, failed)) ? failed : CANCELLED)
  } finally {
    ticker.cancel()
    if (active === me) {
      active = null
    }
    await finish($, me, record)
  }
}

async function finish($: EngineInterface, me: ActiveRun, record: RunRecord | null): Promise<void> {
  const isReady = record?.outcome.kind === 'enhanced'
  const isEarlierKept = !isReady && me.task.revise !== null
  if (record !== null && !isReady && !isEarlierKept) {
    keepRecord($, record)
  }
  if (me.copy !== null && !isReady && !isEarlierKept) {
    await closeCopy($, me.copy)
  }
  if (record !== null) {
    await announce($, record.outcome)
  }
}

function start($: EngineInterface, task: Task, boxAtStart: string): boolean {
  if (active !== null && !active.cancel.isCancelled) {
    $.ui.toast('An enhancement is already running')
    return false
  }

  const me: ActiveRun = {
    id: task.revise?.from.record.id ?? crypto.randomUUID(),
    copyId: task.revise?.from.copyId ?? crypto.randomUUID(),
    task,
    cancel: { isCancelled: false },
    copy: null,
    boxAtStart,
    isBoxTouched: false,
    done: Promise.resolve(),
  }
  active = me
  me.done = runCopy($, me, task)

  return true
}

function enhance($: EngineInterface, draft: string, boxAtStart: string): void {
  if (start($, { draft, revise: null }, boxAtStart)) {
    void update($, lastDraft, () => draft).catch((error: unknown) => $.ui.toast(`Could not keep the draft for the runs pane: ${reasonOf(error)}`))
  }
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

async function markTouched($: EngineInterface): Promise<void> {
  if (active !== null) {
    active.isBoxTouched = true
  }
  await update($, run, cur => (cur.kind === 'idle' && cur.isDraftBack ? IDLE : cur))
}

async function enhanceBox($: EngineInterface): Promise<void> {
  const box = await $.prompt.read()
  if (box.text.trim() === '') {
    $.ui.toast(NO_DRAFT)
    return
  }
  enhance($, box.text.trim(), box.text)
}

async function send($: EngineInterface): Promise<void> {
  const ready = await read($, run)
  if (ready.kind !== 'ready' || isSending) {
    return
  }
  isSending = true
  try {
    const { prompt } = ready.record.outcome
    const entered = await $.prompt.submit({ text: prompt, asUser: true })
    if ('drop' in entered) {
      $.ui.toast(`The enhanced prompt was not sent: ${entered.drop}`)
      return
    }
    await clear($, () => 'as-is')
    if ((await $.prompt.read()).text === prompt) {
      await $.prompt.fill({ text: '' })
    }
  } catch (error) {
    $.ui.toast(`Could not send the enhanced prompt: ${reasonOf(error)}`)
  } finally {
    isSending = false
  }
}

async function cleanUpLeftover($: EngineInterface): Promise<void> {
  const state = await read($, run)
  if (state.kind === 'ready') {
    await leaveReady($, state, 'dropped')
  }
  if (state.kind === 'running') {
    await forget($, state.copyId)
  }
  if (state.kind === 'running' || state.kind === 'ready') {
    await setRun($, IDLE)
  }
}

async function wrapUp($: EngineInterface, me: ActiveRun | null): Promise<void> {
  await me?.done
  await cleanUpLeftover($)
  await recordWrite
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
  return moveBox($, true, ready => ready.record.outcome.prompt)
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

async function revise($: EngineInterface): Promise<void> {
  const text = (await ask($, 'What should change in the prompt?', []))?.trim() ?? ''
  const box = await $.prompt.read()
  const from = await read($, run)
  if (text !== '' && from.kind === 'ready') {
    start($, { draft: from.record.draft, revise: { from, text } }, box.text)
  }
}

async function cancel($: EngineInterface): Promise<void> {
  const me = await cancelActive()
  const earlier = me?.task.revise?.from ?? null
  const isDraftBack = me !== null && earlier === null && (await refill($, me))
  await transition(
    $,
    cur => (cur.kind === 'running' && (me === null || cur.runId === me.id) ? cur : null),
    () => earlier ?? { kind: 'idle', isDraftBack },
  )
}

async function openNotes($: EngineInterface): Promise<void> {
  try {
    await $.ui.open({ id: NOTES_PANE, title: 'Enhance notes' })
  } catch (error) {
    $.ui.toast(reasonOf(error))
  }
}

function sentOf(record: RunRecord<Enhanced>, text: string): Sent {
  if (text.trim() === record.outcome.prompt.trim()) {
    return 'as-is'
  }

  return text.trim() === record.draft.trim() ? 'own-draft' : 'edited'
}

async function openRuns($: EngineInterface): Promise<void> {
  try {
    const runs = await recentRuns($)
    await update($, recent, () => runs)
    await $.ui.open({ id: RUNS_PANE, title: 'Enhance runs' })
  } catch (error) {
    $.ui.toast(reasonOf(error))
  }
}

async function putBack($: EngineInterface, draft: string): Promise<void> {
  if (!(await $.prompt.fill({ text: draft })).isFilled) {
    $.ui.toast('The prompt box is not available right now')
  }
}

async function clear($: EngineInterface, sent: (record: RunRecord<Enhanced>) => Sent): Promise<void> {
  const from = await transition(
    $,
    cur => (cur.kind === 'ready' || cur.kind === 'failed' ? cur : null),
    () => IDLE,
  )
  if (from === null) {
    return
  }
  if (from.kind === 'ready') {
    await leaveReady($, from, sent(from.record))
  }
  try {
    await $.ui.close({ id: NOTES_PANE })
  } catch (error) {
    $.ui.toast(reasonOf(error))
  }
}

type Ui = Pick<Elements[RenderSurface], 'Box' | 'Button' | 'Markdown' | 'Text'>
type Site = 'band' | 'pane'

function runningRow({ Box, Button, Text }: Ui, $: EngineInterface, running: Running) {
  return (
    <Box columnGap={1}>
      <Text>Enhancing the draft… {running.seconds} s</Text>
      {running.progress !== null && (
        <Box flexShrink={1}>
          <Text dimColor wrap="truncate-end">
            {running.progress}
          </Text>
        </Box>
      )}
      <Button key="cancel" label="Cancel" onPress={() => cancel($)} />
    </Box>
  )
}

function dismissButton({ Button }: Ui, $: EngineInterface, site: Site) {
  return <Button key={`${site}-dismiss`} label="Dismiss" role="dismiss" onPress={() => clear($, () => 'dropped')} />
}

function retryButton({ Button }: Ui, $: EngineInterface, site: Site) {
  return <Button key={`${site}-retry`} label="Retry" variant="primary" onPress={() => retry($)} />
}

function statusOf(ready: Ready): string {
  if (ready.record.outcome.prompt.trim() === ready.record.draft.trim()) {
    return 'Draft already clear, nothing changed'
  }

  return ready.isFilled ? 'Enhanced prompt is in the box' : 'Enhanced prompt is ready'
}

function readyActions({ Button, Text }: Ui, $: EngineInterface, ready: Ready, site: Site) {
  return [
    <Text color="success">✓</Text>,
    <Text>{statusOf(ready)}</Text>,
    !ready.isFilled && <Button key={`${site}-use`} label="Use prompt" variant="primary" onPress={() => usePrompt($)} />,
    <Button
      key={`${site}-copy`}
      label="Copy prompt"
      variant={ready.isFilled ? 'primary' : 'secondary'}
      onPress={press => copyPrompt($, ready.record.outcome.prompt, press.surface)}
    />,
    ready.isFilled && <Button key={`${site}-restore`} label="Restore draft" onPress={() => restoreDraft($)} />,
    <Button key={`${site}-send`} label="Send" onPress={() => send($)} />,
    <Button key={`${site}-revise`} label="Revise" onPress={() => revise($)} />,
  ]
}

function readyRow(ui: Ui, $: EngineInterface, ready: Ready) {
  const { Box, Button, Text } = ui
  const { notes } = ready.record.outcome
  const lines = [
    ['Goal', bulletOf(notes, 'Understood goal')],
    ['Effort', bulletOf(notes, 'Effort')],
  ] as const

  return (
    <Box flexDirection="column">
      <Box flexWrap="wrap" columnGap={1}>
        {readyActions(ui, $, ready, 'band')}
        <Button key="notes" label="Notes" onPress={() => openNotes($)} />
        {dismissButton(ui, $, 'band')}
      </Box>
      {lines.map(
        ([label, text]) =>
          text !== null && (
            <Text dimColor wrap="truncate-end">
              {label}: {text}
            </Text>
          ),
      )}
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
          {failed.isDraftBack && '. The draft is back in the box'}
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

function idleRow({ Box, Button, Text }: Ui, $: EngineInterface, isDraftBack: boolean) {
  return (
    <Box>
      <Box display="none">
        <Button key="enhance" label="Enhance" action={BIND_ACTION} onPress={() => enhanceBox($)} />
      </Box>
      {isDraftBack && <Text dimColor>Cancelled. The draft is back in the box</Text>}
    </Box>
  )
}

function firstLine(text: string): string {
  return text.trim().split('\n', 1)[0] ?? ''
}

function runsPane({ Box, Button, Text }: Ui, $: EngineInterface, draft: string | null, runs: readonly RunSummary[]) {
  return (
    <Box flexDirection="column">
      {draft !== null && (
        <Box columnGap={1}>
          <Box flexShrink={1}>
            <Text wrap="truncate-end">This session's last draft: {firstLine(draft)}</Text>
          </Box>
          <Button key="put-back" label="Put draft in box" variant="primary" onPress={() => putBack($, draft)} />
        </Box>
      )}
      {runs.length === 0 && <Text dimColor>No enhance run has left a record yet.</Text>}
      {runs.map((past, at) => (
        <Box columnGap={1}>
          <Box flexShrink={1}>
            <Text wrap="truncate-end">
              {past.startedAt.slice(0, 16).replace('T', ' ')} {past.outcome}: {firstLine(past.draft)}
            </Text>
          </Box>
          {past.prompt !== null && (
            <Button key={`copy-${at}`} label="Copy prompt" onPress={press => copyPrompt($, past.prompt ?? '', press.surface)} />
          )}
        </Box>
      ))}
    </Box>
  )
}

function withBoldLabels(notes: string): string {
  return notes.replace(BULLET_LABEL, '$1**$2:**')
}

function readyPane(ui: Ui, $: EngineInterface, ready: Ready) {
  const { Box, Markdown, Text } = ui
  const { prompt } = ready.record.outcome
  const notes = shownNotes(ready.record)

  return (
    <Box flexDirection="column" rowGap={1}>
      <Box flexWrap="wrap" columnGap={1}>
        {readyActions(ui, $, ready, 'pane')}
        {dismissButton(ui, $, 'pane')}
      </Box>
      <Box flexDirection="column">
        <Text weight="bold">Notes</Text>
        {notes === '' ? <Text dimColor>The copy sent no notes with this prompt.</Text> : <Markdown text={withBoldLabels(notes)} />}
      </Box>
      <Box flexDirection="column" borderStyle="round" borderColor="suggestion" paddingX={1}>
        <Text weight="bold" color="suggestion">
          Enhanced prompt
        </Text>
        <Text wrap="wrap">{prompt}</Text>
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
          <Text weight="bold">Details</Text>
          <Text wrap="wrap">{failed.notes}</Text>
        </Box>
      )}
    </Box>
  )
}

export const register: Register = (on, options) => {
  writer = writerOf(options)
  trackEffort(on)

  on('session.start', async ($, e, next) => {
    await cleanUpLeftover($)
    await pruneRecords($).catch((error: unknown) => $.ui.toast(reasonOf(error)))
    await $.command.register({
      name: 'enhance',
      description: 'Enhance a draft with /enhance-prompt and put the result in the prompt box',
      argumentHint: '<draft>',
      immediate: true,
    })
    await $.command.register({ name: 'enhance-runs', description: 'List the recent /enhance runs in a pane', immediate: true })

    return next(e)
  })

  on('command.run', { command: 'enhance-runs' }, async $ => {
    await openRuns($)

    return {}
  })

  on('command.run', { command: 'enhance' }, async ($, e) => {
    const draft = e.args.trim()
    if (draft === '') {
      $.ui.toast(NO_DRAFT)
      return {}
    }

    enhance($, draft, '')

    return {}
  })

  on('prompt.edit', async ($, e, next) => {
    await markTouched($)

    return next(e)
  })

  on('prompt.change', async ($, e, next) => {
    const isOtherPlugin = e.origin.kind === 'plugin' && e.origin.name !== 'enhance'
    if (isOtherPlugin || e.origin.kind === 'history' || e.origin.kind === 'undo' || e.origin.kind === 'app' || e.origin.kind === 'engine') {
      await markTouched($)
    }

    return next(e)
  })

  on('session.end', async ($, e, next) => {
    const me = await cancelActive()
    await Promise.race([wrapUp($, me), $.clock.sleep(SESSION_END_WAIT_MS)])

    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    const entered = await next(e)
    if (e.origin.kind === 'composer' || e.origin.kind === 'bridge') {
      if (e.command === undefined && !('drop' in entered)) {
        await clear($, record => sentOf(record, e.text))
      }
      await markTouched($)
    }

    return entered
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

  on('ui.render', { component: 'Pane', requestId: RUNS_PANE }, async ($, e) =>
    runsPane($.ui.resolve(e), $, await read($, lastDraft), await read($, recent)),
  )

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) {
      return next(e)
    }

    const ui = $.ui.resolve(e)
    const current = await read($, run)
    if (current.kind === 'running') {
      return runningRow(ui, $, current)
    }
    if (current.kind === 'ready') {
      return readyRow(ui, $, current)
    }
    if (current.kind === 'failed') {
      return failedRow(ui, $, current)
    }

    return idleRow(ui, $, current.isDraftBack)
  })
}
