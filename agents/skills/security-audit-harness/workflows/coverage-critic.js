export const meta = {
  name: 'security-audit-coverage-critic',
  description: 'Fresh coverage critic over the ledger after a hunter wave',
  phases: [{ title: 'Critic' }],
}
const A = typeof args === 'string' ? JSON.parse(args) : args
if (!A.id || !A.prompt_path) throw new Error('args.id and args.prompt_path required')
const UNIT = { type: 'object', properties: {
  surface: { type: 'string' }, boundary: { type: 'string' }, subsystem: { type: 'string' }, attack_class: { type: 'string' },
  starting_paths: { type: 'array', items: { type: 'string' } },
  selected_companion_blocks: { type: 'array', items: { type: 'string' } },
  excluded_blocks: { type: 'array', items: { type: 'object', properties: { block: { type: 'string' }, reason: { type: 'string' } }, required: ['block', 'reason'] } },
  reason: { type: 'string' } }, required: ['surface', 'boundary', 'subsystem', 'attack_class', 'starting_paths', 'selected_companion_blocks', 'excluded_blocks', 'reason'] }
const SCHEMA = { type: 'object', properties: {
  missing_units: { type: 'array', items: UNIT },
  reassign_ids: { type: 'array', items: { type: 'string' } },
  reassign_reasons: { type: 'array', items: { type: 'string' } },
  resolved_prior_leads: { type: 'array', items: { type: 'string' } },
  unreviewed_without_unit: { type: 'array', items: { type: 'object', properties: { pattern: { type: 'string' }, reason: { type: 'string' } }, required: ['pattern', 'reason'] } },
  stop: { type: 'boolean' } }, required: ['missing_units', 'reassign_ids', 'reassign_reasons', 'resolved_prior_leads', 'unreviewed_without_unit', 'stop'] }
phase('Critic')
const r = await agent(`You are coverage critic ${A.id} for a defensive security audit. You are NOT the orchestrator. Your full, trusted, parent-written prompt is the file ${A.prompt_path}. Read the whole file first with the Read tool (in chunks until the end), then do exactly what it says. Return the result through the structured output tool.`, { label: A.id, phase: 'Critic', schema: SCHEMA })
return r
