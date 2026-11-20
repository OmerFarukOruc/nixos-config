import type { EngineInterface, ProcessRunInit, ProcessRunResult } from 'claude-code'

import { HEADLESS_START, headlessResultOf, isSessionId, readHeadless } from './reply'

export type Turn = { kind: 'reply'; text: string } | { kind: 'failed'; reason: string; notes: string } | { kind: 'cancelled' }

export type Cancel = { isCancelled: boolean }

export type Copy = {
  send: (text: string) => Promise<Turn>
  stop: () => Promise<void>
  close: () => Promise<void>
}

type CopyPlan = {
  sessionId: string
  parentId: string | null
  cancel: Cancel
}

const COPY_MODEL = 'claude-sonnet-5-5'
const DENIED_TOOLS = 'Edit,Write,NotebookEdit,AskUserQuestion'
const COPY_PERMISSION_MODE = 'bypassPermissions'
const COPY_SETTINGS = '{"disableAllHooks":true,"permissions":{"denyInsteadOfPrompting":true},"env":{"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS":"1"}}'
const SCRATCH_ROOT = '/tmp/agents'
const TOOL_CWD = '/'
const TURN_TIMEOUT_MS = 570_000
const STDERR_TAIL_CHARS = 300
const IMAGE_MARK = /\[Image #(\d+)\]/g
const IMAGE_FILE = /\/(\d+)\.(?:png|jpe?g|gif|webp)$/
const UID = /^\d+$/

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

async function projectsDir($: EngineInterface): Promise<string> {
  return `${(await $.env.get('CLAUDE_CONFIG_DIR')) ?? `${(await $.env.get('HOME')) ?? ''}/.claude`}/projects`
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

async function forgetSessionFiles($: EngineInterface, sessionId: string): Promise<void> {
  const projects = await projectsDir($)
  const removed = await runTool($, [
    'find',
    '-H',
    projects,
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
    '-exec',
    'rm',
    '-rf',
    '{}',
    '+',
  ])
  if (removed.exitCode !== 0) {
    throw new Error(`could not remove the copy's session files under ${projects}: ${removed.stderr.trim().slice(0, 200)}`)
  }
}

export async function forgetCopy($: EngineInterface, sessionId: string): Promise<void> {
  if (!isSessionId(sessionId)) {
    return
  }
  const [files, draft] = await Promise.allSettled([forgetSessionFiles($, sessionId), forgetDraft($, sessionId)])
  const failed = [files, draft].flatMap(step => (step.status === 'rejected' ? [step.reason instanceof Error ? step.reason.message : String(step.reason)] : []))
  if (failed.length > 0) {
    throw new Error(failed.join('; '))
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
      const argv = ['claude', '-p', '--output-format', 'stream-json', '--verbose', ...copyFlags(plan, isFirstTurn), '--', text]
      isFirstTurn = false
      const running = $.process.spawn({ argv })
      child = running
      const deadline = new AbortController()
      let isLate = false
      void $.clock
        .sleep(TURN_TIMEOUT_MS, { signal: deadline.signal })
        .then(() => {
          isLate = true
          return running.return({ code: null, signal: 'SIGTERM' })
        })
        .catch(() => undefined)

      let reader = HEADLESS_START
      let stderrTail = ''
      try {
        for await (const piece of running) {
          if (piece.stream === 'stdout') {
            reader = readHeadless(reader, piece.text)
          } else {
            stderrTail = (stderrTail + piece.text).slice(-STDERR_TAIL_CHARS)
          }
        }
      } finally {
        deadline.abort()
        child = null
      }
      if (plan.cancel.isCancelled) {
        return { kind: 'cancelled' }
      }

      const parsed = headlessResultOf(reader)
      if (parsed.kind === 'answered') {
        return { kind: 'reply', text: parsed.text }
      }
      if (isLate) {
        return { kind: 'failed', reason: `the copy's turn did not end in ${TURN_TIMEOUT_MS / 1000} s`, notes: stderrTail.trim() }
      }
      const ended = await running.result
      const why = ended.code === 0 ? parsed.reason : `${parsed.reason} (exit ${ended.code ?? ended.signal}: ${stderrTail.trim()})`

      return { kind: 'failed', reason: why, notes: '' }
    },
    stop: async () => {
      await child?.return({ code: null, signal: 'SIGTERM' })
      await forgetCopy($, plan.sessionId)
    },
    close: () => forgetCopy($, plan.sessionId),
  }
}
