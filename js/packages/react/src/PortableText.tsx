'use client'

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

import { createElement, Fragment } from 'react'
import type { ComponentType, ReactElement, ReactNode } from 'react'

/** A single inline text run within a {@link PortableTextBlock}. */
export interface PortableTextSpan {
  _type: 'span'
  _key?: string
  text: string
  /** Mark keys — may be either a built-in style (e.g. `'strong'`) or a {@link PortableTextMarkDef} key. */
  marks?: string[]
}

/**
 * Definition for a custom mark (e.g. a link). Referenced by `span.marks`
 * via `_key`; the concrete mark type + attributes live on this record.
 */
export interface PortableTextMarkDef {
  _type: string
  _key: string
  [k: string]: unknown
}

/**
 * A block-level node. Standard styles (`normal`, `h1`…`h6`, `blockquote`) map
 * to default HTML tags; override via {@link PortableTextComponents}.`block`.
 */
export interface PortableTextBlock {
  _type: 'block'
  _key?: string
  style?: string
  children: PortableTextSpan[]
  markDefs?: PortableTextMarkDef[]
  listItem?: 'bullet' | 'number'
  level?: number
}

/** Any non-`'block'` node — rendered via {@link PortableTextComponents}.`types`. */
export interface CustomBlock {
  _type: string
  _key?: string
  [k: string]: unknown
}

export type PortableTextNode = PortableTextBlock | CustomBlock

/**
 * Component overrides for {@link PortableText}. Each section is optional; any
 * node/mark type without a matching component falls back to `unknownBlockStyle`
 * / `unknownMark` / `unknownType`, or a default HTML tag.
 */
export interface PortableTextComponents {
  block?: Partial<Record<string, ComponentType<{ children: ReactNode; value: PortableTextBlock }>>>
  mark?: Partial<Record<string, ComponentType<{ children: ReactNode; value?: unknown; markType: string }>>>
  types?: Partial<Record<string, ComponentType<{ value: CustomBlock }>>>
  list?: Partial<Record<'bullet' | 'number', ComponentType<{ children: ReactNode }>>>
  listItem?: Partial<Record<'bullet' | 'number', ComponentType<{ children: ReactNode; value: PortableTextBlock }>>>
  unknownMark?: ComponentType<{ children: ReactNode; markType: string }>
  unknownBlockStyle?: ComponentType<{ children: ReactNode; value: PortableTextBlock }>
  unknownType?: ComponentType<{ value: CustomBlock }>
}

/** Props for {@link PortableText}. */
export interface PortableTextProps {
  /** A single Portable Text node or an array of them. */
  value: PortableTextNode[] | PortableTextNode
  /** Component overrides for blocks, marks, lists, and custom types. */
  components?: PortableTextComponents
  /** Called once per unknown block style / mark type / custom `_type` encountered during render. */
  onMissingComponent?: (nodeOrMark: { _type: string; markType?: string }) => void
}

type Miss = (n: { _type: string; markType?: string }) => void

const BLOCK_TAGS: Record<string, string> = {
  normal: 'p',
  h1: 'h1',
  h2: 'h2',
  h3: 'h3',
  h4: 'h4',
  h5: 'h5',
  h6: 'h6',
  blockquote: 'blockquote',
}

const MARK_TAGS: Record<string, string> = {
  strong: 'strong',
  em: 'em',
  code: 'code',
  underline: 'u',
  'strike-through': 's',
}

function findDef(defs: PortableTextMarkDef[] | undefined, key: string): PortableTextMarkDef | undefined {
  if (!defs) return undefined
  for (let i = 0; i < defs.length; i++) {
    const d = defs[i]
    if (d && d._key === key) return d
  }
  return undefined
}

function renderSpan(
  span: PortableTextSpan,
  block: PortableTextBlock,
  components: PortableTextComponents,
  miss: Miss | undefined,
  idx: number,
): ReactNode {
  let node: ReactNode = span.text
  const marks = span.marks
  if (marks && marks.length) {
    for (let i = marks.length - 1; i >= 0; i--) {
      const m = marks[i]
      if (!m) continue
      const def = findDef(block.markDefs, m)
      const markType = def ? def._type : m
      const userC = components.mark && components.mark[markType]
      const tag = MARK_TAGS[markType]
      if (userC) {
        node = createElement(userC, { value: def, markType, children: node })
      } else if (tag) {
        node = createElement(tag, null, node)
      } else if (components.unknownMark) {
        if (miss) miss({ _type: markType, markType })
        node = createElement(components.unknownMark, { markType, children: node })
      } else {
        if (miss) miss({ _type: markType, markType })
      }
    }
  }
  return createElement(Fragment, { key: span._key ?? idx }, node)
}

