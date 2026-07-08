import type { ReactNode, Key } from "react";
import { valuerefState, type Block, type Inline } from "@/lib/papers";
import { SheetSnapshot, type DenseSnapshot } from "@/components/sheet-grid";
import { PaperEditorMount } from "@/components/paper-editor-mount";
import { safeHref } from "@/lib/safe-href";
import { markHref } from "@/lib/mark-href";
import {
  taskBoardColumns,
  TASK_BOARD_COLUMN_ORDER,
  TASK_BOARD_COLUMN_LABELS,
  TASK_BOARD_GLYPHS,
  type TaskBoardColumnKey,
  type TaskBoardRow,
} from "@/lib/task-board-columns";
import {
  statusLegendProjection,
  notesProjection,
  noteProjection,
  cardsProjection,
  pipelineProjection,
  stageProjection,
  taskDetailProjection,
  roadmapProjection,
  STATUS_LADDER,
} from "@/lib/component-projections";

/** Role → its white-ladder glyph char (the spinner role shows the steady Braille
 * frame the reader animates elsewhere) — the timeline cell glyph per status. */
const ROLE_GLYPH: Record<string, string> = Object.fromEntries(
  STATUS_LADDER.map((r) => [r.role, r.spinner ? "⠋" : r.glyph]),
);

/* ── inline ─────────────────────────────────────────────────────────────── */

const inlineCode =
  "rounded bg-zinc-200/70 px-1.5 py-0.5 font-mono text-[0.85em] dark:bg-zinc-800/70";
const linkClass =
  "font-medium text-zinc-900 underline decoration-zinc-300 underline-offset-2 hover:decoration-zinc-500 dark:text-zinc-100 dark:decoration-zinc-600";

function wrapMark(name: string, href: string | undefined, el: ReactNode): ReactNode {
  switch (name) {
    case "strong":
    case "bold":
      return <strong>{el}</strong>;
    case "em":
    case "italic":
      return <em>{el}</em>;
    case "strike":
    case "strikethrough":
    case "s":
      return <s>{el}</s>;
    case "underline":
      return <u>{el}</u>;
    case "code":
      return <code className={inlineCode}>{el}</code>;
    case "link": {
      const h = safeHref(href);
      return h ? (
        <a
          href={h}
          className={linkClass}
          rel="noopener noreferrer"
          target="_blank"
        >
          {el}
        </a>
      ) : (
        <span className={linkClass}>{el}</span>
      );
    }
    default:
      return el;
  }
}

function renderInline(node: Inline, key: Key): ReactNode {
  if (typeof node === "string" || typeof node === "number") return node;

  switch (node.type) {
    case "text": {
      let el: ReactNode = (node as { value?: string }).value ?? "";
      const marks = Array.isArray((node as { marks?: unknown[] }).marks)
        ? (node as { marks: Array<string | { type: string; href?: string }> })
            .marks
        : [];
      // Fold marks so the first is outermost (matches the serializer order).
      for (let i = marks.length - 1; i >= 0; i--) {
        const m = marks[i];
        const name = typeof m === "string" ? m : m?.type;
        const href = markHref(m);
        if (name) el = wrapMark(name, href, el);
      }
      return <span key={key}>{el}</span>;
    }
    case "strong":
      return <strong key={key}>{renderInlines(node.children)}</strong>;
    case "em":
      return <em key={key}>{renderInlines(node.children)}</em>;
    case "strikethrough":
    case "strike":
    case "s":
      return <s key={key}>{renderInlines(node.children)}</s>;
    case "underline":
      return <u key={key}>{renderInlines(node.children)}</u>;
    case "code":
      return (
        <code key={key} className={inlineCode}>
          {(node as { value?: string }).value ?? ""}
        </code>
      );
    case "link": {
      const h = safeHref((node as { href?: string }).href);
      return h ? (
        <a
          key={key}
          href={h}
          className={linkClass}
          rel="noopener noreferrer"
          target="_blank"
        >
          {renderInlines(node.children)}
        </a>
      ) : (
        <span key={key} className={linkClass}>
          {renderInlines(node.children)}
        </span>
      );
    }
    // Internal-link kinds. Targets are UNRESOLVED (no href/title yet); render a
    // styled, non-navigating affordance with a data-* hook for a later resolver.
    // The visible label follows the ordered fallback alias → children → target
    // (wire §4 amended, lvw-t7): a chip-shaped node ships alias + children:[],
    // which previously vanished here.
    case "wikilink": {
      const target = (node as { target?: string }).target ?? "";
      const alias = (node as { alias?: string }).alias;
      const kids = node.children;
      return (
        <span
          key={key}
          data-wikilink={target}
          className="text-zinc-900 underline decoration-dotted underline-offset-2 dark:text-zinc-100"
        >
          {alias != null && alias !== ""
            ? alias
            : Array.isArray(kids) && kids.length > 0
              ? renderInlines(kids)
              : target}
        </span>
      );
    }
    case "blockref": {
      const anchor = (node as { anchor?: string }).anchor ?? "";
      return (
        <span
          key={key}
          data-blockref={(node as { target?: string }).target ?? ""}
          data-anchor={anchor}
          className="text-[0.9em] text-zinc-500 dark:text-zinc-400"
        >
          ^{anchor}
        </span>
      );
    }
    case "tag": {
      const name = (node as { name?: string }).name ?? "";
      return (
        <span
          key={key}
          data-tag={name}
          className="rounded bg-zinc-200/70 px-1.5 text-[0.9em] text-zinc-700 dark:bg-zinc-800/70 dark:text-zinc-300"
        >
          #{name}
        </span>
      );
    }
    // Inline live value (lvw-t1, wire §3/§6). `resolved` is the
    // server-pre-resolved display value stamped by resolveValuerefsInBlocks;
    // absent/empty → the node's pinned `fallback` literal. Rendered as a TEXT
    // node ONLY (never dangerouslySetInnerHTML — React escapes it), children
    // (the D6 dual-written fallback subtree for OLD renderers) are IGNORED,
    // and `as`/`label` are RESERVED (never interpreted). Never crashes, never
    // vanishes.
    case "valueref": {
      const v = node as {
        target?: string;
        field?: string;
        fallback?: string;
        resolved?: string;
      };
      const resolved =
        typeof v.resolved === "string" && v.resolved !== ""
          ? v.resolved
          : null;
      const fallback = typeof v.fallback === "string" ? v.fallback : "";
      // lvw-t2 marker: resolved | drift | dangling (vocabulary lockstep with
      // the Elixir walker). The states ride a data attribute ONLY — this
      // public reader ships no styling or control for them, so a drifted or
      // dangling value stays plain text (no marker leak; Studio is the
      // surface that marks visually and carries accept-baseline).
      return (
        <span
          key={key}
          data-valueref={v.target ?? ""}
          data-field={v.field ?? ""}
          data-valueref-state={valuerefState(resolved, fallback)}
        >
          {resolved ?? fallback}
        </span>
      );
    }
    default: {
      // Unknown inline type → degrade to its children when present (a
      // D6-style forward-compat node dual-writes its visible fallback as a
      // text child), else render nothing. Never crash — and never silently
      // drop a node that carries renderable content (wire §6; this reader
      // previously vanished every unknown inline).
      const kids = (node as { children?: Inline[] }).children;
      return Array.isArray(kids) && kids.length > 0 ? (
        <span key={key}>{renderInlines(kids)}</span>
      ) : null;
    }
  }
}

