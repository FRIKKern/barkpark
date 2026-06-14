import type { GenericDoc } from "@/lib/get-document";
import { typeLabel } from "@/lib/find";

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
  // Common body/excerpt fields are rendered as prose, not list rows.
  "body",
  "excerpt",
  "description",
  "bio",
]);

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
  return (
    (typeof value === "string" && value.length > 0) ||
    typeof value === "number" ||
    typeof value === "boolean"
  );
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

  // Collect the remaining showable scalar fields, in stable key order.
  const fields = Object.entries(doc)
    .filter(([k, v]) => isShowableField(k, v))
    .map(([k, v]) => [k, v as FieldValue] as const);

  // Prose: prefer an explicit excerpt/description/bio, else a string body.
  const prose =
    (typeof doc.excerpt === "string" && doc.excerpt) ||
    (typeof doc.description === "string" && doc.description) ||
    (typeof doc.bio === "string" && doc.bio) ||
    (typeof doc.body === "string" && doc.body) ||
    null;

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

      {(doc.slug || updated || created || fields.length > 0) && (
        <dl className="grid grid-cols-[max-content_1fr] gap-x-6 gap-y-2 text-sm">
          {doc.slug ? (
            <Row label="Slug">
              <code className="rounded bg-zinc-100 px-1.5 py-0.5 font-mono text-[0.85em] dark:bg-zinc-800">
                {doc.slug}
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
      <dt className="font-medium text-zinc-500 dark:text-zinc-400">{label}</dt>
      <dd className="text-zinc-800 dark:text-zinc-200">{children}</dd>
    </>
  );
}
