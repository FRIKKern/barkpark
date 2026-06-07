/**
 * Typed PortableDoc block union + constructors.
 *
 * Field names mirror EXACTLY what `Barkpark.PortableDoc.Render.compose_block/2`
 * reads (api/lib/barkpark/portable_doc/render.ex) — they are not invented:
 *
 *   heading   -> { level, text }              (compose_block %{"type"=>"heading"})
 *   paragraph -> { content: Inline[] }        (reads Map.get(b,"content"))
 *   ingress   -> { content: Inline[] }
 *   pullquote -> { content: Inline[] }
 *   eyebrow   -> { text }
 *   byline    -> { items[] | text }
 *   list      -> { ordered, items: Inline[][] }(each item is an inline-node array)
 *   callout   -> { tone, title?, content: Inline[] }
 *   action    -> { href, label, priority? }
 *   code      -> { value }                    (NOT lang/code — the renderer reads "value")
 *   diagram   -> { source, caption? }         (NOT "mermaid" — the renderer reads "source")
 *   asciicast -> { src, caption? }
 *   image     -> { src, alt, width?, height? }
 *   table     -> { head?, rows }
 *   divider   -> {}
 *
 * Every block carries a unique string `id` (the ingest + patch contract keys
 * blocks by id; patch.ex resolves ops against `block_id` = `Map.get(block,"id")`).
 * When the author omits `id`, a DETERMINISTIC id ("b1","b2",…) is minted from a
 * monotonic counter — no Date.now()/random, so output is byte-reproducible.
 */

// ── deterministic id minting ───────────────────────────────────────────────

let __counter = 0;

/** Reset the monotonic id counter. Tests call this for reproducible output. */
export function resetBlockIds(): void {
  __counter = 0;
}

/** Mint the next deterministic block id: "b1", "b2", … */
export function nextBlockId(): string {
  __counter += 1;
  return `b${__counter}`;
}

function withId(id: string | undefined): string {
  return id ?? nextBlockId();
}

// ── inline node types (ProseMirror-ish, per compose_inline/2) ──────────────
//
// compose_inline tolerates bare strings/numbers as text leaves, so the SDK's
// `Inline` accepts a plain string for the common case and the structured node
// shapes for marks/links/code.

export interface InlineText {
  type: "text";
  value: string;
  marks?: InlineMark[];
}
export interface InlineStrong {
  type: "strong";
  children: Inline[];
}
export interface InlineEm {
  type: "em";
  children: Inline[];
}
export interface InlineCode {
  type: "code";
  value: string;
}
export interface InlineLink {
  type: "link";
  href: string;
  children: Inline[];
}
export interface InlineMark {
  type: string;
  attrs?: Record<string, unknown>;
}

export type Inline = string | InlineText | InlineStrong | InlineEm | InlineCode | InlineLink;

/** Coerce a string|Inline[] into the inline-node array the renderer reads. */
function inlineContent(content: string | Inline[]): Inline[] {
  return typeof content === "string" ? [content] : content;
}

// ── block types ─────────────────────────────────────────────────────────────

export type Tone = "info" | "success" | "warning" | "danger" | "note";
export type HeadingLevel = 1 | 2 | 3;

export interface HeadingBlock {
  id: string;
  type: "heading";
  level: HeadingLevel;
  text: string;
}
export interface ParagraphBlock {
  id: string;
  type: "paragraph";
  content: Inline[];
}
export interface IngressBlock {
  id: string;
  type: "ingress";
  content: Inline[];
}
export interface PullquoteBlock {
  id: string;
  type: "pullquote";
  content: Inline[];
}
export interface EyebrowBlock {
  id: string;
  type: "eyebrow";
  text: string;
}
export interface BylineBlock {
  id: string;
  type: "byline";
  items: string[];
}
export interface ListBlock {
  id: string;
  type: "list";
  ordered: boolean;
  items: Inline[][];
}
export interface CalloutBlock {
  id: string;
  type: "callout";
  tone: Tone;
  content: Inline[];
  title?: string;
}
export interface ActionBlock {
  id: string;
  type: "action";
  href: string;
  label: string;
  priority?: string;
}
export interface CodeBlock {
  id: string;
  type: "code";
  value: string;
}
export interface DiagramBlock {
  id: string;
  type: "diagram";
  source: string;
  caption?: string;
}
export interface AsciicastBlock {
  id: string;
  type: "asciicast";
  src: string;
  caption?: string;
}
export interface ImageBlock {
  id: string;
  type: "image";
  src: string;
  alt: string;
  width?: number;
  height?: number;
}
export interface TableBlock {
  id: string;
  type: "table";
  head?: Inline[][];
  rows: Inline[][][];
}
export interface DividerBlock {
  id: string;
  type: "divider";
}
export interface SectionBlock {
  id: string;
  type: "section";
  title?: string;
  blocks: Block[];
}

