export const meta = {
  name: 'security-audit-verify',
  description: 'Phase 3 and 5 verifiers: one fresh refuting verifier per assignment, structured verdicts',
  phases: [{ title: 'Verify', detail: 'one fresh verifier per fingerprint or record, parallel' }],
}
const A = typeof args === 'string' ? JSON.parse(args) : args
if (!Array.isArray(A.verifiers) || A.verifiers.length === 0) throw new Error('args.verifiers must be a non-empty array')
const SCHEMA = {
  type: 'object',
  properties: {
    decision: { type: 'string', enum: ['confirmed', 'needs_validation', 'rejected'] },
    record: { type: 'object' },
    artifacts: { type: 'array', items: { type: 'string' } },
  },
  required: ['decision', 'record', 'artifacts'],
}
phase('Verify')
const results = await parallel(A.verifiers.map(v => () => agent(
  `You are a security-audit verifier subagent, agent id ${v.id}. You are NOT the orchestrator, you did not find this candidate, and there are no sibling results for you to report. Your job is to try to refute it.

Your complete assignment prompt is the trusted, parent-written file:
${v.prompt_path}

Before any other action, read that whole file with the Read tool (use offset and limit in chunks until you reach the end). It contains your role, architecture.md, the candidate records, the linked coverage units, the verbatim validation and promotion rules, your scratch and sandbox paths, the three schema branches, and the return contract. Follow it exactly.

Return your final answer through the structured output tool: exactly one object {decision, record, artifacts} as the Return section defines. Also write the same JSON to the scratch result.json path named in the file.`,
  { label: v.id, phase: 'Verify', schema: SCHEMA }).then(r => r ? { ...r, id: v.id } : null)))
const missing = A.verifiers.map(v => v.id).filter(id => !results.some(r => r && r.id === id))
if (missing.length) log(`verifiers without a result: ${missing.join(', ')}`)
const done = results.filter(Boolean)
return { done: done.map(r => r.id), missing, decisions: Object.fromEntries(done.map(r => [r.id, r.decision])) }
