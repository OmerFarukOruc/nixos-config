import { expect, test } from 'claude-code/testing'
import type { PromptChangeInput, PromptChangeResult } from 'claude-code'
import type { Engine } from 'claude-code/testing'

import { HEADLESS_START, headlessResultOf, parseReply, readHeadless } from '../hooks/reply'
import type { HeadlessResult } from '../hooks/reply'
import { ERROR_STREAM, FORK_STREAM } from './fixtures'
import { RUNS_DIR, SESSION_ID, lastRecord, resultLine, stubSession } from './session'
import type { Seen } from './session'

const TYPED = { command: 'enhance', origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 120 } } as const
const DRAFT_FILE = /^\/tmp\/agents\/enhance-copy-[0-9a-f-]+\/draft\.md$/
const SCROLL = { offset: 0, bodyRows: 20 }
const BAND = {
  plugin: 'enhance',
  component: 'AbovePrompt',
  surface: 'terminal',
  props: { hasSurvey: false, isCollapsed: false, isWorking: false, maxRows: 5, bodyColumns: 160, scroll: SCROLL, view: {} },
} as const
const PANE = { title: 'Enhance', isFocused: true, bodyColumns: 80, placement: 'dock', scroll: SCROLL, view: {} } as const
const NOTES = { plugin: 'enhance', component: 'Pane', requestId: 'enhance-notes', surface: 'terminal', props: PANE } as const
const RUNS = { plugin: 'enhance', component: 'Pane', requestId: 'enhance-runs', surface: 'terminal', props: PANE } as const
const SITES = { band: BAND, pane: NOTES } as const
const PROMPT = resultLine('```paste\nprompt\n```\n- Understood goal: Fix the login bug.\n- Effort: high recommended; this session: medium')
const READING = resultLine('reading')
const NO_RESULT = '{"type":"system"}\n'

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
    exists: path => ['/work', '/work/shots/login.png', '/work/old.png', '/home/t/a b.jpg'].includes(path),
  })

  await $.command.run({ ...TYPED, args: 'what is wrong in shots/login.png, @missing.png, old.png.bak and "~/a b.jpg"?' })
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
    replies: [resultLine('```paste\nFix the login in src/app/login.ts. Read lib/util.ts, /repo/docs/guide.md and lib/old.ts.bak.\n```\n- Target: test'), resultLine('reading')],
  })

  await $.command.run({
    ...TYPED,
    args: 'fix src/app/login.ts like ~/notes/plan.md says, see https://example.com/issue/7. and keep `retryCount`, check @lib/util.ts, ./docs/guide.md and README.md, not lib/old.ts',
  })
  await seen.clock.settle()

  const outcome = lastRecord(seen).outcome
  expect(outcome.kind === 'enhanced' && outcome.notes.split('\n').filter(line => line.startsWith('- Not in the prompt:'))).toEqual([
    '- Not in the prompt: https://example.com/issue/7',
    '- Not in the prompt: retryCount',
    '- Not in the prompt: ~/notes/plan.md',
    '- Not in the prompt: README.md',
    '- Not in the prompt: lib/old.ts',
  ])
})

const FORK = ['--resume', SESSION_ID, '--fork-session']

for (const [notes, fork] of [
  ['- Receiver: a new session', []],
  ['- **Receiver:** this conversation, as the command says', FORK],
  ['- Receiver: `new session`', []],
  ['- Target: test', FORK],
] as const) {
  test(`in a session with turns, the cold reader of a reply with the notes "${notes}" gets ${fork.length === 0 ? 'no conversation' : 'the conversation'}`, async ($, on) => {
    const seen = stubSession(on, { turns: 2, replies: [resultLine(`\`\`\`paste\nprompt\n\`\`\`\n${notes}`), READING] })

    await $.command.run({ ...TYPED, args: 'a draft' })
    await seen.clock.settle()

    const reader = seen.spawned[1]?.argv ?? []
    expect(reader.slice(reader.indexOf('--tools'), reader.indexOf('--tools') + 2)).toEqual(['--tools', ''])
    expect(reader.filter(flag => FORK.includes(flag))).toEqual(fork)
  })
}

type Site = Parameters<Engine['ui']['mount']>[0]

async function press($: Engine, seen: Seen, site: Site, key: string): Promise<void> {
  const ui = await $.ui.mount(site)
  await ui.press({ key })
  await seen.clock.settle()
  await ui.unmount()
}