function renderInlines(nodes?: Inline[]): ReactNode {
  if (!Array.isArray(nodes)) return null;
  return nodes.map((n, i) => renderInline(n, i));
}

/* ── helpers ────────────────────────────────────────────────────────────── */

function str(v: unknown): string {
  return typeof v === "string" ? v : "";
}
/** Positive finite number from a number or numeric string, else undefined.
 * Used for image intrinsic dimensions, which the block may carry as either. */
function num(v: unknown): number | undefined {
  if (typeof v === "number") return Number.isFinite(v) && v > 0 ? v : undefined;
  if (typeof v === "string") {
    const n = Number.parseFloat(v);
    return Number.isFinite(n) && n > 0 ? n : undefined;
  }
  return undefined;
}
function inlineArr(v: unknown): Inline[] {
  return Array.isArray(v) ? (v as Inline[]) : [];
}

const HEADING = {
  1: "mt-2 text-3xl font-semibold tracking-tight",
  2: "mt-8 text-2xl font-semibold tracking-tight",
  3: "mt-6 text-xl font-semibold tracking-tight",
} as const;

const calloutTone: Record<string, string> = {
  info: "border-blue-300/70 bg-blue-50 dark:border-blue-900/60 dark:bg-blue-950/30",
  // `warn` is the legacy key; `warning` is the server/shorthand canonical tone.
  warn: "border-amber-300/70 bg-amber-50 dark:border-amber-900/60 dark:bg-amber-950/30",
  warning:
    "border-amber-300/70 bg-amber-50 dark:border-amber-900/60 dark:bg-amber-950/30",
  success:
    "border-emerald-300/70 bg-emerald-50 dark:border-emerald-900/60 dark:bg-emerald-950/30",
  danger:
    "border-red-300/70 bg-red-50 dark:border-red-900/60 dark:bg-red-950/30",
  neutral:
    "border-zinc-300/70 bg-zinc-50 dark:border-zinc-800/60 dark:bg-zinc-900/40",
};

function toneLabel(tone: string): string {
  switch (tone) {
    case "success":
      return "Success";
    case "warning":
    case "warn":
      return "Warning";
    case "danger":
      return "Danger";
    case "neutral":
      return "Neutral";
    default:
      return "Info";
  }
}

/* ── task-board embed (charter wave 5, D16) ───────────────────────────────── */

/**
 * Scoped, self-contained keyframes for the in_progress Braille spinner — the
 * §0 "feels alive at rest" signal carried into the paper reader (D6). Pure CSS,
 * no JS, no asset: the `::before` cycles the ten Braille frames
 * (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏) and FREEZES on ⠿ under `prefers-reduced-motion`. Byte-parallel
 * to the LiveView board's inline spinner. Rendered with a stable `href` +
 * `precedence` so React 19 HOISTS it to <head> and emits it exactly ONCE no
 * matter how many boards a paper embeds (dedupe by href — the content is a
 * constant, so the single survivor is byte-identical). Still inline CSS: no
 * asset, CSP-safe.
 */
const TASK_BOARD_SPINNER_HREF = "bp-tbe-spin";
const TASK_BOARD_SPINNER_CSS = `
.bp-tbe-spin::before{content:"⠋";display:inline-block;animation:bp-tbe-spin 1s steps(1,end) infinite}
@keyframes bp-tbe-spin{0%{content:"⠋"}10%{content:"⠙"}20%{content:"⠹"}30%{content:"⠸"}40%{content:"⠼"}50%{content:"⠴"}60%{content:"⠦"}70%{content:"⠧"}80%{content:"⠇"}90%{content:"⠏"}}
@media (prefers-reduced-motion: reduce){.bp-tbe-spin::before{animation:none;content:"⠿"}}
`;

