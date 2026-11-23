import { expect, test } from 'claude-code/testing'

import { HEADLESS_START, headlessResultOf, parseReply, readHeadless } from '../hooks/reply'
import type { HeadlessResult } from '../hooks/reply'
import { ERROR_STREAM, FORK_STREAM } from './fixtures'
import { lastRecord, resultLine, stubSession } from './session'

const TYPED = { command: 'enhance', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 120 } } as const
const DRAFT_FILE = /^\/tmp\/agents\/enhance-copy-[0-9a-f-]+\/draft\.md$/

test('/enhance with no draft starts nothing', async ($, on) => {
  let started = 0
  const toasts: string[] = []
  on('ui.toast', (_, toast) => {
    toasts.push(toast.text)
    return { value: undefined }
  })
  on('process.spawn', async function* () {
    started += 1
    return { value: { code: 0, signal: null } }
  })
  on('process.run', () => {
    started += 1
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })

  const answer = await $.command.run({
    command: 'enhance',
    args: '  ',
    origin: { kind: 'composer' },
    presentation: { isFullscreen: false, columns: 120 },
  })

  expect(answer.text).toBe(undefined)
  expect(started).toBe(0)
  expect(toasts.length).toBe(1)
})

function resultOf(stream: string, pieceSize: number): HeadlessResult {
  let reader = HEADLESS_START
  for (let at = 0; at < stream.length; at += pieceSize) {
    reader = readHeadless(reader, stream.slice(at, at + pieceSize))
  }

  return headlessResultOf(reader)
}

test('the reply is the result of the prompt, not of a task notification before or after it', () => {
  const lines = FORK_STREAM.split('\n')
  const [notice, noticeResult] = lines
  for (const pieceSize of [7, 1000, FORK_STREAM.length + 100]) {
    expect(resultOf(FORK_STREAM, pieceSize)).toEqual({ kind: 'answered', text: 'ok' })
    expect(resultOf(`${FORK_STREAM}\n`, pieceSize)).toEqual({ kind: 'answered', text: 'ok' })
    expect(resultOf([...lines, notice, noticeResult].join('\n'), pieceSize)).toEqual({ kind: 'answered', text: 'ok' })
    expect(resultOf(lines.slice(0, 3).join('\n'), pieceSize).kind).toBe('failed')
  }
})

test('an error result fails the run with its message, and a run with no output fails', () => {
  const failed = resultOf(`[claude-code:unrecognized_model] noise on stdout\n${ERROR_STREAM}`, 64)
  expect(failed.kind === 'failed' && failed.reason.includes('claude-nonexistent-9')).toBe(true)
  expect(resultOf('', 64).kind).toBe('failed')
})

test('the one paste block is the prompt and the rest are notes', () => {
  expect(parseReply('Intro\n```paste Title\nbody\n```\n- note')).toEqual({ kind: 'prompt', prompt: 'body', notes: 'Intro\n\n- note' })
  expect(parseReply('````paste\nRun:\n```sh\nnpm test\n```\n````')).toEqual({ kind: 'prompt', prompt: 'Run:\n```sh\nnpm test\n```', notes: '' })
  expect(parseReply('~~~paste\nbody\n~~~')).toEqual({ kind: 'prompt', prompt: 'body', notes: '' })
  expect(parseReply('```paste\nRun:\n```sh\nnpm test\n```\nDone.\n```\nnote')).toEqual({
    kind: 'prompt',
    prompt: 'Run:\n```sh\nnpm test\n```\nDone.',
    notes: 'note',
  })
})

test('the last of several paste blocks is the prompt, and an unclosed last one carries a warning', () => {
  const warning = "- The reply's paste block was not closed, so the prompt may be cut off."
  expect(parseReply('first\n```paste\na\n```\nsecond\n```paste\nb\n```')).toEqual({ kind: 'prompt', prompt: 'b', notes: 'first\n\nsecond' })
  expect(parseReply('note\n```paste\nbody without a closing fence')).toEqual({
    kind: 'prompt',
    prompt: 'body without a closing fence',
    notes: `note\n${warning}`,
  })
  expect(parseReply('```paste\na\n```\n```paste\nunclosed second block')).toEqual({ kind: 'prompt', prompt: 'unclosed second block', notes: warning })
})

