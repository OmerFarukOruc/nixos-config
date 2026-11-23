const URL_TEXT = /https?:\/\/[^\s<>"'`)\]]+/g
const CODE_SPAN = /`([^`\n]+)`/g
const PATH = /(?<![\w./~@+-])(?:(?:~|\.{1,2})\/[\w.@+-]+(?:\/[\w.@+-]+)*|\/[\w.@+-]+(?:\/[\w.@+-]+)+|[\w.@+-]+(?:\/[\w.@+-]+)+\.\w+)/g
const TRAILING_MARKS = /[.,;:!?]+$/

export function missingFrom(draft: string, prompt: string): string[] {
  const urls = [...draft.matchAll(URL_TEXT)].map(found => found[0].replace(TRAILING_MARKS, ''))
  const withoutUrls = draft.replace(URL_TEXT, ' ')
  const spans = [...withoutUrls.matchAll(CODE_SPAN)].flatMap(found => found[1] ?? [])
  const paths = [...withoutUrls.replace(CODE_SPAN, ' ').matchAll(PATH)].map(found => found[0].replace(TRAILING_MARKS, ''))

  return [...new Set([...urls, ...spans, ...paths])].filter(item => !prompt.includes(item))
}
