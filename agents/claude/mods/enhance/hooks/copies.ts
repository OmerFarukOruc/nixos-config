import type { EngineInterface, ProcessRunInit, ProcessRunResult } from 'claude-code'

import type { Seat } from '../types'
import { foldBytes, isSessionId, parseHeadless, readerAt, slashCommandOf, textAt, valueAt } from './reply'
import type { SlashCommand, TranscriptReader } from './reply'

export type Turn = { kind: 'reply'; text: string } | { kind: 'failed'; reason: string; notes: string } | { kind: 'cancelled' }

export type Cancel = { isCancelled: boolean }

export type Copy = {
  send: (text: string) => Promise<Turn>
  stop: () => Promise<void>
  close: () => Promise<void>
}

export type CopyPlan = {
  sessionId: string
  parentId: string | null
  cwd: string
  cancel: Cancel
  onSeat: (seat: Seat | null) => Promise<void>
}

export type Place = 'beside-session' | 'new-workspace'

const COPY_MODEL = 'claude-sonnet-5-5'
const DENIED_TOOLS = 'Edit,Write,NotebookEdit,AskUserQuestion'
const COPY_PERMISSION_MODE = 'bypassPermissions'
const COPY_SETTINGS = '{"disableAllHooks":true,"permissions":{"denyInsteadOfPrompting":true},"env":{"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS":"1"}}'
const SCRATCH_ROOT = '/tmp/agents'
const TOOL_CWD = '/'
const AGENT_START_TIMEOUT_MS = 120_000
const PROMPT_TIMEOUT_MS = 570_000
const SHELL_READY_TIMEOUT_MS = 180_000
const PROBE_FIRST_WAIT_MS = 3000
const PROBE_LONGEST_WAIT_MS = 30_000
const PROBE_ID_RANGE = 1_000_000_000
const START_TRIES = 30
const PROMPT_TRIES = 60
const NOT_READY = new Set(['agent_not_ready', 'agent_blocked'])
const GONE = new Set(['pane_not_found', 'workspace_not_found'])
const TRANSCRIPT_RANGE_BYTES = 2 * 1024 * 1024
const TRANSCRIPT_RETRY_MS = 1000
const CANCEL_POLL_MS = 500
const TRUST_DIALOG_MARKERS = ['Yes, I trust this folder', 'No, exit']
const IMAGE_MARK = /\[Image #(\d+)\]/g
const IMAGE_FILE = /\/(\d+)\.(?:png|jpe?g|gif|webp)$/
const UID = /^\d+$/

type Herdr = { ok: true; result: unknown } | { ok: false; code: string }

class CopyCancelled extends Error {}

class FolderNotTrusted extends Error {}

function runTool($: EngineInterface, argv: readonly string[], init: Omit<ProcessRunInit, 'cwd'> = {}): Promise<ProcessRunResult> {
  return $.process.run(argv, { ...init, cwd: TOOL_CWD })
}

function copyFlags(plan: CopyPlan, isFirstTurn: boolean): string[] {
  const shared = [
    '--model',
    COPY_MODEL,
    '--permission-mode',
    COPY_PERMISSION_MODE,
    '--disallowedTools',
    DENIED_TOOLS,
    '--settings',
    COPY_SETTINGS,
  ]
  if (!isFirstTurn) {
    return ['--resume', plan.sessionId, ...shared]
  }

  const fork = plan.parentId === null ? [] : ['--resume', plan.parentId, '--fork-session']

  return [...shared, '--session-id', plan.sessionId, ...fork]
}

async function configDir($: EngineInterface): Promise<string | null> {
  return (await $.env.get('CLAUDE_CONFIG_DIR')) ?? null
}

async function projectsDir($: EngineInterface): Promise<string> {
  return `${(await configDir($)) ?? `${(await $.env.get('HOME')) ?? ''}/.claude`}/projects`
}

async function findInProjects($: EngineInterface, sessionId: string, action: readonly string[]): Promise<string> {
  const found = await runTool($, [
    'find',
    '-H',
    await projectsDir($),
    '-mindepth',
    '2',
    '-maxdepth',
    '2',
    '(',
    '-name',
    `${sessionId}.jsonl`,
    '-o',
    '-name',
    sessionId,
    ')',
    ...action,
  ])

  return found.stdout
}

function draftDirOf(sessionId: string): string {
  return `${SCRATCH_ROOT}/enhance-copy-${sessionId}`
}

async function forgetDraft($: EngineInterface, sessionId: string): Promise<void> {
  const dir = draftDirOf(sessionId)
  const removed = await runTool($, ['rm', '-rf', '--', dir])
  if (removed.exitCode !== 0) {
    throw new Error(`could not remove the draft folder ${dir}: ${removed.stderr.trim().slice(0, 200)}`)
  }
}

async function pastedImages($: EngineInterface, sessionId: string): Promise<string[]> {
  try {
    const uid = (await runTool($, ['id', '-u'])).stdout.trim()
    if (!UID.test(uid)) {
      return []
    }
    const found = await runTool($, ['find', `/tmp/claude-${uid}`, '-mindepth', '4', '-maxdepth', '4', '-type', 'f', '-path', `*/${sessionId}/images/*`])

    return found.stdout.split('\n').filter(path => path !== '')
  } catch {
    return []
  }
}

export async function withImagePaths($: EngineInterface, sessionId: string, draft: string): Promise<string> {
  const numbers = [...new Set([...draft.matchAll(IMAGE_MARK)].flatMap(mark => mark[1] ?? []))]
  if (numbers.length === 0 || !isSessionId(sessionId)) {
    return draft
  }
  const images = await pastedImages($, sessionId)
  const lines = numbers.flatMap(number => {
    const path = images.find(image => IMAGE_FILE.exec(image)?.[1] === number)
    return path === undefined ? [] : [`[Image #${number}] is the file ${path}`]
  })

  return lines.length === 0 ? draft : `${draft}\n\n${lines.join('\n')}`
}

export async function withDraftFile<T>($: EngineInterface, sessionId: string, draft: string, use: (path: string) => Promise<T>): Promise<T> {
  const path = `${draftDirOf(sessionId)}/draft.md`
  try {
    await $.fs.write(path, draft)
    return await use(path)
  } finally {
    await forgetDraft($, sessionId)
  }
}

export async function forgetCopy($: EngineInterface, sessionId: string): Promise<void> {
  if (isSessionId(sessionId)) {
    await findInProjects($, sessionId, ['-exec', 'rm', '-rf', '{}', '+'])
    await forgetDraft($, sessionId)
  }
}

function checkCancel(cancel: Cancel): void {
  if (cancel.isCancelled) {
    throw new CopyCancelled()
  }
}

export function headlessCopy($: EngineInterface, plan: CopyPlan): Copy {
  let isFirstTurn = true
  let child: ReturnType<EngineInterface['process']['spawn']> | null = null

  return {
    send: async text => {
      if (plan.cancel.isCancelled) {
        return { kind: 'cancelled' }
      }
      const argv = ['claude', '-p', '--output-format', 'json', ...copyFlags(plan, isFirstTurn), '--', text]
      isFirstTurn = false
      const running = $.process.spawn({ argv })
      child = running

      let stdout = ''
      let stderr = ''
      for await (const piece of running) {
        if (piece.stream === 'stdout') {
          stdout += piece.text
        } else {
          stderr += piece.text
        }
      }
      child = null
      if (plan.cancel.isCancelled) {
        return { kind: 'cancelled' }
      }

      const ended = await running.result
      const parsed = parseHeadless(stdout)
      if (parsed.kind === 'failed') {
        const why = ended.code === 0 ? parsed.reason : `${parsed.reason} (exit ${ended.code ?? ended.signal}: ${stderr.trim().slice(-300)})`
        return { kind: 'failed', reason: why, notes: '' }
      }

      return { kind: 'reply', text: parsed.text }
    },
    stop: async () => {
      await child?.return({ code: null, signal: 'SIGTERM' })
      await forgetCopy($, plan.sessionId)
    },
    close: () => forgetCopy($, plan.sessionId),
  }
}

async function herdr($: EngineInterface, args: readonly string[], timeoutMs = 60_000): Promise<Herdr> {
  const ran = await runTool($, ['herdr', ...args], { timeoutMs })
  const output = ran.exitCode === 0 ? ran.stdout : ran.stderr
  if (ran.exitCode === 0 && output.trim() === '') {
    return { ok: true, result: null }
  }
  try {
    const parsed: unknown = JSON.parse(output)
    if (ran.exitCode === 0) {
      return { ok: true, result: valueAt(parsed, ['result']) }
    }
    return { ok: false, code: textAt(parsed, ['error', 'code']) ?? `exit ${ran.exitCode}` }
  } catch {
    return { ok: false, code: `exit ${ran.exitCode}: ${output.trim().slice(0, 200)}` }
  }
}

export async function isHerdrRunning($: EngineInterface): Promise<boolean> {
  try {
    const status = await runTool($, ['herdr', 'status', 'server'])
    return status.exitCode === 0 && /^status: running$/m.test(status.stdout)
  } catch {
    return false
  }
}

async function openSeat($: EngineInterface, place: Place, cwd: string): Promise<Seat> {
  if (place === 'beside-session') {
    const split = await herdr($, ['pane', 'split', '--current', '--direction', 'down', '--cwd', cwd, '--no-focus'])
    const pane = split.ok ? textAt(split.result, ['pane', 'pane_id']) : null
    if (pane === null) {
      throw new Error(`herdr could not split a pane: ${split.ok ? 'no pane id' : split.code}`)
    }
    return { kind: 'pane', id: pane, pane }
  }

  const created = await herdr($, ['workspace', 'create', '--cwd', cwd, '--label', 'enhance', '--no-focus'])
  const workspace = created.ok ? textAt(created.result, ['workspace', 'workspace_id']) : null
  const pane = created.ok ? textAt(created.result, ['root_pane', 'pane_id']) : null
  if (workspace === null || pane === null) {
    throw new Error(`herdr could not create a workspace: ${created.ok ? 'no workspace or pane id' : created.code}`)
  }

  return { kind: 'workspace', id: workspace, pane }
}

export async function closeSeat($: EngineInterface, seat: Seat): Promise<boolean> {
  const closed = await herdr($, [seat.kind, 'close', seat.id])

  return closed.ok || GONE.has(closed.code)
}

function shellQuote(text: string): string {
  return `'${text.replaceAll("'", `'\\''`)}'`
}

async function typeInPane($: EngineInterface, pane: string, command: string, purpose: string): Promise<void> {
  const typed = await herdr($, ['pane', 'run', pane, command])
  if (!typed.ok) {
    throw new Error(`herdr could not ${purpose} in pane ${pane}: ${typed.code}`)
  }
}

async function waitShellReady($: EngineInterface, pane: string, cancel: Cancel): Promise<void> {
  const seed = Math.floor(Math.random() * PROBE_ID_RANGE)
  const answer = `shell-ready-${seed + 1}`
  const probe = `echo shell-ready-$((${seed}+1))`
  const deadline = (await $.clock.now()) + SHELL_READY_TIMEOUT_MS
  let waitMs = PROBE_FIRST_WAIT_MS
  for (let leftMs = SHELL_READY_TIMEOUT_MS; leftMs > 0; leftMs = deadline - (await $.clock.now())) {
    checkCancel(cancel)
    await typeInPane($, pane, probe, 'check that the shell is ready')
    const seen = await herdr($, ['pane', 'wait-output', pane, '--match', answer, '--timeout', String(Math.min(waitMs, leftMs))])
    if (seen.ok) {
      return
    }
    if (seen.code !== 'timeout') {
      throw new Error(`herdr could not read pane ${pane}: ${seen.code}`)
    }
    waitMs = Math.min(waitMs * 2, PROBE_LONGEST_WAIT_MS)
  }
  throw new Error(`the shell in pane ${pane} ran no typed command in ${SHELL_READY_TIMEOUT_MS / 1000} s`)
}

async function startAgent($: EngineInterface, name: string, pane: string, plan: CopyPlan): Promise<void> {
  checkCancel(plan.cancel)
  await waitShellReady($, pane, plan.cancel)
  const account = await configDir($)
  const env = `export CLAUDE_TOOLS_PLAIN=1; ${account === null ? 'unset CLAUDE_CONFIG_DIR' : `export CLAUDE_CONFIG_DIR=${shellQuote(account)}`}`
  await typeInPane($, pane, env, "set the copy's account")

  for (let attempt = 1; ; attempt += 1) {
    checkCancel(plan.cancel)
    const started = await herdr(
      $,
      ['agent', 'start', name, '--kind', 'claude', '--pane', pane, '--timeout', String(AGENT_START_TIMEOUT_MS), '--', ...copyFlags(plan, true)],
      AGENT_START_TIMEOUT_MS + 30_000,
    )
    if (started.ok) {
      return
    }
    checkCancel(plan.cancel)
    if (started.code === 'agent_not_ready') {
      const screen = await screenOf($, name)
      if (TRUST_DIALOG_MARKERS.every(marker => screen.includes(marker))) {
        throw new FolderNotTrusted()
      }
      throw new Error(`the copy is blocked at startup; its screen ended: ${screen.slice(-400)}`)
    }
    if (started.code !== 'agent_pane_busy' || attempt === START_TRIES) {
      throw new Error(`herdr could not start the copy: ${started.code}`)
    }
    await $.clock.sleep(1000)
  }
}

async function promptAgent($: EngineInterface, name: string, text: string, cancel: Cancel): Promise<Herdr> {
  for (let attempt = 1; ; attempt += 1) {
    checkCancel(cancel)
    const prompted = await herdr($, ['agent', 'prompt', name, text, '--wait', '--timeout', String(PROMPT_TIMEOUT_MS)], PROMPT_TIMEOUT_MS + 30_000)
    if (prompted.ok || !NOT_READY.has(prompted.code) || attempt === PROMPT_TRIES) {
      return prompted
    }
    await $.clock.sleep(1000)
  }
}

async function screenOf($: EngineInterface, name: string): Promise<string> {
  const read = await runTool($, ['herdr', 'agent', 'read', name, '--source', 'visible', '--lines', '40'])

  return read.exitCode === 0 ? read.stdout.trim() : ''
}

async function transcriptPath($: EngineInterface, sessionId: string): Promise<string | null> {
  const found = await findInProjects($, sessionId, ['-type', 'f'])
  const path = found.split('\n')[0]?.trim() ?? ''

  return path === '' ? null : path
}

async function unlessMissing<T>($: EngineInterface, path: string, read: () => Promise<T>, whenMissing: T): Promise<T> {
  try {
    return await read()
  } catch (error) {
    if (await $.fs.exists(path)) {
      throw new Error(`could not read the copy transcript ${path}: ${error instanceof Error ? error.message : String(error)}`, { cause: error })
    }
    return whenMissing
  }
}

async function transcriptSize($: EngineInterface, path: string | null): Promise<number> {
  return path === null ? 0 : unlessMissing($, path, async () => (await $.fs.stat(path)).size, 0)
}

async function readNewRows($: EngineInterface, path: string, seen: TranscriptReader, call: SlashCommand | null, cancel: Cancel): Promise<TranscriptReader> {
  const size = await transcriptSize($, path)
  let reader = size < seen.offset ? readerAt(0) : seen
  while (reader.offset < size) {
    checkCancel(cancel)
    const { offset } = reader
    const length = Math.min(TRANSCRIPT_RANGE_BYTES, size - offset)
    const base64 = await unlessMissing($, path, async () => (await $.fs.read(path, { as: 'bytes', offset, length })).base64, '')
    const added = Uint8Array.from(atob(base64), byte => byte.charCodeAt(0))
    if (added.length < length) {
      return readerAt(0)
    }
    reader = foldBytes(reader, added, call)
  }

  return reader
}

type TurnRange = { bytesBefore: number; isHistoryInRange: boolean }

async function replyAfter($: EngineInterface, sessionId: string, range: TurnRange, call: SlashCommand | null, cancel: Cancel, deadline: number): Promise<Turn> {
  const path = await transcriptPath($, sessionId)
  if (path === null) {
    return { kind: 'failed', reason: 'the copy left no transcript', notes: '' }
  }

  let reader = readerAt(range.bytesBefore)
  for (;;) {
    checkCancel(cancel)
    reader = await readNewRows($, path, reader, call, cancel)
    const { turn } = reader
    const isCommandMissing = call !== null && !reader.sawCommand
    const isOwnTurn = !(range.isHistoryInRange && isCommandMissing)
    if (isOwnTurn && turn.isApiError) {
      return { kind: 'failed', reason: `the copy stopped at an API error: ${turn.text ?? 'no text'}`, notes: '' }
    }
    if (isOwnTurn && turn.hasEnded) {
      if (isCommandMissing) {
        return { kind: 'failed', reason: `the copy did not load ${call.name}`, notes: turn.text ?? '' }
      }
      return turn.text === null ? { kind: 'failed', reason: 'the copy wrote no reply to this turn', notes: '' } : { kind: 'reply', text: turn.text }
    }
    if ((await $.clock.now()) >= deadline) {
      return isOwnTurn
        ? { kind: 'failed', reason: `the copy's turn did not end in ${PROMPT_TIMEOUT_MS / 1000} s`, notes: turn.text ?? '' }
        : { kind: 'failed', reason: `the copy did not load ${call?.name ?? 'the prompt'} in ${PROMPT_TIMEOUT_MS / 1000} s`, notes: '' }
    }
    await $.clock.sleep(TRANSCRIPT_RETRY_MS)
  }
}

