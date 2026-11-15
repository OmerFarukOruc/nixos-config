import { expect, test } from 'claude-code/testing'

import { lastAssistantText, parseHeadless, parseReply } from '../hooks/reply'
import { HEADLESS_ERROR, HEADLESS_OK, TRANSCRIPT } from './fixtures'

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

test('a claude -p result gives its text, and an error result gives its message', () => {
  expect(parseHeadless(HEADLESS_OK)).toEqual({ kind: 'answered', text: 'ok' })
  const failed = parseHeadless(`[claude-code:unrecognized_model] noise on stdout\n${HEADLESS_ERROR}`)
  expect(failed.kind).toBe('failed')
  expect(failed.kind === 'failed' && failed.reason.includes('claude-nonexistent-9')).toBe(true)
  expect(parseHeadless('').kind).toBe('failed')
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

test('the reply is the last assistant text of the copy transcript', () => {
  expect(lastAssistantText(TRANSCRIPT)).toBe('hi')
  expect(lastAssistantText(`${TRANSCRIPT}\nnot json\n{"type":"system"}`)).toBe('hi')
  expect(lastAssistantText(TRANSCRIPT.split('\n')[0] ?? '')).toBe(null)
})
