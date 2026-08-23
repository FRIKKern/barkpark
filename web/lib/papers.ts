import {
  typedClient,
  type BarkparkClient,
  type BarkparkDocument,
} from "@barkpark/core";
import type { Paper, BarkparkTypeMap } from "./barkpark.types";
import { inlineText } from "./find.ts";
import type { PaperTag } from "./paper-tags.ts";
import { collectAllPages } from "./paginate.ts";

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
  | { type: "tag"; name?: string }
  | {
      /** Inline live value (lvw-t1, wire §3): renders the CURRENT canonical
       * value of `field` on the `target` doc. `as`/`label` are RESERVED —
       * round-trip opaquely, never interpreted. `children` are the D6
       * dual-written fallback subtree for OLD renderers — this reader IGNORES
       * them. `resolved` is NOT wire data: the server pre-resolve pass
       * ({@link resolveValuerefsInBlocks}) stamps it before render; absent /
       * empty → the pinned `fallback` literal shows (never a crash, never a
       * vanish). */
      type: "valueref";
      target?: string;
      field?: string;
      as?: string;
      label?: string;
      fallback?: string;
      resolved?: string;
      children?: Inline[];
    };

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
     * level, so these surface here; consumed by the /tags/[tag] route. Since the
     * authoring-excellence wall (charter D8–D10) tags may be flat strings, weighted
     * `{tag, strength, rationale}` objects, or a mix — read them via {@link paperTags}. */
    tags?: PaperTag[];
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

// Pagination bounds (task-269eefbe4864d8a5): a bare `.limit(50).find()` used
// to ride the server's default page and silently truncate at 50 papers — the
// `docs` dataset carries 118 in prod today, so 68 were dropped from every
// consumer (the /papers listing, sitemap.xml, feed.xml). 1000/page (the
// server's own clamp — js/packages/core's `DocsBuilder.limit` docs) x 20
// pages = 20k papers, far beyond any plausible corpus; the cap exists so an
// upstream that never serves a short page can't spin the walk forever, and
// hitting it is reported out loud, never absorbed. Mirrors
// apps/hundesteder/lib/paginate.ts (PR #13316), the second instance of this
// fix — this is the third, same shape.
const PAPERS_PAGE_LIMIT = 1000;
const PAPERS_MAX_PAGES = 20;

/** Listing query — papers, newest first, walked page by page until a short
 * page terminates. Scope rides on the client. */