async function shown($: Engine, site: Site, text: RegExp): Promise<string | undefined> {
  const ui = await $.ui.mount(site)
  const found = await ui.find({ type: 'Text', text })
  await ui.unmount()

  return found?.text
}

function draftsOf(seen: Seen): string[] {
  return [...seen.written].flatMap(([path, text]) => (DRAFT_FILE.test(path) ? [text] : []))
}

async function typed($: Engine, seen: Seen, draft: string): Promise<void> {
  await $.command.run({ ...TYPED, args: draft })
  await seen.clock.settle()
}

test('with no run, the row draws nothing and keeps the Enhance action mounted', async ($, on) => {
  stubSession(on, { replies: [] })

  const ui = await $.ui.mount(BAND)

  expect(await ui.findAll({ type: 'Text' })).toEqual([])
  expect((await ui.findAll({ type: 'Box' })).map(box => box.props.display)).toEqual([undefined, 'none'])
  expect((await ui.find({ key: 'enhance' }))?.props.action).toBe('app:cycleDiffBase')
  expect(await ui.find({ key: 'runs' })).toBeUndefined()
})

test('the Enhance action runs on the text of the box and puts the prompt there', async ($, on) => {
  const seen = stubSession(on, { box: 'fix the login', replies: [PROMPT, READING] })

  await press($, seen, BAND, 'enhance')

  expect(draftsOf(seen)).toEqual(['fix the login'])
  expect(seen.box.text).toBe('prompt')
  expect(seen.notified).toEqual(['Enhanced prompt is ready'])
})

test('the Enhance action on an empty box starts nothing', async ($, on) => {
  const seen = stubSession(on, { box: '  ', replies: [PROMPT, READING] })

  await press($, seen, BAND, 'enhance')

  expect(seen.spawned).toEqual([])
  expect(seen.toasts).toEqual(['Type the draft after /enhance'])
})

for (const site of ['band', 'pane'] as const) {
  test(`the ${site}'s ready buttons swap the box, copy, revise on the same copy and send`, async ($, on) => {
    const seen = stubSession(on, { replies: [PROMPT, READING, resultLine('```paste\nshort\n```'), READING], answers: ['make it shorter'] })
    await typed($, seen, 'a draft')
    expect(seen.box.text).toBe('prompt')

    await press($, seen, SITES[site], `${site}-restore`)
    expect(seen.box.text).toBe('a draft')
    await press($, seen, SITES[site], `${site}-use`)
    expect(seen.box.text).toBe('prompt')
    await press($, seen, SITES[site], `${site}-copy`)
    expect(seen.copied).toEqual(['prompt'])

    await press($, seen, SITES[site], `${site}-revise`)
    const [first, , revise] = seen.spawned.map(spawn => spawn.argv)
    expect(revise?.slice(-1)).toEqual(['Revise: make it shorter'])
    expect(revise?.[revise.indexOf('--resume') + 1]).toBe(first?.[first.indexOf('--session-id') + 1])
    expect(seen.box.text).toBe('short')

    await press($, seen, SITES[site], `${site}-send`)
    expect(seen.submitted).toEqual(['short'])
    expect(seen.box.text).toBe('')
    expect(lastRecord(seen)).toMatchObject({ outcome: { kind: 'enhanced', prompt: 'short' }, sent: 'as-is', sentText: null, earlierPrompts: ['prompt'] })
    expect(await shown($, BAND, /Enhanced prompt/)).toBeUndefined()
  })

  test(`the ${site}'s Dismiss drops the result`, async ($, on) => {
    const seen = stubSession(on, { replies: [PROMPT, READING] })
    await typed($, seen, 'a draft')
    expect(await shown($, BAND, /Enhanced prompt/)).toBe('Enhanced prompt is in the box')

    await press($, seen, SITES[site], `${site}-dismiss`)

    expect(await shown($, BAND, /Enhanced prompt/)).toBeUndefined()
    expect(lastRecord(seen).sent).toBe('dropped')
  })

  test(`the ${site}'s Retry runs the draft of a failed run again`, async ($, on) => {
    const seen = stubSession(on, { replies: [NO_RESULT, PROMPT, READING] })
    await typed($, seen, 'a draft')
    expect(lastRecord(seen).outcome.kind).toBe('failed')

    await press($, seen, SITES[site], `${site}-retry`)

    expect(lastRecord(seen).outcome).toMatchObject({ kind: 'enhanced', prompt: 'prompt' })
    expect(draftsOf(seen)).toEqual(['a draft', 'a draft'])
    expect(seen.box.text).toBe('prompt')
  })
}

