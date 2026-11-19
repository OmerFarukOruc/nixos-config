import { expect, test } from 'claude-code/testing'

import { foldBytes, parseHeadless, parseReply, readerAt } from '../hooks/reply'
import type { TurnState } from '../hooks/reply'
import { API_ERROR, HEADLESS_ERROR, HEADLESS_OK, INTERRUPT, SESSION } from './fixtures'

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

const ROWS = SESSION.split('\n')

function turnOf(rows: readonly (string | undefined)[]): TurnState {
  return foldBytes(readerAt(0), new TextEncoder().encode(rows.map(row => `${row}\n`).join('')), null).turn
}

function turnAfter(rows: number): TurnState {
  return turnOf(ROWS.slice(0, rows))
}

test('the reply is the last assistant text since the last prompt, once a turn_duration row with no pending work ends the turn', () => {
  expect(turnAfter(3)).toEqual({ text: null, hasEnded: false, isApiError: false })
  expect(turnAfter(5)).toEqual({ text: 'done', hasEnded: false, isApiError: false })
  expect(turnAfter(6)).toEqual({ text: 'done', hasEnded: false, isApiError: false })
  expect(turnAfter(7)).toEqual({ text: 'done', hasEnded: true, isApiError: false })
  expect(turnAfter(8)).toEqual({ text: null, hasEnded: false, isApiError: false })
  const retrying = 'The first launch failed because I added `isolation: remote`, which you did not ask for. Retrying without it.'
  expect(turnAfter(11)).toEqual({ text: retrying, hasEnded: false, isApiError: false })
  expect(turnAfter(14)).toEqual({ text: 'started', hasEnded: false, isApiError: false })
  expect(turnAfter(15)).toEqual({ text: null, hasEnded: false, isApiError: false })
  expect(turnAfter(17)).toEqual({ text: 'The background subagent finished and replied `ok`.', hasEnded: true, isApiError: false })
  expect(turnOf([...ROWS, 'not json'])).toEqual(turnAfter(17))
})

test('an interrupted turn has no reply, and an API error row stops the turn with its message', () => {
  expect(turnOf([...ROWS.slice(0, 5), INTERRUPT, ROWS[6]])).toEqual({ text: null, hasEnded: true, isApiError: false })
  expect(turnOf([ROWS[0], API_ERROR])).toEqual({
    text: "You've hit your 5-hour limit · resets 7:10pm (Europe/Istanbul)",
    hasEnded: false,
    isApiError: true,
  })
})
