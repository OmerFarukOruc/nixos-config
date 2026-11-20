export type Reply =
  | { kind: 'prompt'; prompt: string; notes: string }
  | { kind: 'question'; question: string; options: string[] }
  | { kind: 'unusable'; reason: string }

export type HeadlessResult = { kind: 'answered'; text: string } | { kind: 'failed'; reason: string }

export type HeadlessReader = { rest: string; result: HeadlessResult | null }

type Block = { tag: string; body: string; start: number; end: number | null }

const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const FENCE = /^ {0,3}(`{3,}|~{3,})[ \t]*(\S*)/
const OPTION = /^- (.+)$/

export function isSessionId(text: string): boolean {
  return SESSION_ID.test(text)
}

function valueAt(value: unknown, path: readonly string[]): unknown {
  return path.reduce<unknown>(
    (at, key) => (typeof at === 'object' && at !== null && key in at ? (at as Record<string, unknown>)[key] : undefined),
    value,
  )
}

function textAt(value: unknown, path: readonly string[]): string | null {
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

function isPromptResult(event: unknown): boolean {
  return textAt(event, ['type']) === 'result' && textAt(event, ['origin', 'kind']) !== 'task-notification'
}

function promptResultOf(line: string): HeadlessResult | null {
  const event = parseLine(line)
  if (!isPromptResult(event)) {
    return null
  }

  const text = textAt(event, ['result'])
  if (valueAt(event, ['is_error']) === true || text === null) {
    return { kind: 'failed', reason: `claude -p failed: ${text ?? 'no text'}` }
  }

  return { kind: 'answered', text }
}

export const HEADLESS_START: HeadlessReader = { rest: '', result: null }

export function readHeadless(reader: HeadlessReader, text: string): HeadlessReader {
  if (reader.result !== null) {
    return reader
  }

  const lines = (reader.rest + text).split('\n')
  const rest = lines.pop() ?? ''
  for (const line of lines) {
    const result = promptResultOf(line)
    if (result !== null) {
      return { rest: '', result }
    }
  }

  return { rest, result: null }
}

export function headlessResultOf(reader: HeadlessReader): HeadlessResult {
  return reader.result ?? promptResultOf(reader.rest) ?? { kind: 'failed', reason: 'claude -p printed no result for the prompt' }
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