test('a failed run puts the draft back in an empty box and says so', async ($, on) => {
  const seen = stubSession(on, { replies: [NO_RESULT] })

  await typed($, seen, 'a draft')

  expect(seen.box.text).toBe('a draft')
  expect(await shown($, BAND, /Enhance failed/)).toMatch(/The draft is back in the box$/)
  expect(seen.notified).toEqual(['Enhance failed'])
})

test('a failed run leaves a box that holds text alone', async ($, on) => {
  const seen = stubSession(on, { box: 'typed here', replies: [NO_RESULT] })

  await press($, seen, BAND, 'enhance')

  expect(seen.box.text).toBe('typed here')
  expect(await shown($, BAND, /Enhance failed/)).toMatch(/printed no result for the prompt$/)
})

test('the ready row shows the goal and the effort of the notes', async ($, on) => {
  const seen = stubSession(on, { replies: [PROMPT, READING] })

  await typed($, seen, 'a draft')

  expect(await shown($, BAND, /^Goal:/)).toBe('Goal: Fix the login bug.')
  expect(await shown($, BAND, /^Effort:/)).toBe('Effort: high recommended; this session: medium')
})

test('a prompt equal to the draft says that nothing changed', async ($, on) => {
  const seen = stubSession(on, { replies: [resultLine('```paste\nprompt\n\n```'), READING] })

  await typed($, seen, 'prompt')

  expect(await shown($, BAND, /Enhanced prompt|nothing changed/)).toBe('Draft already clear, nothing changed')
})

for (const [sent, text, sentText] of [
  ['as-is', 'prompt', null],
  ['edited', 'prompt, and the signup too', 'prompt, and the signup too'],
  ['own-draft', 'a draft', null],
] as const) {
  test(`a submit of ${sent === 'as-is' ? 'the prompt' : sent === 'edited' ? 'a changed prompt' : 'the draft'} records ${sent}`, async ($, on) => {
    const seen = stubSession(on, { replies: [PROMPT, READING] })
    await typed($, seen, 'a draft')

    await $.prompt.submit({ text, wait: false, origin: { kind: 'composer' } })
    await seen.clock.settle()

    expect(lastRecord(seen)).toMatchObject({ sent, sentText, earlierPrompts: [] })
  })
}

const PAST = {
  startedAt: '2026-11-20T10:00:00.000Z',
  draft: 'an old draft\nsecond line',
  seconds: 71,
  costUsd: 0.479,
  outcome: { kind: 'enhanced', prompt: 'an old prompt' },
}
const FAILED = { startedAt: '2026-11-21T09:30:00.000Z', draft: 'a failed draft', seconds: 3, costUsd: 0, outcome: { kind: 'failed', reason: 'no result' } }
const RECORDS = {
  [`${RUNS_DIR}/2026-11-20T10-00-00.000Z-aaaa.json`]: JSON.stringify(PAST),
  [`${RUNS_DIR}/2026-11-21T09-30-00.000Z-bbbb.json`]: JSON.stringify(FAILED),
  [`${RUNS_DIR}/2026-10-24T11-59-59.000Z-cccc.json`]: JSON.stringify({ ...PAST, startedAt: '2026-10-24T11:59:59.000Z' }),
  [`${RUNS_DIR}/2026-10-24T12-00-01.000Z-dddd.json`]: JSON.stringify({ ...PAST, startedAt: '2026-10-24T12:00:01.000Z' }),
}
const CANCELLED = { startedAt: '2026-11-23T11:20:00.000Z', draft: 'a cancelled draft', outcome: { kind: 'cancelled' } }
const AHEAD = { startedAt: '2026-11-24T12:00:00.000Z', draft: 'a draft from a fast clock', seconds: 5, costUsd: 0.004, outcome: { kind: 'enhanced', prompt: 'p' } }
const EDGE_RECORDS = {
  [`${RUNS_DIR}/2026-11-23T11-20-00.000Z-eeee.json`]: JSON.stringify(CANCELLED),
  [`${RUNS_DIR}/2026-11-23T11-59-30.000Z-ffff.json`]: JSON.stringify({ ...PAST, startedAt: '2026-11-23T11:59:30.000Z' }),
  [`${RUNS_DIR}/2026-11-23T09-00-00.000Z-gggg.json`]: JSON.stringify({ ...PAST, startedAt: '2026-11-23T09:00:00.000Z' }),
  [`${RUNS_DIR}/2026-11-24T12-00-00.000Z-hhhh.json`]: JSON.stringify(AHEAD),
}

