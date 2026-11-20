import { expect, test } from 'claude-code/testing'

import { HEADLESS_START, headlessResultOf, parseReply, readHeadless } from '../hooks/reply'
import type { HeadlessResult } from '../hooks/reply'
import { ERROR_STREAM, FORK_STREAM } from './fixtures'

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

test('a reply the box must not take is unusable', () => {
  const unusable = [
    'no block here',
    '```paste\n\n```',
    '```paste\na\n```\n```paste\nb\n```',
    '```paste\nbody without a closing fence',
    '```paste\na\n```\n```paste\nunclosed second block',
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