async function untilCancelled($: EngineInterface, cancel: Cancel, sent: { isOver: boolean }): Promise<Turn> {
  while (!cancel.isCancelled && !sent.isOver) {
    await $.clock.sleep(CANCEL_POLL_MS)
  }

  return { kind: 'cancelled' }
}

type HerdrCopyState = { kind: 'unstarted' } | { kind: 'seated'; seat: Seat } | { kind: 'headless'; copy: Copy }

export function herdrCopy($: EngineInterface, plan: CopyPlan, place: Place): Copy {
  const name = `enhance-${plan.sessionId.slice(0, 8)}`
  let state: HerdrCopyState = { kind: 'unstarted' }

  const closeOwnSeat = async (seat: Seat): Promise<void> => {
    if (!(await closeSeat($, seat))) {
      throw new Error(`herdr could not close the copy's ${seat.kind} ${seat.id}; close it yourself`)
    }
  }

  const start = async (): Promise<HerdrCopyState> => {
    checkCancel(plan.cancel)
    const seat = await openSeat($, place, plan.cwd)
    state = { kind: 'seated', seat }
    await plan.onSeat(seat)
    try {
      await startAgent($, name, seat.pane, plan)
      return state
    } catch (error) {
      if (!(error instanceof FolderNotTrusted)) {
        throw error
      }
      await closeOwnSeat(seat)
      state = { kind: 'headless', copy: headlessCopy($, plan) }
      await plan.onSeat(null)
      return state
    }
  }

  const send = async (text: string): Promise<Turn> => {
    const isForkStart = state.kind === 'unstarted' && plan.parentId !== null
    const current = state.kind === 'unstarted' ? await start() : state
    if (current.kind === 'headless') {
      return current.copy.send(text)
    }

    const range = { bytesBefore: await transcriptSize($, await transcriptPath($, plan.sessionId)), isHistoryInRange: isForkStart }
    const deadline = (await $.clock.now()) + PROMPT_TIMEOUT_MS
    const prompted = await promptAgent($, name, text, plan.cancel)
    checkCancel(plan.cancel)
    if (!prompted.ok) {
      return { kind: 'failed', reason: `herdr could not prompt the copy: ${prompted.code}`, notes: await screenOf($, name) }
    }
    if (textAt(prompted.result, ['agent', 'agent_status']) === 'blocked') {
      return { kind: 'failed', reason: 'the copy stopped at a question or approval; Details shows its screen', notes: await screenOf($, name) }
    }

    return replyAfter($, plan.sessionId, range, slashCommandOf(text), plan.cancel, deadline)
  }

  return {
    send: async text => {
      const sent = { isOver: false }
      const sending = send(text)
      sending.catch(() => undefined)
      try {
        return await Promise.race([sending, untilCancelled($, plan.cancel, sent)])
      } catch (error) {
        if (error instanceof CopyCancelled || plan.cancel.isCancelled) {
          return { kind: 'cancelled' }
        }
        throw error
      } finally {
        sent.isOver = true
      }
    },
    stop: async () => {
      switch (state.kind) {
        case 'unstarted':
          return
        case 'headless':
          return state.copy.stop()
        case 'seated':
          if (await closeSeat($, state.seat)) {
            await forgetCopy($, plan.sessionId)
          }
      }
    },
    close: async () => {
      if (state.kind === 'seated') {
        await closeOwnSeat(state.seat)
      }
      await forgetCopy($, plan.sessionId)
    },
  }
}
