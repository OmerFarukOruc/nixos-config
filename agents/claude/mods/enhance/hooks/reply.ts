import type { Spent } from '../types'

export type Reply =
  | { kind: 'prompt'; prompt: string; notes: string }
  | { kind: 'question'; question: string; options: string[] }
  | { kind: 'unusable'; reason: string }

export type HeadlessResult = { kind: 'answered'; text: string } | { kind: 'failed'; reason: string }

export type HeadlessReader = { rest: string; result: HeadlessResult | null; model: string | null; spent: Spent; tool: string | null }

type Block = { tag: string; body: string; start: number; end: number | null }

const SESSION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const FENCE = /^ {0,3}(`{3,}|~{3,})[ \t]*(\S*)/
const OPTION = /^- (.+)$/
const TOOL_ARGUMENT_CHARS = 40
const UNCLOSED_WARNING = "The reply's paste block was not closed, so the prompt may be cut off."

export const NOTHING_SPENT: Spent = { costUsd: 0, turns: 0, tokens: { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 } }

export function isSessionId(text: string): boolean {
  return SESSION_ID.test(text)
}

function valueAt(value: unknown, path: readonly string[]): unknown {
  return path.reduce<unknown>(
    (at, key) => (typeof at === 'object' && at !== null && key in at ? (at as Record<string, unknown>)[key] : undefined),
    value,
  )
}

function foundAt<Kind>(value: unknown, path: readonly string[], isKind: (found: unknown) => found is Kind): Kind | null {
  const found = valueAt(value, path)

  return isKind(found) ? found : null
}

export function textAt(value: unknown, path: readonly string[]): string | null {
  return foundAt(value, path, (found): found is string => typeof found === 'string')
}

export function numberOrNullAt(value: unknown, path: readonly string[]): number | null {
  return foundAt(value, path, (found): found is number => typeof found === 'number')
}

function numberAt(value: unknown, path: readonly string[]): number {
  return numberOrNullAt(value, path) ?? 0
}

function valuesOf(value: unknown): unknown[] | null {
  return typeof value === 'object' && value !== null ? Object.values(value) : null
}

export function plus(a: Spent, b: Spent): Spent {
  return {
    costUsd: a.costUsd === null || b.costUsd === null ? null : a.costUsd + b.costUsd,
    turns: a.turns + b.turns,
    tokens: {
      input: a.tokens.input + b.tokens.input,
      output: a.tokens.output + b.tokens.output,
      cacheRead: a.tokens.cacheRead + b.tokens.cacheRead,
      cacheCreation: a.tokens.cacheCreation + b.tokens.cacheCreation,
    },
  }
}

function spentOf(event: unknown): Spent {
  const costs = valuesOf(valueAt(event, ['model_usage_since_last_result']))?.map(model => valueAt(model, ['costUSD'])) ?? null

  return {
    costUsd: costs === null ? null : costs.reduce<number | null>((sum, cost) => (sum === null || typeof cost !== 'number' ? null : sum + cost), 0),
    turns: numberAt(event, ['num_turns']),
    tokens: {
      input: numberAt(event, ['usage', 'input_tokens']),
      output: numberAt(event, ['usage', 'output_tokens']),
      cacheRead: numberAt(event, ['usage', 'cache_read_input_tokens']),
      cacheCreation: numberAt(event, ['usage', 'cache_creation_input_tokens']),
    },
  }
}

function toolOf(event: unknown): string | null {
  const content = valueAt(event, ['message', 'content'])
  const use = Array.isArray(content) ? content.findLast(block => textAt(block, ['type']) === 'tool_use') : undefined
  if (use === undefined) {
    return null
  }
  const name = textAt(use, ['name']) ?? 'tool'
  const argument = valuesOf(valueAt(use, ['input']))?.find(value => typeof value === 'string')

  return typeof argument === 'string' ? `${name} ${argument.replace(/\s+/g, ' ').trim().slice(0, TOOL_ARGUMENT_CHARS)}` : name
}

export function parseLine(line: string): unknown {
  try {
    return JSON.parse(line)
  } catch {
    return undefined
  }
}

function isPromptResult(event: unknown): boolean {
  return textAt(event, ['type']) === 'result' && textAt(event, ['origin', 'kind']) !== 'task-notification'
}

function promptResultOf(event: unknown): HeadlessResult | null {
  if (!isPromptResult(event)) {
    return null
  }

  const text = textAt(event, ['result'])
  if (valueAt(event, ['is_error']) === true || text === null) {
    return { kind: 'failed', reason: `claude -p failed: ${text ?? 'no text'}` }
  }

  return { kind: 'answered', text }
}

export const HEADLESS_START: HeadlessReader = { rest: '', result: null, model: null, spent: NOTHING_SPENT, tool: null }

function withLine(reader: HeadlessReader, line: string): HeadlessReader {
  const event = parseLine(line)
  const result = promptResultOf(event)
  if (result !== null) {
    return { ...reader, rest: '', result, spent: spentOf(event) }
  }

  const type = textAt(event, ['type'])

  return {
    ...reader,
    model: reader.model ?? (textAt(event, ['subtype']) === 'init' ? textAt(event, ['model']) : null),
    tool: type === 'assistant' ? toolOf(event) : type === 'user' ? null : reader.tool,
  }
}

export function readHeadless(reader: HeadlessReader, text: string): HeadlessReader {
  const lines = (reader.rest + text).split('\n')
  const rest = lines.pop() ?? ''

  const read = lines.reduce((at, line) => (at.result === null ? withLine(at, line) : at), reader)

  return { ...read, rest: read.result === null ? rest : '' }
}

export function endHeadless(reader: HeadlessReader): HeadlessReader {
  return reader.result === null ? withLine(reader, reader.rest) : reader
}

export function headlessResultOf(reader: HeadlessReader): HeadlessResult {
  return endHeadless(reader).result ?? { kind: 'failed', reason: 'claude -p printed no result for the prompt' }
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

function notesOf(lines: readonly string[], blocks: readonly Block[]): string {
  const outside = blocks.reduce<{ kept: string[]; from: number }>(
    (at, block) => ({ kept: [...at.kept, ...lines.slice(at.from, block.start), ''], from: (block.end ?? lines.length) + 1 }),
    { kept: [], from: 0 },
  )

  return [...outside.kept, ...lines.slice(outside.from)].join('\n').trim()
}

export function parseReply(text: string): Reply {
  const lines = text.split(/\r\n?|\n/)
  const blocks = blocksOf(lines)
  const prompt = blocks.at(-1)
  if (blocks.some(block => block.end === null) && blocks.some(block => block.tag !== 'paste')) {
    return { kind: 'unusable', reason: 'the skill replied with a fenced block that never closes' }
  }

  const question = blocks.find(block => block.tag === 'question')
  if (question !== undefined) {
    return questionOf(question.body)
  }
  if (prompt === undefined || blocks.some(block => block.tag !== 'paste')) {
    return { kind: 'unusable', reason: prompt === undefined ? 'the skill replied with no paste block' : 'the skill replied with a fenced block that is not a paste block' }
  }
  if (prompt.body.trim() === '') {
    return { kind: 'unusable', reason: 'the skill replied with an empty paste block' }
  }

  const notes = notesOf(lines, blocks)

  return { kind: 'prompt', prompt: prompt.body, notes: prompt.end === null ? [notes, `- ${UNCLOSED_WARNING}`].filter(part => part !== '').join('\n') : notes }
}
