import type { ReactNode, Key } from "react";
import type { Block, Inline } from "@/lib/papers";
import { SheetSnapshot, type DenseSnapshot } from "@/components/sheet-grid";

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
    case "code":
      return <code className={inlineCode}>{el}</code>;
    case "link":
      return (
        <a href={href ?? "#"} className={linkClass} rel="noopener noreferrer">
          {el}
        </a>
      );
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
        const href = typeof m === "object" ? m?.href : undefined;
        if (name) el = wrapMark(name, href, el);
      }
      return <span key={key}>{el}</span>;
    }
    case "strong":
      return <strong key={key}>{renderInlines(node.children)}</strong>;
    case "em":
      return <em key={key}>{renderInlines(node.children)}</em>;
    case "code":
      return (
        <code key={key} className={inlineCode}>
          {(node as { value?: string }).value ?? ""}
        </code>
      );
    case "link":
      return (
        <a
          key={key}
          href={(node as { href?: string }).href ?? "#"}
          className={linkClass}
          rel="noopener noreferrer"
        >
          {renderInlines(node.children)}
        </a>
      );
    default:
      return null;
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
  warn: "border-amber-300/70 bg-amber-50 dark:border-amber-900/60 dark:bg-amber-950/30",
  success:
    "border-emerald-300/70 bg-emerald-50 dark:border-emerald-900/60 dark:bg-emerald-950/30",
  danger:
    "border-red-300/70 bg-red-50 dark:border-red-900/60 dark:bg-red-950/30",
};

/* ── blocks ─────────────────────────────────────────────────────────────── */

function renderBlock(block: Block, key: Key): ReactNode {
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
      return (
        <aside
          key={key}
          className={`rounded-lg border px-4 py-3 text-sm leading-6 text-zinc-700 dark:text-zinc-200 ${
            calloutTone[tone] ?? calloutTone.info
          }`}
        >
          {block.title ? (
            <p className="mb-1 font-medium">{str(block.title)}</p>
          ) : null}
          <div>{renderInlines(inlineArr(block.content))}</div>
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
    case "image":
      return (
        // Demo renderer: remote CMS images, arbitrary hosts — plain <img> is
        // intentional (next/image needs per-host remotePatterns config).
        // eslint-disable-next-line @next/next/no-img-element
        <img
          key={key}
          src={str(block.src)}
          alt={str(block.alt)}
          className="rounded-lg"
        />
      );
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
    case "action":
      return (
        <a
          key={key}
          href={str(block.href) || "#"}
          className="inline-flex w-fit items-center rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-zinc-50 transition-colors hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
        >
          {str(block.label) || "Open"}
        </a>
      );
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
    case "asciicast":
      return (
        <p key={key} className="text-sm text-zinc-500">
          ▶{" "}
          <a href={str(block.src) || "#"} className={linkClass}>
            {str(block.caption) || "terminal recording"}
          </a>
        </p>
      );
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