export async function fetchPapers(
  client: BarkparkClient,
): Promise<PaperDocument[]> {
  // `typedClient<BarkparkTypeMap>` narrows `docs("paper")` to the generated
  // `Paper`; cast to the demo's wider `PaperDocument` view at the boundary.
  const bp = typedClient<BarkparkTypeMap>(client);
  const { rows, truncated } = await collectAllPages(
    async (limit, offset) => {
      try {
        return (await bp
          .docs("paper")
          .order("_updatedAt:desc")
          .limit(limit)
          .offset(offset)
          .find()) as unknown[];
      } catch (err) {
        // A first-page failure keeps the PRE-EXISTING behaviour: this used to
        // be the only query issued, so its rejection propagated to the
        // caller (papers/page.tsx, sitemap.ts, feed.xml/route.ts all already
        // wrap fetchPapers in try/catch). A later page failing mid-walk is
        // new territory the walk now recovers from — degrade to null so
        // collectAllPages returns the rows already collected, flagged.
        if (offset === 0) throw err;
        return null;
      }
    },
    { limit: PAPERS_PAGE_LIMIT, maxPages: PAPERS_MAX_PAGES },
  );
  if (truncated !== undefined) {
    // Partial truth, said out loud — never a silent shrink of the corpus.
    console.warn(
      `[papers] PAGINATION COULD NOT TERMINATE CLEANLY (${truncated}) — ` +
        `returning the ${rows.length} papers collected so far`,
    );
  }
  return rows as PaperDocument[];
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

/* ── inline live values (lvw-t1, wire §3/§5) ────────────────────────────── */

/**
 * Deep-collect every inline `valueref` node's non-empty `(target, field)`
 * pair from a block tree, distinct, in document order. `field` must be a
 * single top-level name — dot-paths (incl. the `content.` prefix) are wire
 * violations and are dropped here (the node then renders its fallback).
 * Pure + exported for tests.
 */
export function collectValuerefPairs(
  blocks: Block[],
): Array<{ target: string; field: string }> {
  const seen = new Set<string>();
  const out: Array<{ target: string; field: string }> = [];
  const walk = (v: unknown): void => {
    if (Array.isArray(v)) {
      v.forEach(walk);
      return;
    }
    if (v === null || typeof v !== "object") return;
    const node = v as Record<string, unknown>;
    if (node.type === "valueref") {
      const target =
        typeof node.target === "string" ? node.target.trim() : "";
      const field = typeof node.field === "string" ? node.field.trim() : "";
      if (target !== "" && field !== "" && !field.includes(".")) {
        const k = `${target}\u0000${field}`;
        if (!seen.has(k)) {
          seen.add(k);
          out.push({ target, field });
        }
      }
    }
    Object.values(node).forEach(walk);
  };
  walk(blocks);
  return out;
}

/** The shared three-surface scalar rule: only a non-empty string / number /
 * boolean resolves ("" counts as UNRESOLVED — the Go convention); maps, lists
 * and null never stringify, so an encrypted `_bpenc` envelope or a nested
 * object degrades to the node's fallback. Pure + exported for tests. */
export function valuerefScalar(v: unknown): string | null {
  if (typeof v === "string") {
    const s = v.trim();
    return s === "" ? null : s;
  }
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  return null;
}

/**
 * The lvw-t2 stale marker — THREE states, two stale treatments, kept in
 * vocabulary lockstep with the Elixir walker (`data-valueref-state`):
 *
 *   - `resolved` — value resolved and the pinned `fallback` matches (or no
 *     fallback is pinned: with no baseline there is nothing to drift).
 *   - `drift`    — value resolved but the pinned `fallback` literal no longer
 *     matches (the ONE comparison, fallback vs resolved — wire §8; there is
 *     no standalone checker).
 *   - `dangling` — did not resolve (target deleted / never published): drift
 *     uncomputable; the pinned `fallback` shows.
 *
 * Since this reader is server-pre-resolved against the PUBLISHED perspective
 * only, public drift is by construction drift against the published canonical
 * value. Pure + exported for tests.
 */
export function valuerefState(
  resolved: string | null,
  fallback: string,
): "resolved" | "drift" | "dangling" {
  if (resolved === null) return "dangling";
  return fallback === "" || fallback === resolved ? "resolved" : "drift";
}

/**
 * Return a NEW block tree with `resolved` stamped onto every valueref whose
 * `(target, field)` resolves through `envelopes` (target doc_id → flat
 * envelope). Non-mutating; unresolved nodes pass through untouched (they
 * render their pinned `fallback`). Pure + exported for tests.
 */
export function stampResolvedValues(
  blocks: Block[],
  envelopes: Record<string, Record<string, unknown>>,
): Block[] {
  const walk = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(walk);
    if (v === null || typeof v !== "object") return v;
    const node = v as Record<string, unknown>;
    let next: Record<string, unknown> = node;
    if (node.type === "valueref") {
      const target =
        typeof node.target === "string" ? node.target.trim() : "";
      const field = typeof node.field === "string" ? node.field.trim() : "";
      const env = target !== "" ? envelopes[target] : undefined;
      const resolved =
        env && field !== "" && !field.includes(".")
          ? valuerefScalar(env[field])
          : null;
      if (resolved !== null) next = { ...node, resolved };
    }
    const out: Record<string, unknown> = {};
    for (const [k, child] of Object.entries(next)) out[k] = walk(child);
    return out;
  };
  return walk(blocks) as Block[];
}

/**
 * Server pre-resolve pass (the wire §5 "recommended default" for the React
 * reader): collect every valueref target, batch-fetch the target docs through
 * the PUBLIC client (published perspective — draft values never leak into the
 * anonymous reader), and stamp `resolved` onto the nodes so the component
 * stays dumb (no client resolver, no live DB coupling in the browser).
 *
 * Targets are TYPELESS doc_id slugs and the query surface is type-scoped, so
 * declared types are probed with ONE batched `getDocuments` (the `_id in`
 * filter) each, early-exiting once every target resolves — never one fetch
 * per node. Best-effort throughout: ANY failure returns the original blocks
 * (every valueref then renders its pinned fallback — never a crash, never a
 * vanish).
 */
export async function resolveValuerefsInBlocks(
  client: BarkparkClient,
  blocks: Block[],
): Promise<Block[]> {
  try {
    const pairs = collectValuerefPairs(blocks);
    if (pairs.length === 0) return blocks;
    const remaining = new Set(pairs.map((p) => p.target));

    const envelopes: Record<string, Record<string, unknown>> = {};
    const schemas = await client.schemas();
    for (const schema of schemas) {
      if (remaining.size === 0) break;
      const ids = [...remaining].sort();
      const docs = await client.getDocuments<Record<string, unknown>>(
        schema.name,
        ids,
      );
      docs.forEach((doc, i) => {
        const id = ids[i];
        if (doc && id) {
          envelopes[id] = doc;
          remaining.delete(id);
        }
      });
    }
    return stampResolvedValues(blocks, envelopes);
  } catch {
    return blocks;
  }
}
