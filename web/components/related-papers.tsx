import Link from "next/link";
import {
  fetchRelated,
  isBacklinkOnly,
  creditedStrength,
  type RelatedEntry,
} from "@/lib/related";
import { readerHref } from "@/lib/find";

/**
 * Related section for the reader pane — a Server Component that fetches the
 * tag-weighted + backlink-fused related list for a document and renders it
 * below the article. Links go through `readerHref(type, slug)` so every entry
 * lands on the unified `/d/[type]/[slug]` reader by SLUG (the entry's `doc_id`
 * is the published slug, never a uuid).
 *
 * Empty related renders NOTHING — no heading, no empty-state chrome — so an
 * untagged / unreferenced document simply doesn't grow the section. Provenance
 * is honest: an entry that earned its place only through an inbound reference
 * (no shared tags) gets a subtle "Linked" badge instead of tag chips.
 */
export async function RelatedPapers({ docId }: { docId: string }) {
  const entries = await fetchRelated(docId);
  if (entries.length === 0) return null;

  return (
    <section
      aria-labelledby="related-papers-heading"
      className="mx-auto w-full max-w-2xl px-6 pb-10"
    >
      <h2
        id="related-papers-heading"
        className="mb-3 text-xs font-semibold uppercase tracking-wide text-zinc-500 dark:text-zinc-400"
      >
        Related
      </h2>
      <ul className="flex flex-col gap-2">
        {entries.map((entry) => (
          <RelatedRow key={entry.doc_id} entry={entry} />
        ))}
      </ul>
    </section>
  );
}

function RelatedRow({ entry }: { entry: RelatedEntry }) {
  const backlinkOnly = isBacklinkOnly(entry);
  return (
    <li>
      <Link
        href={readerHref(entry.type, entry.doc_id)}
        className="group flex flex-col gap-1.5 rounded-lg border border-zinc-200 px-3 py-2 transition-colors hover:border-zinc-300 hover:bg-zinc-50 dark:border-zinc-800 dark:hover:border-zinc-700 dark:hover:bg-zinc-900"
      >
        <span className="flex items-center gap-2">
          <span className="text-sm font-medium text-zinc-900 group-hover:underline dark:text-zinc-100">
            {entry.title ?? entry.doc_id}
          </span>
          {backlinkOnly ? (
            <span
              title="Links to this document — no shared tags"
              className="shrink-0 rounded-full border border-zinc-200 px-1.5 py-0.5 text-[0.65rem] font-medium uppercase tracking-wide text-zinc-500 dark:border-zinc-700 dark:text-zinc-400"
            >
              Linked
            </span>
          ) : null}
        </span>
        {entry.shared_tags.length > 0 ? (
          <span className="flex flex-wrap gap-1.5">
            {entry.shared_tags.map((tag) => (
              <span
                key={tag.tag}
                className="inline-flex items-center gap-1 rounded bg-zinc-100 px-1.5 py-0.5 text-[0.7rem] text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300"
                title={`shared tag — strength ${creditedStrength(tag)}`}
              >
                <span>{tag.tag}</span>
                <span className="tabular-nums text-zinc-400 dark:text-zinc-500">
                  {creditedStrength(tag)}
                </span>
              </span>
            ))}
          </span>
        ) : null}
      </Link>
    </li>
  );
}
