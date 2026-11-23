import type { EngineInterface, Hook, On } from 'claude-code'

const DEFAULT_EFFORT = 'medium'
const EFFORT_FLAG = /(?:^|\s)--effort(?:=|\s+)([a-z]+)/

let lastStepEffort: string | null = null
let isSetByCommand = false

function effortAt(settings: unknown, model: string): string | null {
  const models = typeof settings === 'object' && settings !== null ? (settings as { modelSettings?: unknown }).modelSettings : undefined
  const entry = typeof models === 'object' && models !== null ? (models as Record<string, unknown>)[model] : undefined
  const level = typeof entry === 'object' && entry !== null ? (entry as { effortLevel?: unknown }).effortLevel : undefined

  return typeof level === 'string' ? level : null
}

async function launchEffort($: EngineInterface): Promise<string | null> {
  try {
    const session = await $.process.run(['sh', '-c', 'ps -o args= -p "$PPID"'], { cwd: '/' })

    return EFFORT_FLAG.exec(session.stdout)?.[1] ?? null
  } catch {
    return null
  }
}

export async function liveEffort($: EngineInterface, model: string): Promise<string> {
  if (lastStepEffort !== null) {
    return lastStepEffort
  }
  const launched = isSetByCommand ? null : await launchEffort($)

  return launched ?? effortAt(await $.settings.read(), model) ?? DEFAULT_EFFORT
}

const forgetStep: Hook<'command.run'> = ($, e, next) => {
  lastStepEffort = null
  isSetByCommand = true

  return next(e)
}

export function trackEffort(on: On): void {
  on('turn.step', async function* ($, e, next) {
    if (e.agentId === undefined && typeof e.effort === 'string') {
      lastStepEffort = e.effort
    }

    return yield* next(e)
  })

  on('command.run', { command: 'effort' }, forgetStep)
  on('command.run', { command: 'model' }, forgetStep)
}
