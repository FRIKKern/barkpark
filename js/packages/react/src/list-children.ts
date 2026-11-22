import { type Block, asList, isMap } from './inline'

// Marks the notice block that stands in for a block past the depth limit
// (blocks/depth.ts capDepth), so a list item keeps it. JSON can't carry a
// Symbol: a stored child with "capped": true is still dropped.
// task-a6a57717506de979; Elixir render/block_depth.ex holds the same rule.
export const CAPPED = Symbol()

// Only list blocks, and the notice block, occupy this slot; other child metadata stays opaque.
export function listChildren(item: unknown): Block[] {
  if (!isMap(item)) return []
  return asList(item.children).filter(
    (child): child is Block =>
      isMap(child) &&
      (CAPPED in child ||
        (Array.isArray(child.items) &&
          [
            'list',
            'bulletList',
            'bullet_list',
            'bulleted-list',
            'bulleted_list',
            'ordered-list',
            'numbered_list',
          ].includes(child.type as string))),
  )
}
