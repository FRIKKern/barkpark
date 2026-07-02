import type { ReactNode, Key } from "react";
import { valuerefState, type Block, type Inline } from "@/lib/papers";
import { SheetSnapshot, type DenseSnapshot } from "@/components/sheet-grid";
import { PaperEditorMount } from "@/components/paper-editor-mount";
import { safeHref } from "@/lib/safe-href";
import { markHref } from "@/lib/mark-href";

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
      return (
        // Demo renderer: remote CMS images, arbitrary hosts — plain <img> is
        // intentional (next/image needs per-host remotePatterns config).
        // eslint-disable-next-line @next/next/no-img-element
        <img
          key={key}
          src={src}
          alt={str(block.alt)}
          className="rounded-lg"
          loading="lazy"
          decoding="async"
        />
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
