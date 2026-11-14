export type Reply =
  | { kind: 'prompt'; prompt: string; notes: string }
  | { kind: 'question'; question: string; options: string[] }
  | { kind: 'unusable'; reason: string }

export type HeadlessResult = { kind: 'answered'; text: string } | { kind: 'failed'; reason: string }

type Block = { tag: string; body: string; start: number; end: number | null }

const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const FENCE = /^ {0,3}(`{3,}|~{3,})[ \t]*(\S*)/
const OPTION = /^- (.+)$/

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

export function lastAssistantText(jsonl: string): string | null {
  const texts = jsonl.split('\n').flatMap(line => {
    const row = parseLine(line)
    const content = textAt(row, ['type']) === 'assistant' ? valueAt(row, ['message', 'content']) : undefined
    const blocks: unknown[] = Array.isArray(content) ? content : []

    return blocks.flatMap(block => (textAt(block, ['type']) === 'text' ? [textAt(block, ['text']) ?? ''] : []))
  })

  return texts.at(-1) ?? null
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
