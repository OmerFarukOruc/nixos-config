import type { EngineInterface, Register, RenderSurface } from 'claude-code'

type PasteBlock = { kind: 'paste'; title: string; body: string }

type Part = { kind: 'prose'; text: string } | PasteBlock

const FENCE_OPEN = /^(`{3,}|~{3,})(.*)$/
const PASTE_INFO = /^paste(?:[ \t]+(.*))?$/

function opensFence(line: string): { fence: string; info: string } | null {
  const open = FENCE_OPEN.exec(line)
  if (open === null) {
    return null
  }

  const fence = open[1] ?? ''
  const info = open[2] ?? ''
  if (fence.startsWith('`') && info.includes('`')) {
    return null
  }

  return { fence, info: info.trim() }
}

function closerOf(fence: string): RegExp {
  return new RegExp(`^ {0,3}${fence.charAt(0)}{${fence.length},}[ \\t]*$`)
}

function splitPasteBlocks(text: string): Part[] {
  const lines = text.split(/\r\n?|\n/)
  const parts: Part[] = []
  let prose: string[] = []
  let i = 0

  const flushProse = () => {
    if (prose.join('').trim() !== '') {
      parts.push({ kind: 'prose', text: prose.join('\n') })
    }
    prose = []
  }

  while (i < lines.length) {
    const line = lines[i] ?? ''
    const open = opensFence(line)

    if (open === null) {
      prose.push(line)
      i += 1
      continue
    }

    const closer = closerOf(open.fence)
    let end = i + 1
    while (end < lines.length && !closer.test(lines[end] ?? '')) {
      end += 1
    }

    const paste = PASTE_INFO.exec(open.info)
    if (paste === null) {
      prose.push(...lines.slice(i, end + 1))
    } else {
      flushProse()
      parts.push({ kind: 'paste', title: (paste[1] ?? '').trim(), body: lines.slice(i + 1, end).join('\n') })
    }
    i = end + 1
  }

  flushProse()
  return parts
}

async function copyPaste($: EngineInterface, block: PasteBlock, surface: RenderSurface) {
  const name = block.title === '' ? 'paste block' : block.title

  try {
    const result = await $.ui.copy({ text: block.body, surface })
    $.ui.toast(result.isCopied ? `Copied ${name}` : `Could not copy ${name}: ${result.reason}`)
  } catch (error) {
    $.ui.toast(`Could not copy ${name}: ${error instanceof Error ? error.message : String(error)}`)
  }
}

export const register: Register = on => {
  on('ui.render', { component: 'AssistantMessage' }, ($, e, next) => {
    if (e.props.isSummary === true) {
      return next(e)
    }

    const parts = splitPasteBlocks(e.props.text)
    if (!parts.some(part => part.kind === 'paste')) {
      return next(e)
    }

    const { Box, Button, Markdown, Text } = $.ui.resolve(e)

    return (
      <Box flexDirection="column">
        {parts.map((part, index) =>
          part.kind === 'prose' ? (
            <Markdown text={part.text} />
          ) : (
            <Box flexDirection="column" borderStyle="round" borderColor="suggestion" paddingX={1} marginY={1}>
              <Box flexDirection="row" justifyContent="space-between">
                <Text bold color="suggestion">
                  {part.title === '' ? 'Paste' : part.title}
                </Text>
                <Button
                  key={`copy-${index}`}
                  label="Copy"
                  variant="primary"
                  onPress={press => copyPaste($, part, press.surface)}
                />
              </Box>
              <Text>{part.body}</Text>
            </Box>
          ),
        )}
      </Box>
    )
  })
}