test('/enhance-runs lists the recent runs, newest first, with age, seconds and cost, and copies the prompt of one', async ($, on) => {
  const seen = stubSession(on, { replies: [], files: RECORDS })

  await $.command.run({ ...TYPED, command: 'enhance-runs', args: '' })
  expect(seen.opened).toEqual(['enhance-runs'])

  const ui = await $.ui.mount(RUNS)
  const texts = (await ui.findAll({ type: 'Text' })).map(row => row.text)
  expect(texts.slice(0, 8)).toEqual([
    'Recent runs',
    'newest first',
    '✗ failed',
    '2 d ago · 3 s',
    'a failed draft',
    '✓ enhanced',
    '3 d ago · 71 s · $0.48',
    'an old draft',
  ])
  expect(await ui.find({ key: 'put-back' })).toBeUndefined()
  expect(await ui.find({ key: 'copy-0' })).toBeUndefined()
  await ui.press({ key: 'copy-1' })
  await ui.unmount()
  expect(seen.copied).toEqual(['an old prompt'])
})

test('a run row leaves out each fact its record lacks, and marks an outcome that is neither enhanced nor failed with a ring', async ($, on) => {
  stubSession(on, { replies: [], files: EDGE_RECORDS })

  await $.command.run({ ...TYPED, command: 'enhance-runs', args: '' })

  const ui = await $.ui.mount(RUNS)
  const texts = (await ui.findAll({ type: 'Text' })).map(row => row.text)
  await ui.unmount()
  expect(texts.slice(2)).toEqual([
    '✓ enhanced',
    '5 s · <$0.01',
    'a draft from a fast clock',
    '✓ enhanced',
    'just now · 71 s · $0.48',
    'an old draft',
    '○ cancelled',
    '40 min ago',
    'a cancelled draft',
    '✓ enhanced',
    '3 h ago · 71 s · $0.48',
    'an old draft',
  ])
})

test('with no record, the runs pane says so', async ($, on) => {
  stubSession(on, { replies: [] })

  await $.command.run({ ...TYPED, command: 'enhance-runs', args: '' })

  const ui = await $.ui.mount(RUNS)
  const texts = (await ui.findAll({ type: 'Text' })).map(row => row.text)
  await ui.unmount()
  expect(texts).toEqual(['Recent runs', 'No enhance run has left a record yet.'])
})

test('a session start lists both commands and deletes the records that started more than 30 days ago', async ($, on) => {
  const seen = stubSession(on, { replies: [], files: RECORDS })

  await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })

  expect(seen.registered).toEqual([
    { name: 'enhance', immediate: true },
    { name: 'enhance-runs', immediate: true },
  ])
  expect([...seen.written.keys()].map(path => path.slice(RUNS_DIR.length + 1)).sort()).toEqual([
    '2026-10-24T12-00-01.000Z-dddd.json',
    '2026-11-20T10-00-00.000Z-aaaa.json',
    '2026-11-21T09-30-00.000Z-bbbb.json',
  ])
})

test("the runs pane's card shows the session's last draft and puts it back in the box", async ($, on) => {
  const seen = stubSession(on, { replies: [PROMPT, READING] })
  await typed($, seen, 'my draft')
  await press($, seen, BAND, 'band-dismiss')
  seen.box.text = ''

  await $.command.run({ ...TYPED, command: 'enhance-runs', args: '' })
  expect(seen.opened.at(-1)).toBe('enhance-runs')
  const ui = await $.ui.mount(RUNS)
  const texts = (await ui.findAll({ type: 'Text' })).map(row => row.text)
  await ui.unmount()
  expect(texts.slice(0, 2)).toEqual(['Last draft of this session', 'my draft'])
  await press($, seen, RUNS, 'put-back')

  expect(seen.box.text).toBe('my draft')
})

test('Put draft in box over a prompt that is in the box leaves the result behind Use prompt', async ($, on) => {
  const seen = stubSession(on, { replies: [PROMPT, READING] })
  await typed($, seen, 'my draft')
  expect(await shown($, BAND, /Enhanced prompt/)).toBe('Enhanced prompt is in the box')

  await $.command.run({ ...TYPED, command: 'enhance-runs', args: '' })
  await press($, seen, RUNS, 'put-back')

  expect(seen.box.text).toBe('my draft')
  expect(await shown($, BAND, /Enhanced prompt/)).toBe('Enhanced prompt is ready')
})