// §1 semantic colour per column (the tone the white ladder assigns each role;
// the GLYPH itself is TASK_BOARD_GLYPHS — this only tints it).
const TASK_BOARD_GLYPH_TONE: Record<TaskBoardColumnKey, string> = {
  open: "text-zinc-400 dark:text-zinc-500",
  ready: "text-zinc-700 dark:text-zinc-200",
  in_progress: "text-blue-500 dark:text-blue-400",
  blocked: "text-amber-600 dark:text-amber-400",
  done: "text-teal-600 dark:text-teal-400",
};

/** The column's §1 glyph. `in_progress` is the pure-CSS Braille spinner (an
 * empty span whose `::before` animates the frames); every other column is the
 * static Unicode glyph, tinted by its role. */
function taskBoardGlyph(col: TaskBoardColumnKey): ReactNode {
  if (col === "in_progress") {
    return (
      <span
        className={`bp-tbe-spin ${TASK_BOARD_GLYPH_TONE.in_progress}`}
        aria-label="in progress"
      />
    );
  }
  return (
    <span className={TASK_BOARD_GLYPH_TONE[col]} aria-hidden>
      {TASK_BOARD_GLYPHS[col]}
    </span>
  );
}

/** A P-pip from a resolved `priority` string ("0".."4" or "P1"); absent → null. */
function taskBoardPriorityPip(priority: unknown): ReactNode {
  const s = str(priority).trim();
  if (!s) return null;
  const digits = s.replace(/[^0-9]/g, "");
  const label = digits ? `P${digits}` : "P?";
  return (
    <span className="rounded bg-zinc-100 px-1 font-medium text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
      {label}
    </span>
  );
}

/** `met/total` when the criteria block carries a positive total, else null (the
 * server prunes "0/0", but stay defensive). */
function taskBoardCriteria(criteria: unknown): string | null {
  if (!criteria || typeof criteria !== "object") return null;
  const c = criteria as { met?: unknown; total?: unknown };
  const total = num(c.total) ?? (typeof c.total === "number" ? c.total : NaN);
  if (!Number.isFinite(total) || total <= 0) return null;
  const metRaw = typeof c.met === "number" ? c.met : Number(c.met);
  const met = Number.isFinite(metRaw) ? metRaw : 0;
  return `${met}/${total}`;
}

/** One task card: title · priority pip · criteria · worker · phase chip. Absent
 * segments are omitted (the resolved row is pre-pruned). */
