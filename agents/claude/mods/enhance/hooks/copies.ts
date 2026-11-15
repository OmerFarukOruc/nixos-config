import type { EngineInterface } from 'claude-code'

import type { Seat } from '../types'
import { isSessionId, lastAssistantText, parseHeadless, textAt, valueAt } from './reply'

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
  onSeat: (seat: Seat) => Promise<void>
}

export type Place = 'beside-session' | 'new-workspace'

const COPY_MODEL = 'claude-sonnet-5-5'
const DENIED_TOOLS = 'Edit,Write,NotebookEdit,AskUserQuestion'
const NO_HOOKS = '{"disableAllHooks":true}'
const SCRATCH_ROOT = '/tmp/agents'
const AGENT_START_TIMEOUT_MS = 120_000
const PROMPT_TIMEOUT_MS = 570_000
const SHELL_READY_TIMEOUT_MS = 180_000
const SHELL_READY_PROBE_MS = 3000
const PROBE_ID_RANGE = 1_000_000_000
const START_TRIES = 30
const PROMPT_TRIES = 60
const NOT_READY = new Set(['agent_not_ready', 'agent_blocked'])
const GONE = new Set(['pane_not_found', 'workspace_not_found'])
const TRANSCRIPT_ROWS = '400'

type Herdr = { ok: true; result: unknown } | { ok: false; code: string }

class CopyCancelled extends Error {}

function copyFlags(plan: CopyPlan, isFirstTurn: boolean): string[] {
  const shared = ['--model', COPY_MODEL, '--disallowedTools', DENIED_TOOLS, '--settings', NO_HOOKS, '--add-dir', SCRATCH_ROOT]
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
  const found = await $.process.run([
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

export async function forgetCopy($: EngineInterface, sessionId: string): Promise<void> {
  if (isSessionId(sessionId)) {
    await findInProjects($, sessionId, ['-exec', 'rm', '-rf', '{}', '+'])
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
  const ran = await $.process.run(['herdr', ...args], { timeoutMs })
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
    const status = await $.process.run(['herdr', 'status', 'server'])
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
  while ((await $.clock.now()) < deadline) {
    checkCancel(cancel)
    await typeInPane($, pane, probe, 'check that the shell is ready')
    const seen = await herdr($, ['pane', 'wait-output', pane, '--match', answer, '--timeout', String(SHELL_READY_PROBE_MS)])
    if (seen.ok) {
      return
    }
    if (seen.code !== 'timeout') {
      throw new Error(`herdr could not read pane ${pane}: ${seen.code}`)
    }
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
      throw new Error(`the copy is blocked at startup; its screen ended: ${(await screenOf($, name)).slice(-400)}`)
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
  const read = await $.process.run(['herdr', 'agent', 'read', name, '--source', 'visible', '--lines', '40'])

  return read.exitCode === 0 ? read.stdout.trim() : ''
}

async function transcriptPath($: EngineInterface, sessionId: string): Promise<string | null> {
  const found = await findInProjects($, sessionId, ['-type', 'f'])
  const path = found.split('\n')[0]?.trim() ?? ''

  return path === '' ? null : path
}

async function transcriptRows($: EngineInterface, path: string | null): Promise<number> {
  if (path === null) {
    return 0
  }
  const counted = await $.process.run(['wc', '-l', path])

  return Number.parseInt(counted.stdout.trim(), 10) || 0
}

async function replyAfter($: EngineInterface, sessionId: string, rowsBefore: number): Promise<Turn> {
  const path = await transcriptPath($, sessionId)
  if (path === null) {
    return { kind: 'failed', reason: 'the copy left no transcript', notes: '' }
  }

  const tail = await $.process.run(['sh', '-c', 'tail -n "+$1" "$2" | tail -n "$3"', 'sh', String(rowsBefore + 1), path, TRANSCRIPT_ROWS])
  if (tail.isStdoutTruncated) {
    return { kind: 'failed', reason: 'the copy transcript tail is over 4 MiB', notes: '' }
  }
  const text = lastAssistantText(tail.stdout)

  return text === null ? { kind: 'failed', reason: 'the copy wrote no reply to this turn', notes: '' } : { kind: 'reply', text }
}

export function herdrCopy($: EngineInterface, plan: CopyPlan, place: Place): Copy {
  const name = `enhance-${plan.sessionId.slice(0, 8)}`
  let seat: Seat | null = null

  const send = async (text: string): Promise<Turn> => {
    if (seat === null) {
      checkCancel(plan.cancel)
      seat = await openSeat($, place, plan.cwd)
      await plan.onSeat(seat)
      await startAgent($, name, seat.pane, plan)
    }

    const rowsBefore = await transcriptRows($, await transcriptPath($, plan.sessionId))
    const prompted = await promptAgent($, name, text, plan.cancel)
    checkCancel(plan.cancel)
    if (!prompted.ok) {
      return { kind: 'failed', reason: `herdr could not prompt the copy: ${prompted.code}`, notes: await screenOf($, name) }
    }
    if (textAt(prompted.result, ['agent', 'agent_status']) === 'blocked') {
      return { kind: 'failed', reason: 'the copy stopped at a question or approval; Reply shows its screen', notes: await screenOf($, name) }
    }

    return replyAfter($, plan.sessionId, rowsBefore)
  }

  return {
    send: async text => {
      try {
        return await send(text)
      } catch (error) {
        if (error instanceof CopyCancelled || plan.cancel.isCancelled) {
          return { kind: 'cancelled' }
        }
        throw error
      }
    },
    stop: async () => {
      if (seat !== null && (await closeSeat($, seat))) {
        await forgetCopy($, plan.sessionId)
      }
    },
    close: async () => {
      if (seat !== null && !(await closeSeat($, seat))) {
        throw new Error(`herdr could not close the copy's ${seat.kind} ${seat.id}; close it yourself`)
      }
      await forgetCopy($, plan.sessionId)
    },
  }
}
