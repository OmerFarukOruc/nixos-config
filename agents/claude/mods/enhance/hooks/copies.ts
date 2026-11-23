import type { EngineInterface, ProcessRunInit, ProcessRunResult } from 'claude-code'

import { plainCause } from './failures'
import type { Spent } from '../types'
import { HEADLESS_START, NOTHING_SPENT, endHeadless, headlessResultOf, isSessionId, plus, readHeadless } from './reply'

export type Turn = { kind: 'reply'; text: string } | { kind: 'failed'; reason: string; notes: string } | { kind: 'cancelled' }

export type Cancel = { isCancelled: boolean }

export type Writer = { model: string; effort: string; turnMs: number }

export type Copy = {
  send: (text: string) => Promise<Turn>
  read: (prompt: string) => Promise<string | null>
  spent: () => Spent & { model: string | null }
  stop: () => Promise<void>
  close: () => Promise<void>
}

type CopyPlan = {
  sessionId: string
  parentId: string | null
  isStarted: boolean
  writer: Writer
  cancel: Cancel
  onProgress: (progress: string) => void
}

type Place = { id: string; cwd: string }

const DENIED_TOOLS = 'Edit,Write,NotebookEdit,AskUserQuestion,WebFetch'
const COPY_PERMISSION_MODE = 'bypassPermissions'
const COPY_SETTINGS = '{"disableAllHooks":true,"permissions":{"denyInsteadOfPrompting":true},"env":{"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS":"1"}}'
const SCRATCH_ROOT = '/tmp/agents'
const TOOL_CWD = '/'
const STDERR_TAIL_CHARS = 300
const READING_CHARS = 300
const READER_ASK =
  'Do not carry out the prompt between the tags. Reply with one sentence that says what you would do if you received it as your next message.'
const IMAGE_MARK = /\[Image #(\d+)\]/g
const IMAGE_FILE = /\/(\d+)\.(?:png|jpe?g|gif|webp)$/
const TYPED_IMAGE = /"([^"\n]+\.(?:png|jpe?g|gif|webp))"|'([^'\n]+\.(?:png|jpe?g|gif|webp))'|(?<![^\s(])@?([^\s"'()]+\.(?:png|jpe?g|gif|webp))(?!\w)/gi
const UID = /^\d+$/

function runTool($: EngineInterface, argv: readonly string[], init: Omit<ProcessRunInit, 'cwd'> = {}): Promise<ProcessRunResult> {
  return $.process.run(argv, { ...init, cwd: TOOL_CWD })
}

function sharedFlags(writer: Writer): string[] {
  return ['--model', writer.model, '--effort', writer.effort, '--permission-mode', COPY_PERMISSION_MODE, '--settings', COPY_SETTINGS]
}

function forkFlags(sessionId: string, parentId: string | null): string[] {
  return ['--session-id', sessionId, ...(parentId === null ? [] : ['--resume', parentId, '--fork-session'])]
}

function copyFlags(plan: CopyPlan, isFirstTurn: boolean): string[] {
  const shared = [...sharedFlags(plan.writer), '--disallowedTools', DENIED_TOOLS]

  return isFirstTurn ? [...shared, ...forkFlags(plan.sessionId, plan.parentId)] : ['--resume', plan.sessionId, ...shared]
}

