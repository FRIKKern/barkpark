import {
  typedClient,
  type BarkparkClient,
  type BarkparkDocument,
} from "@barkpark/core";
import type { Paper, BarkparkTypeMap } from "./barkpark.types";
import { inlineText } from "./find.ts";

/**
 * Inline content node (PortableDoc). Mirrors `Barkpark.PortableDoc.Render`'s
 * inline model: a `text` leaf (optionally carrying ProseMirror-style `marks`),
 * the `strong`/`em`/`strikethrough`/`underline`/`code`/`link` wrappers, or a
 * bare string/number.
 */
export type Inline =
  | string
  | number
  | {
      type: "text";
      value?: string;
      marks?: Array<string | { type: string; href?: string }>;
    }
  | { type: "strong"; children?: Inline[] }
  | { type: "em"; children?: Inline[] }
  | { type: "strikethrough"; children?: Inline[] }
  | { type: "strike"; children?: Inline[] }
  | { type: "s"; children?: Inline[] }
  | { type: "underline"; children?: Inline[] }
  | { type: "code"; value?: string }
  | { type: "link"; href?: string; children?: Inline[] }
  | { type: "wikilink"; target?: string; alias?: string; children?: Inline[] }
  | { type: "blockref"; target?: string; anchor?: string }
  | { type: "tag"; name?: string };

/** A PortableDoc block. Loosely typed — `type` drives rendering, attrs vary. */
export interface Block {
  id?: string;
  type: string;
  [attr: string]: unknown;
}

/**
 * The shape of a `paper` document as this demo reader consumes it.
 *
 * Base is the generated {@link Paper} interface (emitted by `barkpark generate`
 * from the production schema — the single source of truth for `title` and the
 * other declared fields). The old hand-written `PaperDocument` that duplicated
 * `title` (and would drift) is DELETED; this alias derives from the generated
 * type instead.
 *
 * The PortableDoc presentation deltas the demo reader needs — `slug`, the
 * top-level `blocks` array, the `body.blocks` mirror, and Obsidian `tags` —
 * are not in the production schema, so they are added here. `_publishedId` +
 * system fields come from {@link BarkparkDocument} (the open envelope core
 * returns), which the generated `BarkparkSystemFields` deliberately omits.
 */
export type PaperDocument = Paper &
  BarkparkDocument & {
    slug?: string;
    /** Canonical block array (also mirrored under `body.blocks`). */
    blocks?: Block[];
    body?: { blocks?: Block[] };
    /** Content tags (Obsidian #tags). The envelope spreads `content` to the top
     * level, so these surface here; consumed by the /tags/[tag] route. */
    tags?: string[];
  };

/** Blocks live at top-level `blocks`, with `body.blocks` as a mirror fallback. */
export function paperBlocks(paper: PaperDocument): Block[] {
  if (Array.isArray(paper.blocks)) return paper.blocks;
  if (Array.isArray(paper.body?.blocks)) return paper.body!.blocks!;
  return [];
}

export function paperSlug(paper: PaperDocument): string {
  return paper.slug ?? paper._publishedId ?? paper._id;
}

/** Title: explicit field, else the first heading's text, else untitled. */
export function paperTitle(paper: PaperDocument): string {
  if (paper.title) return paper.title;
  const heading = paperBlocks(paper).find((b) => b.type === "heading");
  const text = heading?.text;
  return typeof text === "string" && text.length > 0 ? text : "(untitled)";
}

/** First paragraph's plain text — used as a listing excerpt. Descends into
 * marked-up wrapper runs (bold/link/em) via {@link inlineText}, so an excerpt
 * isn't truncated (or emptied) when the paragraph opens with a styled run. */
export function paperExcerpt(paper: PaperDocument): string | null {
  const para = paperBlocks(paper).find((b) => b.type === "paragraph");
  const text = inlineText(para?.content);
  return text.length > 0 ? text : null;
}

/** Listing query — papers, newest first. Scope rides on the client. */
export async function fetchPapers(
  client: BarkparkClient,
): Promise<PaperDocument[]> {
  // `typedClient<BarkparkTypeMap>` narrows `docs("paper")` to the generated
  // `Paper`; cast to the demo's wider `PaperDocument` view at the boundary.
  return typedClient<BarkparkTypeMap>(client)
    .docs("paper")
    .order("_updatedAt:desc")
    .limit(50)
    .find() as Promise<PaperDocument[]>;
}

/** Single paper by slug (or id) — same fallback shape as posts. */
export async function fetchPaperBySlug(
  client: BarkparkClient,
  slug: string,
): Promise<PaperDocument | null> {
  const bp = typedClient<BarkparkTypeMap>(client);
  const bySlug = (await bp
    .docs("paper")
    .where("slug", "eq", slug)
    .findOne()) as PaperDocument | null;
  if (bySlug) return bySlug;
  return bp.doc("paper", slug) as Promise<PaperDocument | null>;
}