function taskBoardCard(row: TaskBoardRow, key: Key): ReactNode {
  const title = str(row.title) || "Untitled task";
  const pip = taskBoardPriorityPip(row.priority);
  const criteria = taskBoardCriteria(row.criteria);
  const worker = str(row.worker).trim();
  const phase = str(row.phase).trim();
  const hasMeta = pip !== null || criteria !== null || worker !== "" || phase !== "";
  return (
    <div
      key={key}
      className="rounded-md border border-zinc-200 bg-white px-2.5 py-2 text-sm dark:border-zinc-800 dark:bg-zinc-950/40"
    >
      <p className="font-medium leading-snug text-zinc-800 dark:text-zinc-100">
        {title}
      </p>
      {hasMeta ? (
        <div className="mt-1 flex flex-wrap items-center gap-1.5 text-[0.7rem] text-zinc-500 dark:text-zinc-400">
          {pip}
          {criteria ? <span className="tabular-nums">{criteria}</span> : null}
          {worker ? <span className="truncate">{worker}</span> : null}
          {phase ? (
            <span className="rounded bg-zinc-100 px-1.5 py-0.5 text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
              {phase}
            </span>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

/* ── blocks ─────────────────────────────────────────────────────────────── */

export function renderBlock(block: Block, key: Key): ReactNode {
  switch (block.type) {
    case "heading": {
      const level = [1, 2, 3].includes(block.level as number)
        ? (block.level as 1 | 2 | 3)
        : 2;
      const Tag = (`h${level}` as "h1" | "h2" | "h3");
      return (
        <Tag key={key} className={HEADING[level]}>
          {str(block.text)}
        </Tag>
      );
    }
    case "eyebrow":
      return (
        <p
          key={key}
          className="text-xs font-medium uppercase tracking-widest text-zinc-400"
        >
          {block.content ? renderInlines(inlineArr(block.content)) : str(block.text)}
        </p>
      );
    case "byline":
      return (
        <p key={key} className="text-sm text-zinc-500">
          {renderInlines(inlineArr(block.content))}
        </p>
      );
    case "ingress":
      return (
        <p
          key={key}
          className="text-lg leading-relaxed text-zinc-600 dark:text-zinc-300"
        >
          {renderInlines(inlineArr(block.content))}
        </p>
      );
    case "paragraph":
      return (
        <p key={key} className="leading-7 text-zinc-700 dark:text-zinc-300">
          {renderInlines(inlineArr(block.content))}
        </p>
      );
    case "pullquote":
      return (
        <blockquote
          key={key}
          className="border-l-2 border-zinc-300 pl-4 text-lg italic text-zinc-600 dark:border-zinc-700 dark:text-zinc-300"
        >
          {renderInlines(inlineArr(block.content))}
        </blockquote>
      );
    case "list": {
      const ordered = block.ordered === true;
      const items = Array.isArray(block.items) ? (block.items as Inline[][]) : [];
      const ListTag = ordered ? "ol" : "ul";
      return (
        <ListTag
          key={key}
          className={`flex flex-col gap-1.5 pl-6 text-zinc-700 dark:text-zinc-300 ${
            ordered ? "list-decimal" : "list-disc"
          }`}
        >
          {items.map((item, i) => (
            <li key={i} className="leading-7">
              {renderInlines(inlineArr(item))}
            </li>
          ))}
        </ListTag>
      );
    }
    case "callout": {
      const tone = str(block.tone) || "info";
      const toneClass = `rounded-lg border px-4 py-3 text-sm leading-6 text-zinc-700 dark:text-zinc-200 ${
        calloutTone[tone] ?? calloutTone.info
      }`;
      const title = str(block.title);
      const body = <div>{renderInlines(inlineArr(block.content))}</div>;

      // Native zero-JS fold when collapsible; the toggle is ephemeral in the
      // read-only web reader (resets on reload). Title or tone label as summary.
      if (block.collapsible === true) {
        return (
          <details key={key} className={toneClass} open={block.collapsed !== true}>
            <summary className="cursor-pointer font-medium">
              {title || toneLabel(tone)}
            </summary>
            <div className="mt-1">{body}</div>
          </details>
        );
      }

      return (
        <aside key={key} className={toneClass}>
          {title ? <p className="mb-1 font-medium">{title}</p> : null}
          {body}
        </aside>
      );
    }
    case "code":
      return (
        <pre
          key={key}
          className="overflow-x-auto rounded-lg bg-zinc-100 p-4 text-sm dark:bg-zinc-900"
        >
          <code className="font-mono text-zinc-800 dark:text-zinc-200">
            {str(block.value)}
          </code>
        </pre>
      );
    case "divider":
      return (
        <hr key={key} className="border-zinc-200 dark:border-zinc-800" />
      );
    case "image": {
      // safeHref parity with Elixir walk.ex `safe_url` and Go hardblocks.go
      // sanitize — drop data:/custom-scheme src that bypasses the allowlist.
      const src = safeHref(str(block.src));
      if (!src) return null; // no/rejected src → skip (empty src="" refetches the page)
      const alt = str(block.alt);
      // Intrinsic pixel dims the block MAY carry (parity with walk.ex `image/1`
      // and compose.ex — keys are `width`/`height`, optional integers).
      const w = num(block.width);
      const h = num(block.height);
      // Stays a plain <img>: hosts are arbitrary, so next/image (per-host
      // remotePatterns) is the wrong tool. But a bare <img> reflows the article
      // body as it streams in (CLS) — so we reserve its space before load.
      if (w && h) {
        // Known dims → width/height attrs let the browser derive the aspect
        // ratio and reserve the exact box; `h-auto max-w-full` keeps it fluid
        // and undistorted. Zero reflow on load.
        return (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            key={key}
            src={src}
            alt={alt}
            width={w}
            height={h}
            className="h-auto max-w-full rounded-lg"
            loading="lazy"
            decoding="async"
          />
        );
      }
      // Unknown dims → reserve space with a default aspect box so the body
      // doesn't jump. `object-contain` shows the whole image at its natural
      // proportions (never cropped, never stretched) inside the reserved box;
      // the tint is a faint skeleton until the image paints.
      return (
        <span
          key={key}
          className="block aspect-[16/9] w-full overflow-hidden rounded-lg bg-zinc-100 dark:bg-zinc-900"
        >
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={src}
            alt={alt}
            className="h-full w-full object-contain"
            loading="lazy"
            decoding="async"
          />
        </span>
      );
    }
    case "figure": {
      const child = block.child as Block | undefined;
      const caption = str(block.caption);
      return (
        <figure key={key} className="flex flex-col gap-2">
          {child ? renderBlock(child, "child") : null}
          {caption ? (
            <figcaption className="text-sm text-zinc-500">{caption}</figcaption>
          ) : null}
        </figure>
      );
    }
    case "table": {
      const rows = Array.isArray(block.rows) ? (block.rows as Inline[][][]) : [];
      const head = Array.isArray(block.head)
        ? (block.head as Inline[][])
        : null;
      return (
        <div key={key} className="overflow-x-auto">
          <table className="w-full border-collapse text-sm">
            {head ? (
              <thead>
                <tr className="border-b border-zinc-300 dark:border-zinc-700">
                  {head.map((cell, c) => (
                    <th key={c} className="px-3 py-2 text-left font-medium">
                      {renderInlines(inlineArr(cell))}
                    </th>
                  ))}
                </tr>
              </thead>
            ) : null}
            <tbody>
              {rows.map((row, r) => (
                <tr
                  key={r}
                  className="border-b border-zinc-200 dark:border-zinc-800"
                >
                  {row.map((cell, c) => (
                    <td key={c} className="px-3 py-2 align-top">
                      {renderInlines(inlineArr(cell))}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
    }
    case "section": {
      const inner = Array.isArray(block.blocks) ? (block.blocks as Block[]) : [];
      return (
        <section key={key} className="flex flex-col gap-4">
          {block.title ? (
            <h2 className="text-2xl font-semibold tracking-tight">
              {str(block.title)}
            </h2>
          ) : null}
          {inner.map((b, i) => renderBlock(b, i))}
        </section>
      );
    }
    case "action": {
      const actionClass =
        "inline-flex w-fit items-center rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-zinc-50 transition-colors hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300";
      const h = safeHref(str(block.href));
      return h ? (
        <a key={key} href={h} className={actionClass}>
          {str(block.label) || "Open"}
        </a>
      ) : (
        <span key={key} className={actionClass}>
          {str(block.label) || "Open"}
        </span>
      );
    }
    case "diagram":
      // Mermaid source — no client renderer here; show the source faithfully.
      return (
        <figure key={key} className="flex flex-col gap-2">
          <pre className="overflow-x-auto rounded-lg bg-zinc-100 p-4 text-sm dark:bg-zinc-900">
            <code className="font-mono text-zinc-700 dark:text-zinc-300">
              {str(block.source)}
            </code>
          </pre>
          {block.caption ? (
            <figcaption className="text-sm text-zinc-500">
              {str(block.caption)}
            </figcaption>
          ) : null}
        </figure>
      );
    case "asciicast": {
      const h = safeHref(str(block.src));
      return (
        <p key={key} className="text-sm text-zinc-500">
          ▶{" "}
          {h ? (
            <a href={h} className={linkClass}>
              {str(block.caption) || "terminal recording"}
            </a>
          ) : (
            <span className={linkClass}>
              {str(block.caption) || "terminal recording"}
            </span>
          )}
        </p>
      );
    }
    case "task-board": {
      // Embedded LIVE task board (charter wave 5, D16). The `task-board`
      // PortableDoc block resolves SERVER-SIDE into a flat `snapshot: [row]`,
      // each row already carrying the honest white-ladder `status` — readiness
      // is derived once on the wire, never re-computed here. This surface only
      // BUCKETS the rows into the five ordered columns for a read-only embed.
      // STAYS a Server Component (no drag/realtime — the live /admin/projects
      // board owns interaction); a momentum line + a `prefers-reduced-motion`-
      // honouring CSS Braille spinner keep it feeling alive at rest.
      const snapshot = Array.isArray(block.snapshot)
        ? (block.snapshot as TaskBoardRow[])
        : null;
      if (!snapshot) return null;
      const caption = str(block.caption);
      const { columns, cancelledCount, momentum } = taskBoardColumns(snapshot);
      const liveTotal = TASK_BOARD_COLUMN_ORDER.reduce(
        (n, k) => n + columns[k].length,
        0,
      );

      // Honest empty state — a truly empty board says so instead of a dead wall.
      if (liveTotal === 0 && cancelledCount === 0) {
        return (
          <figure key={key} className="flex flex-col gap-2">
            <div className="rounded-lg border border-dashed border-zinc-200 px-4 py-6 text-center text-sm text-zinc-400 dark:border-zinc-800 dark:text-zinc-500">
              No tasks on this board yet.
            </div>
            {caption ? (
              <figcaption className="text-sm text-zinc-500">{caption}</figcaption>
            ) : null}
          </figure>
        );
      }

      return (
        <figure key={key} className="flex flex-col gap-3">
          {/* Self-contained spinner keyframes (D6 — no asset, CSP-safe).
              href+precedence → React 19 hoists + dedupes to a single <head>
              tag across every embedded board. */}
          <style href={TASK_BOARD_SPINNER_HREF} precedence="default">
            {TASK_BOARD_SPINNER_CSS}
          </style>

          {/* Momentum header — the "always feel progress" read (§0). */}
          <div className="flex flex-col gap-1.5">
            <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-zinc-500 dark:text-zinc-400">
              <span>
                <span aria-hidden>◐</span>{" "}
                <b className="font-semibold text-zinc-700 dark:text-zinc-200">
                  {momentum.inFlight}
                </b>{" "}
                in flight
              </span>
              <span aria-hidden className="text-zinc-300 dark:text-zinc-700">
                ·
              </span>
              <span>
                <span aria-hidden>○</span>{" "}
                <b className="font-semibold text-zinc-700 dark:text-zinc-200">
                  {momentum.ready}
                </b>{" "}
                ready
              </span>
              <span aria-hidden className="text-zinc-300 dark:text-zinc-700">
                ·
              </span>
              <span>
                <span aria-hidden className="text-teal-600 dark:text-teal-400">
                  ✓
                </span>{" "}
                <b className="font-semibold text-zinc-700 dark:text-zinc-200">
                  {momentum.done}
                </b>{" "}
                done
              </span>
              <span className="ml-auto font-semibold tabular-nums text-zinc-700 dark:text-zinc-200">
                {momentum.pct}%
              </span>
            </div>
            {/* Thin fill bar — grows with pct; width-transitions for free. */}
            <div className="h-1 w-full overflow-hidden rounded-full bg-zinc-200 dark:bg-zinc-800">
              <span
                className="block h-full rounded-full bg-zinc-800 transition-[width] duration-500 dark:bg-zinc-200"
                style={{ width: `${momentum.pct}%` }}
              />
            </div>
          </div>

          {/* Five white-ladder columns as a horizontal wrapping grid. */}
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
            {TASK_BOARD_COLUMN_ORDER.map((col) => {
              const cards = columns[col];
              return (
                <div
                  key={col}
                  className="flex min-w-0 flex-col gap-2 rounded-lg border border-zinc-200 bg-zinc-50/60 p-2.5 dark:border-zinc-800 dark:bg-zinc-900/40"
                >
                  <div className="flex items-center justify-between gap-2 text-xs font-medium text-zinc-500 dark:text-zinc-400">
                    <span className="flex items-center gap-1.5">
                      {taskBoardGlyph(col)}
                      {TASK_BOARD_COLUMN_LABELS[col]}
                    </span>
                    <span className="tabular-nums text-zinc-400 dark:text-zinc-500">
                      {cards.length}
                    </span>
                  </div>
                  <div className="flex flex-col gap-1.5">
                    {cards.length > 0 ? (
                      cards.map((row, i) => taskBoardCard(row, i))
                    ) : (
                      <p className="px-0.5 text-xs text-zinc-300 dark:text-zinc-600">
                        —
                      </p>
                    )}
                  </div>
                </div>
              );
            })}
          </div>

          {/* Cancelled tally — folded, never a column (charter D-fold). */}
          {cancelledCount > 0 ? (
            <p className="text-xs text-zinc-400 dark:text-zinc-500">
              <span aria-hidden>✕</span> {cancelledCount} cancelled
            </p>
          ) : null}

          {caption ? (
            <figcaption className="text-sm text-zinc-500">{caption}</figcaption>
          ) : null}
        </figure>
      );
    }
    case "sheet": {
      // Embedded sheet block — carries a dense, pre-computed snapshot. The
      // grid itself is a client component; rendering it from here keeps this
      // module a server component.
      const snapshot = block.snapshot as DenseSnapshot | undefined;
      if (!snapshot) return null;
      const caption = str(block.caption);
      return (
        <figure key={key} className="flex flex-col gap-2">
          <SheetSnapshot snapshot={snapshot} />
          {caption ? (
            <figcaption className="text-sm text-zinc-500">{caption}</figcaption>
          ) : null}
        </figure>
      );
    }
    // ── S2: task-tracking / composition component family ───────────────────
    // Each case renders FROM its shared projection (component-projections.ts) so
    // the golden-parity web leg locks the real render. Structure only — token /
    // colour adoption is W5.14; Tailwind zinc classes for now.
    case "status-legend": {
      const { rows } = statusLegendProjection();
      return (
        <dl
          key={key}
          className="flex flex-col gap-1 text-sm text-zinc-600 dark:text-zinc-300"
        >
          {rows.map((r) => (
            <div key={r.role} className="flex items-baseline gap-2">
              <span
                aria-hidden
                className="w-4 text-center font-mono text-zinc-500 dark:text-zinc-400"
              >
                {r.spinner ? "⠋" : r.glyph}
              </span>
              <dt className="font-medium text-zinc-700 dark:text-zinc-200">
                {r.role}
              </dt>
            </div>
          ))}
        </dl>
      );
    }
    case "notes": {
      const { rows } = notesProjection(block as Record<string, unknown>);
      return (
        <div key={key} className="flex flex-col gap-2">
          {rows.map((r, i) => (
            <div key={i} className="flex gap-2 text-sm">
              {r.label ? (
                <span className="shrink-0 font-medium text-zinc-500 dark:text-zinc-400">
                  {r.label}
                </span>
              ) : null}
              <div className="text-zinc-700 dark:text-zinc-300">
                {r.lead ? <b className="font-semibold">{r.lead}</b> : null}
                {r.lead && r.text ? " " : null}
                {r.text}
              </div>
            </div>
          ))}
        </div>
      );
    }
    case "note": {
      const r = noteProjection(block as Record<string, unknown>);
      return (
        <div key={key} className="flex gap-2 text-sm">
          {r.label ? (
            <span className="shrink-0 font-medium text-zinc-500 dark:text-zinc-400">
              {r.label}
            </span>
          ) : null}
          <div className="text-zinc-700 dark:text-zinc-300">
            {r.lead ? <b className="font-semibold">{r.lead}</b> : null}
            {r.lead && r.text ? " " : null}
            {r.text}
          </div>
        </div>
      );
    }
    case "cards": {
      const { cards } = cardsProjection(block as Record<string, unknown>);
      const toneStripe: Record<string, string> = {
        info: "border-l-blue-400",
        ok: "border-l-emerald-400",
        warn: "border-l-amber-400",
        danger: "border-l-red-400",
      };
      return (
        <div key={key} className="grid gap-3 sm:grid-cols-2">
          {cards.map((c, i) => (
            <div
              key={i}
              className={`rounded-md border border-zinc-200 bg-white p-3 dark:border-zinc-800 dark:bg-zinc-950/40 ${
                c.tone ? `border-l-2 ${toneStripe[c.tone] ?? ""}` : ""
              }`}
            >
              {c.title ? (
                <p className="font-medium text-zinc-800 dark:text-zinc-100">
                  {c.title}
                </p>
              ) : null}
              {c.text ? (
                <p className="mt-1 text-sm text-zinc-600 dark:text-zinc-400">
                  {c.text}
                </p>
              ) : null}
            </div>
          ))}
        </div>
      );
    }
    case "card": {
      // Slots-native card (au-w5-card-slot-parity, MODEL B): each slot holds
      // ARBITRARY element children, recursed via `renderBlock` in the order
      // media, title, body, action — an `image` media child fast-paths to <img>
      // (the image case) and an `action` child to a button (the action case), no
      // card-specific media/action code. The legacy `tone` accent
      // (info|ok|warn|danger) tints the card; an all-empty card renders as a
      // blank container. This mirrors the Elixir `Components.card_html/2` model-B
      // render. (Card is now COVERED in the parity gate: this render realizes the
      // model-B slots/order/tone projection and is RENDER-asserted by the parity
      // harness — all three surfaces (Elixir, web, Go) conform, so the
      // render↔render parity lock is live. `cardProjection` still feeds the frozen
      // golden-parity leg.)
      const slots = (block.slots ?? {}) as Record<string, unknown>;
      const slotKids = (name: string): Block[] =>
        Array.isArray(slots[name]) ? (slots[name] as Block[]) : [];
      // Card tone vocab → the shared callout tint. `ok` has no callout key, so it
      // maps to `success`; an unknown/absent tone gets no accent.
      const tone = str(block.tone);
      const tint = tone === "ok" ? calloutTone.success : (calloutTone[tone] ?? "");
      const order = ["media", "title", "body", "action"] as const;
      return (
        <div
          key={key}
          className={`flex flex-col gap-3 rounded-md p-3${
            tint ? ` border ${tint}` : " border border-zinc-200 bg-white dark:border-zinc-800 dark:bg-zinc-950/40"
          }`}
        >
          {order.flatMap((name) =>
            slotKids(name).map((b, i) => renderBlock(b, `${name}-${i}`)),
          )}
        </div>
      );
    }
    case "pipeline": {
      const { nodes } = pipelineProjection(block as Record<string, unknown>);
      return (
        <div key={key} className="flex flex-wrap items-stretch gap-2 overflow-x-auto">
          {nodes.map((n, i) => (
            <div key={i} className="flex items-center gap-2">
              {i > 0 ? (
                <span aria-hidden className="text-zinc-400">
                  →
                </span>
              ) : null}
              <div className="rounded-md border border-zinc-200 px-3 py-2 text-sm dark:border-zinc-800">
                {n.kind ? (
                  <p className="text-xs uppercase tracking-widest text-zinc-400">
                    {n.kind}
                  </p>
                ) : null}
                {n.title ? (
                  <p className="font-medium text-zinc-800 dark:text-zinc-100">
                    {n.title}
                  </p>
                ) : null}
                {n.detail ? (
                  <p className="text-xs text-zinc-500 dark:text-zinc-400">
                    {n.detail}
                  </p>
                ) : null}
              </div>
            </div>
          ))}
        </div>
      );
    }
    case "stage": {
      const s = stageProjection(block as Record<string, unknown>);
      return (
        <div
          key={key}
          className="rounded-md border border-zinc-200 px-3 py-2 text-sm dark:border-zinc-800"
        >
          {s.kind ? (
            <p className="text-xs uppercase tracking-widest text-zinc-400">
              {s.kind}
            </p>
          ) : null}
          {s.title ? (
            <p className="font-medium text-zinc-800 dark:text-zinc-100">
              {s.title}
            </p>
          ) : null}
          {s.detail ? (
            <p className="text-xs text-zinc-500 dark:text-zinc-400">
              {s.detail}
            </p>
          ) : null}
        </div>
      );
    }
    case "task-detail": {
      const d = taskDetailProjection(block as Record<string, unknown>);
      const task =
        block.task && typeof block.task === "object"
          ? (block.task as Record<string, unknown>)
          : (block as Record<string, unknown>);
      const criteria = Array.isArray(task.criteria)
        ? (task.criteria as Array<Record<string, unknown>>)
        : [];
      const labels = Array.isArray(task.labels)
        ? (task.labels as unknown[]).map(str).filter(Boolean)
        : [];
      return (
        <div
          key={key}
          className="flex flex-col gap-2 rounded-lg border border-zinc-200 p-4 dark:border-zinc-800"
        >
          <p className="text-lg font-semibold text-zinc-900 dark:text-zinc-100">
            {d.title}
          </p>
          {d.sections.includes("meta") ? (
            <p className="text-xs text-zinc-500 dark:text-zinc-400">
              {[str(task.status), str(task.priority) ? `P${str(task.priority).replace(/[^0-9]/g, "")}` : "", str(task.kind), str(task.worker)]
                .filter(Boolean)
                .join(" · ")}
            </p>
          ) : null}
          {d.sections.includes("timeline") ? (
            <div className="flex flex-wrap items-center gap-1.5 text-xs text-zinc-600 dark:text-zinc-300">
              {d.timeline.map((seg, i) => (
                <span key={i} className="flex items-center gap-1.5">
                  {i > 0 ? (
                    <span aria-hidden className="text-zinc-400">
                      →
                    </span>
                  ) : null}
                  <span className="flex items-center gap-1">
                    <span aria-hidden className="text-zinc-400">
                      {ROLE_GLYPH[seg.role] ?? ""}
                    </span>
                    <span>{seg.label}</span>
                  </span>
                </span>
              ))}
            </div>
          ) : null}
          {d.sections.includes("criteria") ? (
            <div>
              <p className="text-xs font-medium text-zinc-500 dark:text-zinc-400">
                Criteria · {d.criteria.met}/{d.criteria.total}
              </p>
              <ul className="mt-1 flex flex-col gap-0.5 text-sm text-zinc-700 dark:text-zinc-300">
                {criteria.map((c, i) => (
                  <li key={i} className="flex items-baseline gap-1.5">
                    <span aria-hidden className="text-zinc-400">
                      {c.met === true ? "✓" : "○"}
                    </span>
                    {str(c.text) || str(c.criterion)}
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
          {d.sections.includes("labels") ? (
            <p className="text-xs text-zinc-500 dark:text-zinc-400">
              {labels.join(" · ")}
            </p>
          ) : null}
        </div>
      );
    }
    case "roadmap": {
      const { lanes, scale } = roadmapProjection(
        block as Record<string, unknown>,
      );
      const snapshot = Array.isArray(block.snapshot)
        ? (block.snapshot as Array<Record<string, unknown>>)
        : [];
      const roleBar: Record<string, string> = {
        open: "bg-zinc-400",
        ready: "bg-zinc-500",
        progress: "bg-blue-500",
        blocked: "bg-amber-500",
        done: "bg-teal-500",
        cancel: "bg-zinc-300",
      };
      return (
        <div key={key} className="flex flex-col gap-1.5">
          {scale.length ? (
            <div className="flex justify-between text-xs text-zinc-400">
              {scale.map((cell, i) => (
                <span key={i}>{cell}</span>
              ))}
            </div>
          ) : null}
          {lanes.map((lane, i) => {
            const row = snapshot[i] ?? {};
            const left = num(row.left) ?? 0;
            const width = num(row.width) ?? 1;
            return (
              <div key={i} className="flex items-center gap-2 text-sm">
                <span
                  className={`w-32 shrink-0 truncate text-zinc-600 dark:text-zinc-300 ${
                    lane.phase ? "font-semibold" : ""
                  }`}
                >
                  {lane.title}
                </span>
                <div className="relative h-2 flex-1 rounded bg-zinc-100 dark:bg-zinc-800">
                  <span
                    className={`absolute h-full rounded ${roleBar[lane.role] ?? "bg-zinc-500"}`}
                    style={{ left: `${left}%`, width: `${width}%` }}
                  />
                </div>
              </div>
            );
          })}
        </div>
      );
    }
    case "columns": {
      // Recursive container — recurse renderBlock over each column's children.
      const cols = Array.isArray(block.columns)
        ? (block.columns as unknown[])
        : [];
      return (
        <div
          key={key}
          className="grid gap-4"
          style={{ gridTemplateColumns: `repeat(${Math.max(cols.length, 1)}, minmax(0, 1fr))` }}
        >
          {cols.map((col, ci) => {
            const kids = Array.isArray(col) ? (col as Block[]) : [];
            return (
              <div key={ci} className="flex flex-col gap-4">
                {kids.map((b, i) => renderBlock(b, i))}
              </div>
            );
          })}
        </div>
      );
    }
    case "terminal": {
      // Recursive container — traffic-light chrome wrapping child blocks.
      const kids = Array.isArray(block.children)
        ? (block.children as Block[])
        : Array.isArray(block.blocks)
          ? (block.blocks as Block[])
          : [];
      const live =
        block.live === true || block.live === "true" || block.live === "live";
      const footer = str(block.footer);
      return (
        <div
          key={key}
          className="overflow-hidden rounded-lg border border-zinc-200 dark:border-zinc-800"
        >
          <div className="flex items-center gap-2 border-b border-zinc-200 bg-zinc-50 px-3 py-2 dark:border-zinc-800 dark:bg-zinc-900">
            <span aria-hidden className="text-zinc-400">
              ● ● ●
            </span>
            {block.title ? (
              <span className="text-sm font-medium text-zinc-700 dark:text-zinc-200">
                {str(block.title)}
              </span>
            ) : null}
            {live ? (
              <span className="rounded bg-zinc-800 px-1.5 text-xs text-zinc-100 dark:bg-zinc-200 dark:text-zinc-900">
                live
              </span>
            ) : null}
          </div>
          <div className="flex flex-col gap-4 p-3">
            {kids.map((b, i) => renderBlock(b, i))}
          </div>
          {footer ? (
            <div className="border-t border-zinc-200 px-3 py-1.5 text-xs text-zinc-400 dark:border-zinc-800">
              {footer}
            </div>
          ) : null}
        </div>
      );
    }
    default:
      // Unknown / not-yet-supported block (e.g. sheet embeds). Render nothing
      // visible but leave a quiet marker for debugging rather than crashing.
      return (
        <p key={key} className="text-xs text-zinc-400 italic">
          [unsupported block: {block.type}]
        </p>
      );
  }
}

/** Render a PortableDoc block array as an article. */
export function PortableDoc({ blocks }: { blocks: Block[] }) {
  if (!blocks.length) {
    return (
      <p className="text-sm text-zinc-400 italic">This paper has no content.</p>
    );
  }
  return (
    <div className="flex flex-col gap-4">
      {blocks.map((b, i) => renderBlock(b, i))}
    </div>
  );
}

/** Top-level PROSE block types the bp-paper-editor web component can host —
 * authoritative from the WC source (index.js StarterKit config + convert.js).
 * `code` is explicitly NOT prose; everything else stays server-rendered. */
const PROSE_TYPES = new Set(["paragraph", "heading", "list"]);

/**
 * Read-mode editor-aware variant of {@link PortableDoc}. STAYS a Server
 * Component (this file must never become "use client" — renderBlock statically
 * imports the client SheetSnapshot, so a client conversion ships the whole sheet
 * engine to the browser). It partitions blocks in document order:
 *   • non-prose → server-rendered via renderBlock, passed down as opaque
 *     ReactNode slots;
 *   • prose (paragraph|heading|list) → a `null` hole in the slot stream + the
 *     raw Block in `proseBlocks`, which the client {@link PaperEditorMount}
 *     fills with one <bp-paper-editor> each.
 * The client child imports nothing from this file, so the bundle gains only the
 * mount + the WC loader — never the renderer.
 */
export function PaperEditorDoc({ blocks }: { blocks: Block[] }) {
  if (!blocks.length) {
    return (
      <p className="text-sm text-zinc-400 italic">This paper has no content.</p>
    );
  }
  const proseBlocks: Block[] = [];
  const slots: Array<ReactNode | null> = blocks.map((b, i) => {
    if (PROSE_TYPES.has(b.type)) {
      proseBlocks.push(b);
      return null; // hole — the client mount fills it with <bp-paper-editor>.
    }
    return renderBlock(b, i); // server-rendered, serializable ReactNode.
  });
  return <PaperEditorMount proseBlocks={proseBlocks} slots={slots} />;
}
