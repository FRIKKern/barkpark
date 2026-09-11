import { type Block, asList, isMap } from './inline'

// Only list blocks occupy this slot; other child metadata stays opaque.
export function listChildren(item: unknown): Block[] {
  if (!isMap(item)) return []
  return asList(item.children).filter(
    (child): child is Block =>
      isMap(child) &&
      Array.isArray(child.items) &&
      [
        'list',
        'bulletList',
        'bullet_list',
        'bulleted-list',
        'bulleted_list',
        'ordered-list',
        'numbered_list',
      ].includes(child.type as string),
  )
}