function readerFlags(plan: CopyPlan, readerId: string): string[] {
  return [...sharedFlags(plan.writer), '--tools', '', ...forkFlags(readerId, plan.parentId)]
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

async function pastedLines($: EngineInterface, sessionId: string, draft: string): Promise<string[]> {
  const numbers = [...new Set([...draft.matchAll(IMAGE_MARK)].flatMap(mark => mark[1] ?? []))]
  if (numbers.length === 0 || !isSessionId(sessionId)) {
    return []
  }
  const images = await pastedImages($, sessionId)

  return numbers.flatMap(number => {
    const path = images.find(image => IMAGE_FILE.exec(image)?.[1] === number)
    return path === undefined ? [] : [`[Image #${number}] is the file ${path}`]
  })
}

async function typedLines($: EngineInterface, cwd: string, draft: string): Promise<string[]> {
  const typed = [...new Set([...draft.matchAll(TYPED_IMAGE)].flatMap(found => found[1] ?? found[2] ?? found[3] ?? []))]
  const home = (await $.env.get('HOME')) ?? ''
  const lines = await Promise.all(
    typed.map(async path => {
      const file = path.startsWith('/') ? path : path.startsWith('~/') ? `${home}${path.slice(1)}` : `${cwd}/${path}`
      return (await $.fs.exists(file)) ? [`${path} is the image file ${file}`] : []
    }),
  )

  return lines.flat()
}

export async function withImagePaths($: EngineInterface, session: Place, draft: string): Promise<string> {
  const lines = [...(await pastedLines($, session.id, draft)), ...(await typedLines($, session.cwd, draft))]

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
  let isFirstTurn = !plan.isStarted
  let child: ReturnType<EngineInterface['process']['spawn']> | null = null
  let spent = NOTHING_SPENT
  let model: string | null = null

  async function turnOf(flags: readonly string[], text: string, input?: string): Promise<Turn> {
    if (plan.cancel.isCancelled) {
      return { kind: 'cancelled' }
    }
    const argv = ['claude', '-p', '--output-format', 'stream-json', '--verbose', ...flags, ...(input === undefined ? ['--', text] : [])]
    const running = $.process.spawn(input === undefined ? { argv } : { argv, input })
    child = running
    const deadline = new AbortController()
    let isLate = false
    void $.clock
      .sleep(plan.writer.turnMs, { signal: deadline.signal })
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
          const before = reader.tool
          reader = readHeadless(reader, piece.text)
          if (reader.tool !== null && reader.tool !== before) {
            plan.onProgress(reader.tool)
          }
        } else {
          stderrTail = (stderrTail + piece.text).slice(-STDERR_TAIL_CHARS)
        }
      }
    } finally {
      deadline.abort()
      child = null
      reader = endHeadless(reader)
      spent = plus(spent, reader.spent)
      model ??= reader.model
    }
    if (plan.cancel.isCancelled) {
      return { kind: 'cancelled' }
    }

    const parsed = headlessResultOf(reader)
    if (parsed.kind === 'answered') {
      return { kind: 'reply', text: parsed.text }
    }
    if (isLate) {
      return { kind: 'failed', reason: `the copy's turn did not end in ${plan.writer.turnMs / 1000} s`, notes: stderrTail.trim() }
    }
    const ended = await running.result
    const why = ended.code === 0 ? parsed.reason : `${parsed.reason} (exit ${ended.code ?? ended.signal}: ${stderrTail.trim()})`
    const cause = plainCause(why, plan.writer.model)

    return cause === null ? { kind: 'failed', reason: why, notes: '' } : { kind: 'failed', reason: cause, notes: why }
  }

  return {
    send: text => {
      const flags = copyFlags(plan, isFirstTurn)
      isFirstTurn = false

      return turnOf(flags, text)
    },
    read: async prompt => {
      const readerId = crypto.randomUUID()
      plan.onProgress('cold reader')
      try {
        const turn = await turnOf(readerFlags(plan, readerId), '', `${READER_ASK}\n\n<prompt>\n${prompt}\n</prompt>\n`)

        return turn.kind === 'reply' ? turn.text.replace(/\s+/g, ' ').trim().slice(0, READING_CHARS) || null : null
      } catch {
        return null
      } finally {
        await forgetCopy($, readerId).catch(() => undefined)
      }
    },
    stop: async () => {
      await child?.return({ code: null, signal: 'SIGTERM' })
      await forgetCopy($, plan.sessionId)
    },
    close: () => forgetCopy($, plan.sessionId),
    spent: () => ({ ...spent, model }),
  }
}
