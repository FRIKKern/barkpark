import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { getPaper } from "@/lib/get-paper";
import { paperBlocks, paperTitle, paperExcerpt } from "@/lib/papers";
import { PortableDoc } from "@/components/portable-doc";

// ISR: the reader is cached (via getPaper's unstable_cache) and revalidated
// every 5 min; on-demand for unknown slugs. revalidateTag("doc:paper") busts it
// for a published change.
export const revalidate = 300;

type Params = Promise<{ slug: string }>;

export async function generateMetadata({
  params,
}: {
  params: Params;
}): Promise<Metadata> {
  const { slug } = await params;
  const { paper, error } = await getPaper(slug);
  // 404 here (metadata resolves before the response status commits) so a
  // missing paper yields a real HTTP 404, not a 200.
  if (!paper && !error) notFound();
  if (!paper) return { title: "Paper unavailable · Barkpark" };
  const description = paperExcerpt(paper) ?? undefined;
  return {
    title: `${paperTitle(paper)} · Barkpark`,
    description,
    openGraph: { title: paperTitle(paper), description, type: "article" },
  };
}

export default async function PaperReader({ params }: { params: Params }) {
  const { slug } = await params;
  const { paper, error } = await getPaper(slug);

  if (!error && !paper) notFound();

  return (
    <main className="mx-auto flex min-h-screen w-full max-w-2xl flex-col gap-8 px-6 py-16">
      <Link
        href="/papers"
        className="text-sm text-zinc-500 transition-colors hover:text-zinc-900 dark:hover:text-zinc-200"
      >
        ← all papers
      </Link>

      {error ? (
        <section className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-900 dark:border-red-900/60 dark:bg-red-950/40 dark:text-red-200">
          <strong className="font-medium">Failed to load paper.</strong>
          <pre className="mt-2 whitespace-pre-wrap text-xs">{error}</pre>
        </section>
      ) : paper ? (
        <article>
          <PortableDoc blocks={paperBlocks(paper)} />
        </article>
      ) : null}
    </main>
  );
}
