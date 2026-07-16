import { renderPortableDocument } from "@barkpark/react";
import { PaperEditorMount } from "@/components/paper-editor-mount";
import type { Block } from "@/lib/papers";

/** Top-level PROSE block types the `bp-paper-editor` web component can host —
 * authoritative from the WC source (index.js StarterKit config + convert.js).
 * `code` is explicitly NOT prose; everything else stays server-rendered. */
const PROSE_TYPES = new Set(["paragraph", "heading", "list"]);

/**
 * Read-mode editor-aware paper embed — the web-local partner of the canonical
 * `@barkpark/react` `PortableDoc`. This is the ONE web-specific presentation
 * `PortableDoc` cannot express: a flag-gated (`NEXT_PUBLIC_PAPER_EDITOR=read`)
 * variant that mounts a read-only `<bp-paper-editor>` per top-level prose block
 * while server-rendering everything else, so the demo can showcase the live
 * TipTap editor chrome without shipping an edit bundle by default.
 *
 * It STAYS a Server Component (no "use client"): it partitions blocks in
 * document order and renders the NON-prose slots through the canonical
 * `renderPortableDocument([block])` string emitter — the exact `bp-*` markup the
 * Phoenix reader and the default `PortableDoc` produce — wrapped in a
 * `.bp-paper-surface` host so the shipped stylesheet skins them. The prose
 * blocks become `null` holes the client {@link PaperEditorMount} fills with one
 * `<bp-paper-editor>` each. The client child imports nothing from here, so the
 * bundle gains only the mount + the WC loader — never the renderer.
 *
 * This replaces the deleted `portable-doc.tsx` web fork's
 * `PaperEditorDoc`: same prose-partition contract, but the non-prose slots now
 * flow through the single canonical renderer instead of the retired fork.
 */
export function PaperEditorDoc({ blocks }: { blocks: Block[] }) {
  if (!blocks.length) {
    return (
      <p className="text-sm text-zinc-400 italic">This paper has no content.</p>
    );
  }
  const proseBlocks: Block[] = [];
  const slots = blocks.map((b, i) => {
    if (PROSE_TYPES.has(b.type)) {
      proseBlocks.push(b);
      return null; // hole — the client mount fills it with <bp-paper-editor>.
    }
    // Non-prose → canonical bp-* markup, server-rendered as an opaque slot. The
    // `.bp-paper-surface` host mirrors the wrapper `PortableDoc` adds, so the
    // shipped `paper-surface.css` skins the block identically to the default read.
    return (
      <div
        key={`np${i}`}
        className="bp-paper-surface"
        dangerouslySetInnerHTML={{ __html: renderPortableDocument([b]) }}
      />
    );
  });
  return <PaperEditorMount proseBlocks={proseBlocks} slots={slots} />;
}
