type Cause = { text: RegExp; say: (found: RegExpExecArray, model: string) => string }

const CAUSES: readonly Cause[] = [
  {
    text: /There's an issue with the selected model/,
    say: (_, model) => `the writer model ${model} does not exist, or this account cannot use it; set Writer model in /config`,
  },
  {
    text: /You've hit your (\w+) limit(?: · (resets [^\n)]+))?/,
    say: found =>
      `the account's ${found[1] ?? 'usage'} limit is reached${found[2] === undefined ? '' : ` (${found[2].trim()})`}; wait for the reset, or set another Writer model in /config`,
  },
  {
    text: /can't help with this\. Start a new session|appears to violate our Usage Policy/,
    say: () => 'the model refused; retrying will not help. Change the draft, or run it from a new session',
  },
]

export function plainCause(reason: string, model: string): string | null {
  for (const cause of CAUSES) {
    const found = cause.text.exec(reason)
    if (found !== null) {
      return cause.say(found, model)
    }
  }

  return null
}
