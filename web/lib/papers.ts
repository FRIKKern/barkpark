import type { BarkparkClient, BarkparkDocument } from "@barkpark/core";

/**
 * Inline content node (PortableDoc). Mirrors `Barkpark.PortableDoc.Render`'s
 * inline model: a `text` leaf (optionally carrying ProseMirror-style `marks`),
 * the `strong`/`em`/`code`/`link` wrappers, or a bare string/number.
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
  | { type: "code"; value?: string }
  | { type: "link"; href?: string; children?: Inline[] };

/** A PortableDoc block. Loosely typed — `type` drives rendering, attrs vary. */
export interface Block {
  id?: string;
  type: string;
  [attr: string]: unknown;
}

export interface PaperDocument extends BarkparkDocument {
  title?: string;
  slug?: string;
  /** Canonical block array (also mirrored under `body.blocks`). */
  blocks?: Block[];
  body?: { blocks?: Block[] };
}

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

/** First paragraph's plain text — used as a listing excerpt. */
export function paperExcerpt(paper: PaperDocument): string | null {
  const para = paperBlocks(paper).find((b) => b.type === "paragraph");
  const content = para?.content;
  if (!Array.isArray(content)) return null;
  const text = content
    .map((n) =>
      typeof n === "string"
        ? n
        : n && typeof n === "object" && "value" in n
          ? String((n as { value?: unknown }).value ?? "")
          : "",
    )
    .join("")
    .trim();
  return text.length > 0 ? text : null;
}

/** Listing query — papers, newest first. Scope rides on the client. */
export async function fetchPapers(
  client: BarkparkClient,
): Promise<PaperDocument[]> {
  return client
    .docs<PaperDocument>("paper")
    .order("_updatedAt:desc")
    .limit(50)
    .find();
}

/** Single paper by slug (or id) — same fallback shape as posts. */
export async function fetchPaperBySlug(
  client: BarkparkClient,
  slug: string,
): Promise<PaperDocument | null> {
  const bySlug = await client
    .docs<PaperDocument>("paper")
    .where("slug", "eq", slug)
    .findOne();
  if (bySlug) return bySlug;
  return client.doc<PaperDocument>("paper", slug);
}