function renderChildren(
  block: PortableTextBlock,
  components: PortableTextComponents,
  miss: Miss | undefined,
): ReactNode[] {
  return block.children.map((s, i) => renderSpan(s, block, components, miss, i))
}

function renderBlock(
  node: PortableTextBlock,
  components: PortableTextComponents,
  miss: Miss | undefined,
  idx: number,
): ReactElement {
  const style = node.style ?? 'normal'
  const key = node._key ?? String(idx)
  const children = renderChildren(node, components, miss)
  const userC = components.block && components.block[style]
  if (userC) return createElement(userC, { value: node, key, children })
  const tag = BLOCK_TAGS[style]
  if (tag) return createElement(tag, { key }, children)
  if (miss) miss({ _type: style })
  const fallback = components.unknownBlockStyle
  if (fallback) return createElement(fallback, { value: node, key, children })
  return createElement('p', { key }, children)
}

function renderListItem(
  node: PortableTextBlock,
  components: PortableTextComponents,
  miss: Miss | undefined,
  idx: number,
): ReactElement {
  const listType = node.listItem as 'bullet' | 'number'
  const key = node._key ?? String(idx)
  const children = renderChildren(node, components, miss)
  const userC = components.listItem && components.listItem[listType]
  if (userC) return createElement(userC, { value: node, key, children })
  return createElement('li', { key }, children)
}

function renderList(
  items: ReactElement[],
  listType: 'bullet' | 'number',
  components: PortableTextComponents,
  key: string,
): ReactElement {
  const userC = components.list && components.list[listType]
  if (userC) return createElement(userC, { key, children: items })
  return createElement(listType === 'bullet' ? 'ul' : 'ol', { key }, items)
}

function renderType(
  node: CustomBlock,
  components: PortableTextComponents,
  miss: Miss | undefined,
  idx: number,
): ReactElement | null {
  const key = node._key ?? String(idx)
  const userC = components.types && components.types[node._type]
  if (userC) return createElement(userC, { value: node, key })
  if (miss) miss({ _type: node._type })
  if (components.unknownType) return createElement(components.unknownType, { value: node, key })
  return null
}

/**
 * Renders a Portable Text value to React elements.
 *
 * Consecutive `block` nodes with the same `listItem` value are grouped into
 * a single `<ul>` / `<ol>`. Unknown block styles, mark types, and custom
 * `_type`s fall back to optional `unknownBlockStyle` / `unknownMark` /
 * `unknownType` components, or sensible default HTML.
 *
 * @param props — {@link PortableTextProps}
 * @returns A React fragment wrapping the rendered nodes.
 *
 * @example
 * import { PortableText } from '@barkpark/react'
 *
 * <PortableText
 *   value={post.body}
 *   components={{
 *     mark: {
 *       link: ({ value, children }) => (
 *         <a href={(value as { href: string }).href}>{children}</a>
 *       ),
 *     },
 *     types: {
 *       image: ({ value }) => <img src={(value as { url: string }).url} />,
 *     },
 *   }}
 * />
 */
export function PortableText(props: PortableTextProps): ReactElement {
  const value = Array.isArray(props.value) ? props.value : [props.value]
  const components = props.components ?? {}
  const miss = props.onMissingComponent
  const out: ReactElement[] = []
  let i = 0
  while (i < value.length) {
    const node = value[i]
    if (!node) {
      i++
      continue
    }
    if (node._type !== 'block') {
      const r = renderType(node as CustomBlock, components, miss, i)
      if (r) out.push(r)
      i++
      continue
    }
    const blk = node as PortableTextBlock
    if (blk.listItem) {
      const listType = blk.listItem
      const items: ReactElement[] = []
      const startKey = blk._key ?? String(i)
      while (i < value.length) {
        const n = value[i]
        if (!n || n._type !== 'block' || (n as PortableTextBlock).listItem !== listType) break
        items.push(renderListItem(n as PortableTextBlock, components, miss, i))
        i++
      }
      out.push(renderList(items, listType, components, startKey))
      continue
    }
    out.push(renderBlock(blk, components, miss, i))
    i++
  }
  return createElement(Fragment, null, out)
}