const NO_ROOM = { ...BAND, props: { ...BAND.props, maxRows: 0, scroll: { offset: 0, bodyRows: 0 } } } as const

function transcriptRow(id: string) {
  return { plugin: 'enhance', component: 'Placed', requestId: id, surface: 'terminal', props: { id, plugin: 'enhance' } } as const
}

async function buttons($: Engine, site: Site): Promise<number> {
  const ui = await $.ui.mount(site)
  const found = await ui.findAll({ type: 'Button' })
  await ui.unmount()

  return found.length
}

test('the result row is drawn in the transcript only while the band has no room, and by this plugin alone', async ($, on) => {
  const seen = stubSession(on, { replies: [PROMPT, READING] })
  await typed($, seen, 'a draft')

  await buttons($, BAND)
  expect(seen.placed).toEqual([])

  await buttons($, NO_ROOM)
  await buttons($, NO_ROOM)
  expect(seen.placed).toHaveLength(1)
  const [id = ''] = seen.placed
  expect(await buttons($, transcriptRow(id))).toBe(6)
  expect(await buttons($, { ...transcriptRow(id), props: { id, plugin: 'other' } })).toBe(0)
  expect(await buttons($, transcriptRow('enhance-row-0'))).toBe(0)
  await press($, seen, transcriptRow(id), 'row-copy')
  expect(seen.copied).toEqual(['prompt'])

  await buttons($, BAND)
  expect(await buttons($, transcriptRow(id))).toBe(0)

  await buttons($, NO_ROOM)
  expect(seen.placed).toHaveLength(2)
  expect(await buttons($, transcriptRow(id))).toBe(0)
  expect(await buttons($, transcriptRow(seen.placed[1] ?? ''))).toBe(6)

  await press($, seen, transcriptRow(seen.placed[1] ?? ''), 'row-dismiss')
  expect(await buttons($, transcriptRow(seen.placed[1] ?? ''))).toBe(0)
  await buttons($, BAND)
})

test('with no room above the prompt, a failed run is told in the transcript', async ($, on) => {
  const seen = stubSession(on, { replies: [NO_RESULT] })
  await typed($, seen, 'a draft')

  await buttons($, NO_ROOM)

  expect(await shown($, transcriptRow(seen.placed[0] ?? ''), /Enhance failed/)).toMatch(/The draft is back in the box/)
  await press($, seen, transcriptRow(seen.placed[0] ?? ''), 'row-dismiss')
  await buttons($, BAND)
})

test('a row the conversation refuses is told once in a toast', async ($, on) => {
  const seen = stubSession(on, { replies: [PROMPT, READING], placeRefusal: 'past the cap' })
  await typed($, seen, 'a draft')
  const before = seen.toasts.length

  await buttons($, NO_ROOM)
  await buttons($, NO_ROOM)

  expect(seen.toasts.slice(before)).toEqual(['The enhance buttons have no room above the prompt, and the conversation took no row for them: past the cap'])
})

test('a band the person collapsed keeps the result row out of the transcript', async ($, on) => {
  const seen = stubSession(on, { replies: [PROMPT, READING] })
  await typed($, seen, 'a draft')

  await buttons($, { ...NO_ROOM, props: { ...NO_ROOM.props, isCollapsed: true } })

  expect(seen.placed).toEqual([])
})

test('a task notification leaves a ready result in place', async ($, on) => {
  const seen = stubSession(on, { replies: [PROMPT, READING] })
  await typed($, seen, 'a draft')

  await $.prompt.submit({ text: 'a background task ended', wait: false, origin: { kind: 'task-notification' } })
  await seen.clock.settle()

  expect(await shown($, BAND, /Enhanced prompt/)).toBe('Enhanced prompt is in the box')
  expect(lastRecord(seen).sent).toBeNull()
})

test('a Revise turn that fails keeps the earlier prompt and its record', async ($, on) => {
  const seen = stubSession(on, { replies: [PROMPT, READING, NO_RESULT], answers: ['make it shorter'] })
  await typed($, seen, 'a draft')

  await press($, seen, BAND, 'band-revise')

  const [first] = seen.spawned.map(spawn => spawn.argv)
  const copyId = first?.[first.indexOf('--session-id') + 1] ?? ''
  expect(seen.spawned.length).toBe(3)
  expect(await shown($, BAND, /Enhanced prompt/)).toBe('Enhanced prompt is in the box')
  expect(lastRecord(seen).outcome).toMatchObject({ kind: 'enhanced', prompt: 'prompt' })
  expect(seen.ran.filter(argv => argv.includes(`${copyId}.jsonl`))).toEqual([])
  expect(seen.toasts.length).toBe(1)
  expect(seen.toasts[0]).toMatch(/^Revise failed/)
})

