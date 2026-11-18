export type Reply =
  | { kind: 'prompt'; prompt: string; notes: string }
  | { kind: 'question'; question: string; options: string[] }
  | { kind: 'unusable'; reason: string }

export type SlashCommand = { name: string; args: string }

export type HeadlessResult = { kind: 'answered'; text: string } | { kind: 'failed'; reason: string }

export type TurnState = { text: string | null; hasEnded: boolean; isApiError: boolean }

type Block = { tag: string; body: string; start: number; end: number | null }

const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const FENCE = /^ {0,3}(`{3,}|~{3,})[ \t]*(\S*)/
const OPTION = /^- (.+)$/
const SLASH_COMMAND = /^(\/[\w:-]+)(?:\s+([\s\S]*))?$/
const PENDING_COUNTS = ['pendingBackgroundAgentCount', 'pendingWorkflowCount'] as const

export function isSessionId(text: string): boolean {
  return SESSION_ID.test(text)
}

export function valueAt(value: unknown, path: readonly string[]): unknown {
  return path.reduce<unknown>(
    (at, key) => (typeof at === 'object' && at !== null && key in at ? (at as Record<string, unknown>)[key] : undefined),
    value,
  )
}

export function textAt(value: unknown, path: readonly string[]): string | null {
  const found = valueAt(value, path)

  return typeof found === 'string' ? found : null
}

function parseLine(line: string): unknown {
  try {
    return JSON.parse(line)
  } catch {
    return undefined
  }
}

export function parseHeadless(stdout: string): HeadlessResult {
  const line = stdout
    .split('\n')
    .reverse()
    .find(candidate => candidate.startsWith('{'))
  const parsed = line === undefined ? undefined : parseLine(line)
  if (parsed === undefined) {
    return { kind: 'failed', reason: 'claude -p printed no JSON result' }
  }

  const text = textAt(parsed, ['result'])
  if (valueAt(parsed, ['is_error']) === true || text === null) {
    return { kind: 'failed', reason: `claude -p failed: ${text ?? 'no text'}` }
  }

  return { kind: 'answered', text }
}

function blocksOfRow(row: unknown): unknown[] {
  const content = valueAt(row, ['message', 'content'])

  return Array.isArray(content) ? content : []
}

function isTurnEnd(row: unknown): boolean {
  return (
    textAt(row, ['subtype']) === 'turn_duration' &&
    PENDING_COUNTS.every(key => {
      const count = valueAt(row, [key])
      return typeof count !== 'number' || count === 0
    })
  )
}

function isToolResult(row: unknown): boolean {
  return blocksOfRow(row).some(block => textAt(block, ['type']) === 'tool_result')
}

export function turnOf(jsonl: string): TurnState {
  return jsonl.split('\n').reduce<TurnState>(
    (turn, line) => {
      const row = parseLine(line)
      const type = textAt(row, ['type'])
      if (type === 'system') {
        return isTurnEnd(row) ? { ...turn, hasEnded: true } : turn
      }
      if (type === 'user') {
        return { text: isToolResult(row) ? turn.text : null, hasEnded: false, isApiError: false }
      }
      if (type !== 'assistant') {
        return turn
      }
      const texts = blocksOfRow(row).flatMap(block => (textAt(block, ['type']) === 'text' ? [textAt(block, ['text']) ?? ''] : []))
      const isApiError = valueAt(row, ['isApiErrorMessage']) === true

      return { ...turn, text: texts.at(-1) ?? turn.text, isApiError }
    },
    { text: null, hasEnded: false, isApiError: false },
  )
}

export function slashCommandOf(prompt: string): SlashCommand | null {
  const found = SLASH_COMMAND.exec(prompt)

  return found === null ? null : { name: found[1] ?? '', args: (found[2] ?? '').trim() }
}

export function isCommandTurn(jsonl: string, call: SlashCommand): boolean {
  const tags = [`<command-name>${call.name}</command-name>`, `<command-args>${call.args}</command-args>`]

  return jsonl.split('\n').some(line => {
    const row = parseLine(line)
    const content = textAt(row, ['type']) === 'user' ? textAt(row, ['message', 'content']) : null

    return content !== null && tags.every(tag => content.includes(tag))
  })
}

function closeOf(lines: readonly string[], start: number, fence: string): number | null {
  let depth = 0
  for (let at = start + 1; at < lines.length; at += 1) {
    const found = FENCE.exec(lines[at] ?? '')
    if (found === null) {
      continue
    }
    const marks = found[1] ?? ''
    if (found[2] !== '') {
      depth += 1
    } else if (depth > 0) {
      depth -= 1
    } else if (marks.charAt(0) === fence.charAt(0) && marks.length >= fence.length) {
      return at
    }
  }

  return null
}

function blocksOf(lines: readonly string[]): Block[] {
  const blocks: Block[] = []
  let i = 0
  while (i < lines.length) {
    const open = FENCE.exec(lines[i] ?? '')
    if (open === null) {
      i += 1
      continue
    }

    const end = closeOf(lines, i, open[1] ?? '```')
    blocks.push({ tag: open[2] ?? '', body: lines.slice(i + 1, end ?? lines.length).join('\n'), start: i, end })
    if (end === null) {
      return blocks
    }
    i = end + 1
  }

  return blocks
}

function questionOf(body: string): Reply {
  const lines = body.split('\n').map(line => line.trim()).filter(line => line !== '')
  const options = lines.flatMap(line => OPTION.exec(line)?.slice(1, 2) ?? [])
  const question = lines.filter(line => !OPTION.test(line)).join(' ')

  return { kind: 'question', question, options }
}

export function parseReply(text: string): Reply {
  const lines = text.split(/\r\n?|\n/)
  const blocks = blocksOf(lines)
  if (blocks.some(block => block.end === null)) {
    return { kind: 'unusable', reason: 'the skill replied with a fenced block that never closes' }
  }

  const question = blocks.find(block => block.tag === 'question')
  if (question !== undefined) {
    return questionOf(question.body)
  }

  const [prompt] = blocks
  if (blocks.length !== 1 || prompt === undefined || prompt.tag !== 'paste' || prompt.end === null) {
    return { kind: 'unusable', reason: `the skill replied with ${blocks.length} fenced blocks instead of one paste block` }
  }
  if (prompt.body.trim() === '') {
    return { kind: 'unusable', reason: 'the skill replied with an empty paste block' }
  }

  const notes = [...lines.slice(0, prompt.start), '', ...lines.slice(prompt.end + 1)].join('\n').trim()

  return { kind: 'prompt', prompt: prompt.body, notes }
}