test('a reply the box must not take is unusable', () => {
  const unusable = [
    'no block here',
    '```paste\n\n```',
    '```sh\nnpm test',
    '````markdown\nAn example:\n```paste\nexample\n```\n````',
    '```paste\nRun:\n```\nnpm test\n```\nThen stop.\n```\nnote',
    '```paste\nbody\n```\n```sh\nnpm test\n```',
  ]
  for (const reply of unusable) {
    expect(parseReply(reply).kind).toBe('unusable')
  }
})

test('a question block gives the question and its options', () => {
  expect(parseReply('```question\nWhich login page?\n- inbox\n- threadsift\n```')).toEqual({
    kind: 'question',
    question: 'Which login page?',
    options: ['inbox', 'threadsift'],
  })
  expect(parseReply('```question\nWhich login page?\n```')).toEqual({ kind: 'question', question: 'Which login page?', options: [] })
})

test('a typed image path that exists gets a path line in the draft file, and one that does not gets none', async ($, on) => {
  const seen = stubSession(on, {
    replies: [resultLine('```paste\nprompt\n```'), resultLine('reading')],
    exists: path => path === '/work' || path === '/work/shots/login.png' || path === '/home/t/a b.jpg',
  })

  await $.command.run({ ...TYPED, args: 'what is wrong in shots/login.png, @missing.png and "~/a b.jpg"?' })
  await seen.clock.settle()

  const [draft] = [...seen.written].flatMap(([path, text]) => (DRAFT_FILE.test(path) ? [text] : []))
  expect(draft?.split('\n').slice(2)).toEqual(['shots/login.png is the image file /work/shots/login.png', '~/a b.jpg is the image file /home/t/a b.jpg'])
})

test('an unusable reply gets one repair turn on the same copy', async ($, on) => {
  const seen = stubSession(on, { replies: [resultLine('no block'), resultLine('```paste\nprompt\n```'), resultLine('reading')] })

  await $.command.run({ ...TYPED, args: 'a draft' })
  await seen.clock.settle()

  const [first, repair] = seen.spawned.map(spawn => spawn.argv)
  const copyId = first?.[(first?.indexOf('--session-id') ?? 0) + 1]
  expect(repair?.slice(repair.indexOf('--resume'), repair.indexOf('--resume') + 2)).toEqual(['--resume', copyId])
  expect(repair?.at(-1)).toBe('Your reply was unusable: the skill replied with no paste block. Reply again with one paste block or one question block.')
  expect(lastRecord(seen).outcome).toMatchObject({ kind: 'enhanced', prompt: 'prompt' })
})

test('a second unusable reply fails the run', async ($, on) => {
  const seen = stubSession(on, { replies: [resultLine('no block'), resultLine('still no block'), resultLine('```paste\nlate\n```')] })

  await $.command.run({ ...TYPED, args: 'a draft' })
  await seen.clock.settle()

  expect(seen.spawned.length).toBe(2)
  expect(lastRecord(seen).outcome).toEqual({ kind: 'failed', reason: 'the skill replied with no paste block', notes: 'still no block' })
})

test('the notes name each path, URL and code span of the draft that the prompt leaves out', async ($, on) => {
  const seen = stubSession(on, {
    replies: [resultLine('```paste\nFix the login in src/app/login.ts.\n```\n- Target: test'), resultLine('reading')],
  })

  await $.command.run({ ...TYPED, args: 'fix src/app/login.ts like ~/notes/plan.md says, see https://example.com/issue/7. and keep `retryCount`' })
  await seen.clock.settle()

  const outcome = lastRecord(seen).outcome
  expect(outcome.kind === 'enhanced' && outcome.notes.split('\n').filter(line => line.startsWith('- Not in the prompt:'))).toEqual([
    '- Not in the prompt: https://example.com/issue/7',
    '- Not in the prompt: retryCount',
    '- Not in the prompt: ~/notes/plan.md',
  ])
})