test('a Send that is refused keeps the result and records nothing as sent', async ($, on) => {
  const seen = stubSession(on, { replies: [PROMPT, READING], isSubmitRefused: true })
  await typed($, seen, 'a draft')

  await press($, seen, BAND, 'band-send')

  expect(await shown($, BAND, /Enhanced prompt/)).toBe('Enhanced prompt is in the box')
  expect(seen.box.text).toBe('prompt')
  expect(lastRecord(seen).sent).toBeNull()
})

test('a slash command leaves a ready result in place', async ($, on) => {
  const seen = stubSession(on, { replies: [PROMPT, READING] })
  await typed($, seen, 'a draft')

  await $.prompt.submit({ text: '/effort high', command: { name: 'effort', args: 'high' }, wait: false, origin: { kind: 'composer' } })
  await seen.clock.settle()

  expect(await shown($, BAND, /Enhanced prompt/)).toBe('Enhanced prompt is in the box')
  expect(lastRecord(seen).sent).toBeNull()
})

// The kit raises prompt.change on its $, but its Engine type lists only the calls a hook can make on its own $.
type PromptChange = { change: (e: PromptChangeInput) => Promise<PromptChangeResult> }

async function changed($: Engine, seen: Seen, origin: PromptChangeInput['origin']): Promise<void> {
  const prompt = $.prompt as Engine['prompt'] & PromptChange
  await prompt.change({ text: seen.box.text, cursor: 0, origin })
  await seen.clock.settle()
}

async function recall($: Engine, seen: Seen, entry: string): Promise<void> {
  seen.box.text = entry
  await changed($, seen, { kind: 'history' })
}

const RUN_ENDS = [
  ['a prompt put in the box', { box: 'fix the login', replies: [PROMPT, READING] }, async ($: Engine, seen: Seen) => press($, seen, BAND, 'enhance')],
  [
    'a prompt that was dismissed',
    { box: 'fix the login', replies: [PROMPT, READING] },
    async ($: Engine, seen: Seen) => {
      await press($, seen, BAND, 'enhance')
      await press($, seen, BAND, 'band-dismiss')
    },
  ],
  ['a failed run beside other text in the box', { box: 'typed here', replies: [NO_RESULT] }, async ($: Engine, seen: Seen) => typed($, seen, 'fix the login')],
] as const

for (const [end, script, run] of RUN_ENDS) {
  test(`after ${end}, the first history recall brings the draft back and the next one is left alone`, async ($, on) => {
    const seen = stubSession(on, script)
    await run($, seen)
    expect(seen.box.text).not.toBe('fix the login')

    await recall($, seen, 'newest entry')
    expect(seen.box.text).toBe('fix the login')

    await recall($, seen, 'older entry')
    expect(seen.box.text).toBe('older entry')
  })
}

const OFFER_ENDS = [
  ['a submit from the box', async ($: Engine) => $.prompt.submit({ text: 'prompt', wait: false, origin: { kind: 'composer' } })],
  ['Send', async ($: Engine, seen: Seen) => press($, seen, BAND, 'band-send')],
  [
    'Restore draft',
    async ($: Engine, seen: Seen) => {
      await press($, seen, BAND, 'band-restore')
      await changed($, seen, { kind: 'plugin', name: 'enhance' })
    },
  ],
  ['/clear', async ($: Engine) => $.session.end({ reason: 'clear', sessionId: SESSION_ID, resume: { id: SESSION_ID } })],
] as const

for (const [end, act] of OFFER_ENDS) {
  test(`after ${end}, a history recall is left alone`, async ($, on) => {
    const seen = stubSession(on, { box: 'fix the login', replies: [PROMPT, READING] })
    await press($, seen, BAND, 'enhance')

    await act($, seen)
    await seen.clock.settle()
    await recall($, seen, 'newest entry')

    expect(seen.box.text).toBe('newest entry')
  })
}

test('a question block before an unclosed paste block is unusable', () => {
  expect(parseReply('```question\nWhich page?\n```\n```paste\ncut off').kind).toBe('unusable')
})
