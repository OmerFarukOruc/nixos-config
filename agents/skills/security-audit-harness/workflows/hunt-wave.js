export const meta = {
  name: 'security-audit-hunt-wave',
  description: 'Phase 2 hunter wave: one isolated hunter per ledger assignment, structured results',
  phases: [{ title: 'Hunt', detail: 'one hunter per assignment, parallel' }],
}
const A = typeof args === 'string' ? JSON.parse(args) : args
if (!Array.isArray(A.hunters) || A.hunters.length === 0) throw new Error('args.hunters must be a non-empty array')
if (!A.candidate_schema || !Array.isArray(A.candidate_schema.oneOf)) throw new Error('args.candidate_schema must come from wave.py')
const CHECK = {
  type: 'object',
  properties: {
    agent_id: { type: 'string' }, reviewed_paths: { type: 'array', items: { type: 'string' } },
    invariant: { type: 'string' }, method: { type: 'string', enum: ['source', 'local'] },
    result: { type: 'string' }, artifact: { type: ['string', 'null'] },
  },
  required: ['agent_id', 'reviewed_paths', 'invariant', 'method', 'result', 'artifact'],
}
const SCHEMA = {
  type: 'object',
  properties: {
    receipt: { type: 'string' },
    units: { type: 'array', items: { type: 'object', properties: {
      coverage_id: { type: 'string' }, disposition: { type: 'string', enum: ['covered', 'candidate', 'blocked'] },
      reviewed_paths: { type: 'array', items: { type: 'string' } }, checks: { type: 'array', items: CHECK },
      candidate_fingerprints: { type: 'array', items: { type: 'string' } }, unresolved: { type: 'array', items: { type: 'string' } },
    }, required: ['coverage_id', 'disposition', 'reviewed_paths', 'checks', 'candidate_fingerprints', 'unresolved'] } },
    candidates: { type: 'array', items: A.candidate_schema },
    hardening: { type: 'array', items: { type: 'string' } },
    uncovered: { type: 'array', items: { type: 'object', properties: {
      surface: { type: 'string' }, boundary: { type: 'string' }, subsystem: { type: 'string' }, attack_class: { type: 'string' },
      starting_paths: { type: 'array', items: { type: 'string' } }, reason: { type: 'string' },
    }, required: ['surface', 'boundary', 'subsystem', 'attack_class', 'starting_paths', 'reason'] } },
  },
  required: ['receipt', 'units', 'candidates', 'hardening', 'uncovered'],
}
phase('Hunt')
const results = await parallel(A.hunters.map(h => () => agent(
  `You are a security-audit hunter subagent, agent id ${h.id}. You are NOT the orchestrator and there are no sibling results for you to report.

Your complete assignment prompt is the trusted, parent-written file:
${h.prompt_path}

Before any other action, read that whole file with the Read tool (use offset and limit in chunks until you reach the end; it is about 100 KB). It contains your role, architecture.md, your assigned coverage units (${h.coverage_ids.length} of them), the verbatim attack-class blocks, exclusions, the hunting method, the promotion procedure, validation rules, peer-owned units, your scratch and sandbox paths, and the structured-result contract. Follow it exactly.

Return your final answer through the structured output tool: exactly one object with the fields receipt, units, candidates, hardening, uncovered as the contract in Part 9 defines. Every candidate object carries every field of its report-schema branch (with proposed_verdict instead of verdict). Also write the same JSON to the scratch result.json path named in Part 9.`,
  { label: h.id, phase: 'Hunt', schema: SCHEMA }).then(r => r ? { ...r, id: h.id } : null)))
const missing = A.hunters.map(h => h.id).filter(id => !results.some(r => r && r.id === id))
if (missing.length) log(`hunters without a result: ${missing.join(', ')}`)
const done = results.filter(Boolean)
return { wave: A.wave, done: done.map(r => r.id), missing, candidates: done.reduce((n, r) => n + r.candidates.length, 0) }
