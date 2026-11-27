const URL_TEXT = /https?:\/\/[^\s<>"'`)\]]+/g
const CODE_SPAN = /`([^`\n]+)`/g
const PATH =
  /(?<![\w./~+-])@?((?:~|\.{1,2})\/[\w.@+-]+(?:\/[\w.@+-]+)*|\/[\w.@+-]+(?:\/[\w.@+-]+)+|[\w.@+-]+(?:\/[\w.@+-]+)+\.\w+|[\w+-]*[A-Za-z][\w+-]+\.[A-Za-z]{1,5}(?![\w.]))/g
const TRAILING_MARKS = /[.,;:!?]+$/
const REGEXP_MARKS = /[.*+?^${}()|[\]\\]/g
const CURRENT_FOLDER = /^(?:\.\/)+/
const LISTED_AT_MOST = 5
const NAMED_IN_COUNT = 3

function holdsPath(prompt: string, path: string): boolean {
  return new RegExp(`${path.replace(CURRENT_FOLDER, '').replace(REGEXP_MARKS, '\\$&')}(?![\\w-]|\\.\\w)`).test(prompt)
}

function blanked(text: string, pattern: RegExp): string {
  return text.replace(pattern, found => ' '.repeat(found.length))
}

function missingFrom(draft: string, prompt: string): string[] {
  const withoutUrls = blanked(draft, URL_TEXT)
  const urls = [...draft.matchAll(URL_TEXT)].map(found => ({ item: found[0].replace(TRAILING_MARKS, ''), at: found.index }))
  const spans = [...withoutUrls.matchAll(CODE_SPAN)].map(found => ({ item: found[1] ?? '', at: found.index }))
  const paths = [...blanked(withoutUrls, CODE_SPAN).matchAll(PATH)].map(found => ({ item: (found[1] ?? '').replace(TRAILING_MARKS, ''), at: found.index }))
  const missing = [...[...urls, ...spans].filter(named => !prompt.includes(named.item)), ...paths.filter(named => !holdsPath(prompt, named.item))]

  return [...new Set(missing.sort((a, b) => a.at - b.at).map(named => named.item))]
}

export function missingNotes(draft: string, prompt: string): string[] {
  const missing = missingFrom(draft, prompt)
  if (missing.length <= LISTED_AT_MOST) {
    return missing.map(item => `Not in the prompt: ${item}`)
  }

  return [`Not in the prompt: ${missing.length} paths, URLs and code spans of the draft, such as ${missing.slice(0, NAMED_IN_COUNT).join(', ')}`]
}
