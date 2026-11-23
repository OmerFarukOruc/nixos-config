import type { EngineInterface } from 'claude-code'

import type { Guide, RunRecord, RunSummary } from '../types'
import { configDir, runTool } from './copies'
import { parseLine, textAt } from './reply'

const RECENT_RUNS = 10
const KEEP_MS = 30 * 24 * 60 * 60 * 1000
const RECORD_NAME = /^(\d{4}-\d{2}-\d{2}T\d{2})-(\d{2})-(\d{2}\.\d{3}Z)-.+\.json$/
const SKILL_FILE = 'skills/enhance-prompt/SKILL.md'

async function recordsDir($: EngineInterface): Promise<string> {
  return `${(await $.env.get('XDG_STATE_HOME')) || `${(await $.env.get('HOME')) || ''}/.local/state`}/enhance/runs`
}

async function guidesDir($: EngineInterface): Promise<string> {
  return `${(await $.env.get('XDG_CACHE_HOME')) || `${(await $.env.get('HOME')) || ''}/.cache`}/enhance-prompt/guides`
}

export async function writeRecord($: EngineInterface, record: RunRecord): Promise<void> {
  await $.fs.write(`${await recordsDir($)}/${record.startedAt.replaceAll(':', '-')}-${record.id}.json`, `${JSON.stringify(record, null, 2)}\n`)
}

async function sha256Of($: EngineInterface, path: string): Promise<string | null> {
  try {
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(await $.fs.read(path)))

    return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('')
  } catch {
    return null
  }
}

export async function skillSha256($: EngineInterface): Promise<string | null> {
  return (await sha256Of($, `${await configDir($)}/${SKILL_FILE}`)) ?? sha256Of($, `${$.plugin.root}/${SKILL_FILE}`)
}

type CachedFile = { path: string; mtimeMs: number }

async function filesUnder($: EngineInterface, dir: string): Promise<CachedFile[]> {
  const entries = (await $.fs.exists(dir)) ? await $.fs.list(dir) : []
  const nested = await Promise.all(
    entries.map(async entry => {
      const path = `${dir}/${entry.name}`
      if (entry.kind === 'dir') {
        return filesUnder($, path)
      }

      return entry.kind === 'file' ? [{ path, mtimeMs: entry.mtimeMs }] : []
    }),
  )

  return nested.flat()
}

export async function guidesOf($: EngineInterface, since: number, notes: string): Promise<Guide[]> {
  try {
    const dir = await guidesDir($)
    const used = (await filesUnder($, dir)).flatMap(file => {
      const url = `https://${file.path.slice(dir.length + 1)}`
      const isDownloaded = file.mtimeMs >= since

      return isDownloaded || notes.includes(url) ? [{ path: file.path, url, isDownloaded }] : []
    })
    const guides = await Promise.all(
      used.map(async ({ path, url, isDownloaded }) => {
        const sha256 = await sha256Of($, path)
        return sha256 === null ? [] : [{ url, sha256, isDownloaded }]
      }),
    )

    return guides.flat()
  } catch (error) {
    $.ui.toast(`Could not read the guide cache for the enhance run record: ${error instanceof Error ? error.message : String(error)}`)
    return []
  }
}

function startOf(name: string): number | null {
  const found = RECORD_NAME.exec(name)
  const time = found === null ? Number.NaN : Date.parse(`${found[1]}:${found[2]}:${found[3]}`)

  return Number.isNaN(time) ? null : time
}

async function recordNames($: EngineInterface, dir: string): Promise<string[]> {
  const entries = (await $.fs.exists(dir)) ? await $.fs.list(dir) : []

  return entries.flatMap(entry => (entry.kind === 'file' && startOf(entry.name) !== null ? [entry.name] : []))
}

function summaryOf(text: string): RunSummary[] {
  const record = parseLine(text)
  const [startedAt, outcome, draft] = [textAt(record, ['startedAt']), textAt(record, ['outcome', 'kind']), textAt(record, ['draft'])]

  return startedAt === null || outcome === null || draft === null ? [] : [{ startedAt, outcome, draft, prompt: textAt(record, ['outcome', 'prompt']) }]
}

export async function recentRuns($: EngineInterface): Promise<RunSummary[]> {
  const dir = await recordsDir($)
  const newest = (await recordNames($, dir)).sort().reverse().slice(0, RECENT_RUNS)
  const runs = await Promise.all(newest.map(async name => summaryOf(await $.fs.read(`${dir}/${name}`))))

  return runs.flat()
}

export async function pruneRecords($: EngineInterface): Promise<void> {
  const dir = await recordsDir($)
  const oldest = (await $.clock.now()) - KEEP_MS
  const old = (await recordNames($, dir)).filter(name => (startOf(name) ?? oldest) < oldest)
  if (old.length === 0) {
    return
  }
  const removed = await runTool($, ['rm', '-f', '--', ...old.map(name => `${dir}/${name}`)])
  if (removed.exitCode !== 0) {
    throw new Error(`could not remove old enhance run records under ${dir}: ${removed.stderr.trim().slice(0, 200)}`)
  }
}
