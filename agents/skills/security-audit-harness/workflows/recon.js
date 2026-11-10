export const meta = {
  name: 'security-audit-recon',
  description: 'Phase 1 reconnaissance: one read-only research agent per recon task',
  phases: [{ title: 'Recon', detail: 'parallel read-only research agents' }],
}
const A = typeof args === 'string' ? JSON.parse(args) : args
if (!Array.isArray(A.agents) || A.agents.length === 0) throw new Error('args.agents must be a non-empty array')
for (const k of ['target', 'commit', 'out']) if (!A[k]) throw new Error(`args.${k} is required`)
const SCHEMA = {
  type: 'object',
  properties: {
    report: { type: 'string', description: 'Markdown answer to every numbered item, each fact with repository-relative file:line references' },
    open_questions: { type: 'array', items: { type: 'string' } },
  },
  required: ['report', 'open_questions'],
}
phase('Recon')
const results = await parallel(A.agents.map(a => () => {
  const prompt = `You are a reconnaissance research agent for a defensive security audit. You are NOT the orchestrator; do only the task below and return its result.

Agent id: ${a.id}
Target repository (read-only): ${A.target} at commit ${A.commit} (clean tree).
Your only writable path: ${A.out}/agents/${a.id}/scratch/

Rules:
- Read source only (Read, Grep, Glob, git show/log, cat, sed). Do not run builds, tests, gradlew, docker, npm, python scripts from the target, or any target-controlled code. Do not use network access, do not contact any deployed endpoint, provider, registry, Infisical, Cloudflare, Stripe, Cognito, SES, or GitHub API.
- Do not edit the target or any file outside your scratch directory.
- Before returning, write a copy of your final JSON result to ${A.out}/agents/${a.id}/scratch/result.json with a Bash here-doc (the Write tool refuses this path for subagents; that is expected).
- Be complete and source-grounded. Every fact needs a repository-relative path:line reference. Mark anything not visible in source as "not source-visible".

Task:
${a.task}`
  return agent(prompt, { label: a.id, phase: 'Recon', schema: SCHEMA }).then(r => r ? { ...r, id: a.id } : null)
}))
const missing = A.agents.map(a => a.id).filter(id => !results.some(r => r && r.id === id))
if (missing.length) log(`missing recon results: ${missing.join(', ')}`)
return { done: results.filter(Boolean).map(r => r.id), missing }
