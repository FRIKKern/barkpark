import type { GenericDoc } from "@/lib/get-document";
import { typeLabel } from "@/lib/find";
import { slugText } from "@/lib/slug-text";

/**
 * Keys we never surface in the field list: internal ids/revisions, the title
 * (already the heading), the slug + dates (rendered explicitly), and any
 * `_`-prefixed system column we don't special-case. The check below also drops
 * non-primitive values (nested objects, arrays) — a meta card is a summary, not
 * a JSON dump.
 */
const SKIP_KEYS = new Set([
  "_id",
  "_rev",
  "_type",
  "_publishedId",
  "_draft",
  "title",
  "slug",
  "_updatedAt",
  "_createdAt",
  // Common excerpt fields are rendered as prose, not list rows.
  "excerpt",
  "description",
  "bio",
  // Body-shaped fields NEVER surface here in any form: `blocks`/`body` render
  // through PortableDoc, and `body_html` is the server-rendered HTML twin —
  // multi-KB markup that once escaped into this list as a raw dump (the single
  // ugliest surface a stranger could hit). document-detail owns rendering them.
  "body",
  "body_html",
  "body_text",
  "blocks",
]);

/**
 * Hard ceiling for any single printed value. A summary card shows scalars —
 * ids, dates, counts, short labels. Anything longer is body-shaped content
 * that belongs to a real renderer, not a definition list.
 */
const MAX_FIELD_CHARS = 500;

/** Markup-shaped text (an HTML/XML tag anywhere in the value). We never print
 * markup as text — escaped tag soup in a `<dd>` is a dump, not a summary. */
function looksLikeHtml(value: string): boolean {
  return /<\/?[a-z][^>]*>/i.test(value);
}

/** Format an ISO-ish date string to a readable label, or null if unparseable. */
function formatDate(value: unknown): string | null {
  if (typeof value !== "string" || value.length === 0) return null;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return null;
  // timeZone:"UTC" → identical server/client text (avoids a React #418
  // hydration mismatch when the server is UTC and the browser is not).
  return new Intl.DateTimeFormat("en-US", {
    timeZone: "UTC",
    year: "numeric",
    month: "long",
    day: "numeric",
  }).format(d);
}

/** A primitive worth showing in the definition list. */
type FieldValue = string | number | boolean;

function isShowableField(key: string, value: unknown): value is FieldValue {
  if (SKIP_KEYS.has(key)) return false;
  if (key.startsWith("_")) return false; // other system columns
  if (typeof value === "string") {
    // Never print a blob or markup: >500 chars or html-shaped strings are
    // body content wearing a field name, not summary scalars.
    return (
      value.length > 0 &&
      value.length <= MAX_FIELD_CHARS &&
      !looksLikeHtml(value)
    );
  }
  return typeof value === "number" || typeof value === "boolean";
}

function fieldDisplay(value: FieldValue): string {
  if (typeof value === "boolean") return value ? "Yes" : "No";
  return String(value);
}

/** Humanise a camelCase / snake_case key into a label ("publishedAt" → "Published at"). */
function humanizeKey(key: string): string {
  const spaced = key
    .replace(/_/g, " ")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .toLowerCase()
    .trim();
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

/**
 * A clean summary card for view-only document types (page / author / category /
 * project, plus any unknown `_type`). These have no bespoke reader, but a click
 * should never dead-end — so we show the title, a type badge, a definition list
 * of the doc's notable scalar fields (slug, dates, strings, numbers), and any
 * excerpt/bio/description prose it carries.
 */
export function MetaCard({ doc, type }: { doc: GenericDoc; type: string }) {
  const updated = formatDate(doc._updatedAt);
  const created = formatDate(doc._createdAt);
  // Slugs arrive as a bare string or the object form { current }; normalise to
  // text so an object never reaches JSX (React #31 crashes the whole pane).
  const slug = slugText(doc.slug);

  // Collect the remaining showable scalar fields, in stable key order.
  const fields = Object.entries(doc)
    .filter(([k, v]) => isShowableField(k, v))
    .map(([k, v]) => [k, v as FieldValue] as const);

  // Prose: an explicit excerpt/description/bio, plain text only. Body-shaped
  // keys (`body`, `body_html`) never render here — they belong to the real
  // readers — and an html-shaped candidate is dropped rather than dumped.
  // Long plain text is clamped: this is a summary card, not a reader.
  const proseRaw =
    (typeof doc.excerpt === "string" && doc.excerpt) ||
    (typeof doc.description === "string" && doc.description) ||
    (typeof doc.bio === "string" && doc.bio) ||
    null;
  const prose =
    proseRaw && !looksLikeHtml(proseRaw)
      ? proseRaw.length > MAX_FIELD_CHARS
        ? `${proseRaw.slice(0, MAX_FIELD_CHARS).trimEnd()}…`
        : proseRaw
      : null;

  return (
    <article className="mx-auto flex w-full max-w-2xl flex-col gap-6 px-6 py-10">
      <header className="flex flex-col gap-3 border-b border-zinc-200 pb-6 dark:border-zinc-800">
        <span className="inline-flex w-fit items-center rounded-md bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
          {typeLabel(type)}
        </span>
        <h1 className="text-4xl font-semibold tracking-tight text-balance">
          {doc.title ?? "(untitled)"}
        </h1>
      </header>

      {prose ? (
        <p className="text-lg leading-relaxed whitespace-pre-wrap text-zinc-600 dark:text-zinc-300">
          {prose}
        </p>
      ) : null}

      {(slug || updated || created || fields.length > 0) && (
        <dl className="grid grid-cols-[max-content_1fr] gap-x-6 gap-y-2 text-sm">
          {slug ? (
            <Row label="Slug">
              <code className="rounded bg-zinc-100 px-1.5 py-0.5 font-mono text-[0.85em] dark:bg-zinc-800">
                {slug}
              </code>
            </Row>
          ) : null}

          {fields.map(([key, value]) => (
            <Row key={key} label={humanizeKey(key)}>
              {fieldDisplay(value)}
            </Row>
          ))}

          {updated ? <Row label="Updated">{updated}</Row> : null}
          {created ? <Row label="Created">{created}</Row> : null}
        </dl>
      )}
    </article>
  );
}

/** One `<dt>`/`<dd>` pair in the definition list. */
function Row({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <>
      <dt className="font-medium text-muted-text">{label}</dt>
      <dd className="text-zinc-800 dark:text-zinc-200">{children}</dd>
    </>
  );
}