export type Block =
  | HeadingBlock
  | ParagraphBlock
  | IngressBlock
  | PullquoteBlock
  | EyebrowBlock
  | BylineBlock
  | ListBlock
  | CalloutBlock
  | ActionBlock
  | CodeBlock
  | DiagramBlock
  | AsciicastBlock
  | ImageBlock
  | TableBlock
  | DividerBlock
  | SectionBlock;

// ── block constructors ────────────────────────────────────────────────────

export function heading(level: HeadingLevel, text: string, id?: string): HeadingBlock {
  return { id: withId(id), type: "heading", level, text };
}

export function paragraph(content: string | Inline[], id?: string): ParagraphBlock {
  return { id: withId(id), type: "paragraph", content: inlineContent(content) };
}

export function ingress(content: string | Inline[], id?: string): IngressBlock {
  return { id: withId(id), type: "ingress", content: inlineContent(content) };
}

export function pullquote(content: string | Inline[], id?: string): PullquoteBlock {
  return { id: withId(id), type: "pullquote", content: inlineContent(content) };
}

export function eyebrow(text: string, id?: string): EyebrowBlock {
  return { id: withId(id), type: "eyebrow", text };
}

export function byline(items: string[], id?: string): BylineBlock {
  return { id: withId(id), type: "byline", items };
}

export function list(
  items: (string | Inline[])[],
  opts: { ordered?: boolean } = {},
  id?: string,
): ListBlock {
  return {
    id: withId(id),
    type: "list",
    ordered: opts.ordered ?? false,
    items: items.map(inlineContent),
  };
}

export function callout(
  tone: Tone,
  content: string | Inline[],
  opts: { title?: string } = {},
  id?: string,
): CalloutBlock {
  const block: CalloutBlock = {
    id: withId(id),
    type: "callout",
    tone,
    content: inlineContent(content),
  };
  if (opts.title !== undefined) block.title = opts.title;
  return block;
}

export function action(
  href: string,
  label: string,
  opts: { priority?: string } = {},
  id?: string,
): ActionBlock {
  const block: ActionBlock = { id: withId(id), type: "action", href, label };
  if (opts.priority !== undefined) block.priority = opts.priority;
  return block;
}

export function code(value: string, id?: string): CodeBlock {
  return { id: withId(id), type: "code", value };
}

export function diagram(source: string, caption?: string, id?: string): DiagramBlock {
  const block: DiagramBlock = { id: withId(id), type: "diagram", source };
  if (caption !== undefined) block.caption = caption;
  return block;
}

export function asciicast(src: string, caption?: string, id?: string): AsciicastBlock {
  const block: AsciicastBlock = { id: withId(id), type: "asciicast", src };
  if (caption !== undefined) block.caption = caption;
  return block;
}

export function image(
  src: string,
  alt: string,
  opts: { width?: number; height?: number } = {},
  id?: string,
): ImageBlock {
  const block: ImageBlock = { id: withId(id), type: "image", src, alt };
  if (opts.width !== undefined) block.width = opts.width;
  if (opts.height !== undefined) block.height = opts.height;
  return block;
}

export function table(
  rows: (string | Inline[])[][],
  opts: { head?: (string | Inline[])[] } = {},
  id?: string,
): TableBlock {
  const block: TableBlock = {
    id: withId(id),
    type: "table",
    rows: rows.map((row) => row.map(inlineContent)),
  };
  if (opts.head !== undefined) block.head = opts.head.map(inlineContent);
  return block;
}

export function divider(id?: string): DividerBlock {
  return { id: withId(id), type: "divider" };
}

export function section(title: string | undefined, blocks: Block[], id?: string): SectionBlock {
  const block: SectionBlock = { id: withId(id), type: "section", blocks };
  if (title !== undefined) block.title = title;
  return block;
}
