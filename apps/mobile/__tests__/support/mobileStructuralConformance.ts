import type { ReactElement, ReactNode } from 'react'

interface Golden {
  type: string
  input: Record<string, unknown>
}

interface Projection {
  text: string
  styles: Record<string, unknown>[]
  images: { uri?: string; accessibilityLabel?: string }[]
  presses: number
}

export interface NativeStructureVerdict {
  diff: string[]
  via: 'native-structure'
}

function isElement(node: unknown): node is ReactElement {
  return !!node && typeof node === 'object' && 'props' in (node as object) && '$$typeof' in (node as object)
}

function typeName(type: unknown): string {
  if (typeof type === 'string') return type
  if (typeof type === 'function') {
    const candidate = type as { displayName?: string; name: string }
    return candidate.displayName ?? candidate.name
  }
  if (type !== null && typeof type === 'object') {
    const candidate = type as { displayName?: string; render?: { name?: string } }
    return candidate.displayName ?? candidate.render?.name ?? ''
  }
  return ''
}

function walk(node: ReactNode, projection: Projection): void {
  if (node === null || node === undefined || typeof node === 'boolean') return
  if (typeof node === 'string' || typeof node === 'number') {
    projection.text += String(node)
    return
  }
  if (Array.isArray(node)) {
    for (const child of node) walk(child as ReactNode, projection)
    return
  }
  if (!isElement(node)) return

  const props = node.props as Record<string, unknown>
  const rawStyle = props.style
  if (rawStyle !== undefined) {
    const parts = Array.isArray(rawStyle) ? rawStyle : [rawStyle]
    projection.styles.push(Object.assign({}, ...parts.filter(Boolean)) as Record<string, unknown>)
  }
  if (typeName(node.type) === 'Image') {
    projection.images.push({
      uri: (props.source as { uri?: string } | undefined)?.uri,
      accessibilityLabel: typeof props.accessibilityLabel === 'string' ? props.accessibilityLabel : undefined,
    })
  }
  if (typeof props.onPress === 'function') projection.presses += 1
  walk(props.children as ReactNode, projection)
}

function project(node: ReactNode): Projection {
  const projection: Projection = { text: '', styles: [], images: [], presses: 0 }
  walk(node, projection)
  return projection
}

function expectEqual(diff: string[], name: string, actual: unknown, expected: unknown): void {
  if (actual !== expected) diff.push(`${name}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`)
}

/**
 * Structural adjudication for the three canonical goldens whose DOM shapes
 * contain no author words. This is deliberately separate from the mobile
 * report's text comparator until its report update is coordinated.
 */
export function mobileStructuralVerdict(golden: Golden, output: ReactNode): NativeStructureVerdict | undefined {
  if (!['divider', 'image', 'video'].includes(golden.type)) return undefined

  const actual = project(output)
  const diff: string[] = []

  if (golden.type === 'divider') {
    if (!actual.styles.some((style) => style.height === 1 && style.alignSelf === 'stretch')) {
      diff.push('divider: missing visible 1px stretched rule')
    }
    expectEqual(diff, 'divider mark', actual.text, '§')
  }

  if (golden.type === 'image') {
    expectEqual(diff, 'image count', actual.images.length, 1)
    expectEqual(diff, 'image src', actual.images[0]?.uri, golden.input.src)
    expectEqual(diff, 'image accessible name', actual.images[0]?.accessibilityLabel, golden.input.alt)
    const width = typeof golden.input.width === 'number' ? golden.input.width : undefined
    const height = typeof golden.input.height === 'number' ? golden.input.height : undefined
    const ratio = width !== undefined && height !== undefined ? width / height : 16 / 9
    if (!actual.styles.some((style) => style.width === '100%' && style.aspectRatio === ratio)) {
      diff.push(`image ratio: no full-width ${ratio} image style`)
    }
  }

  if (golden.type === 'video') {
    const captions = Array.isArray(golden.input.captions)
      ? golden.input.captions.filter((caption) => !!caption && typeof caption === 'object').length
      : 0
    const trackLabel = `${captions} caption track${captions === 1 ? '' : 's'}`
    if (!actual.text.includes('▶ Video')) diff.push('video: missing honest degrade label')
    if (captions > 0 && !actual.text.includes(trackLabel)) diff.push(`video: missing ${trackLabel}`)
    if (!actual.text.includes('open in browser')) diff.push('video: missing handoff label')
    expectEqual(diff, 'video poster count', actual.images.length, 1)
    expectEqual(diff, 'video poster', actual.images[0]?.uri, golden.input.poster)
    expectEqual(diff, 'video handoff count', actual.presses, 1)
  }

  return { diff, via: 'native-structure' }
}
