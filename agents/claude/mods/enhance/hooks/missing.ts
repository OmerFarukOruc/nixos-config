const URL_TEXT = /https?:\/\/[^\s<>"'`)\]]+/g
const CODE_SPAN = /`([^`\n]+)`/g
const PATH =
  /(?<![\w./~+-])@?((?:~|\.{1,2})\/[\w.@+-]+(?:\/[\w.@+-]+)*|\/[\w.@+-]+(?:\/[\w.@+-]+)+|[\w.@+-]+(?:\/[\w.@+-]+)+\.\w+|[\w+-]*[A-Za-z][\w+-]+\.[A-Za-z]{1,5}(?![\w.]))/g
const TRAILING_MARKS = /[.,;:!?]+$/
const REGEXP_MARKS = /[.*+?^${}()|[\]\\]/g

function holdsPath(prompt: string, path: string): boolean {
  return new RegExp(`${path.replace(REGEXP_MARKS, '\\$&')}(?![\\w-]|\\.\\w)`).test(prompt)
}

export function missingFrom(draft: string, prompt: string): string[] {
  const urls = [...draft.matchAll(URL_TEXT)].map(found => found[0].replace(TRAILING_MARKS, ''))
  const withoutUrls = draft.replace(URL_TEXT, ' ')
  const spans = [...withoutUrls.matchAll(CODE_SPAN)].flatMap(found => found[1] ?? [])
  const paths = [...withoutUrls.replace(CODE_SPAN, ' ').matchAll(PATH)].map(found => (found[1] ?? '').replace(TRAILING_MARKS, ''))

  return [...new Set([...urls, ...spans].filter(item => !prompt.includes(item))), ...new Set(paths.filter(path => !holdsPath(prompt, path)))]
}
