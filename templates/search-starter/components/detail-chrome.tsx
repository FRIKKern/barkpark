"use client";

import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { typeLabel } from "@/lib/find";

interface DetailChromeProps {
  /** Doc title for the bar. Falls back to the slug upstream when absent. */
  title: string;
  /** Document `_type` — drives the badge label. */
  type: string;
  /**
   * Optional standalone reader URL (e.g. `/posts/:slug`, `/papers/:slug`). When
   * given, an "open standalone ↗" link is shown. Same-tab — `target="_blank"`
   * is deliberately not set (the spec leaves a new tab optional).
   */
  standaloneHref?: string;
}

/**
 * Sticky header inside the detail pane: the doc title, a small type badge, an
 * optional "open standalone" link, and a close button.
 *
 * Close is a `<Link>` back to `/?<currentQuery>` — the finder's search state
 * lives in the query string, so preserving it here means closing a doc returns
 * the finder exactly as the user left it (query, engine, facets, sort). It's a
 * client component solely to read `useSearchParams()` for that round-trip.
 */
export function DetailChrome({ title, type, standaloneHref }: DetailChromeProps) {
  const params = useSearchParams();
  const query = params.toString();
  const closeHref = query ? `/?${query}` : "/";

  return (
    <header className="sticky top-0 z-10 flex items-center gap-3 border-b border-zinc-200 bg-white/90 px-4 py-3 backdrop-blur dark:border-zinc-800 dark:bg-zinc-950/90">
      <span className="inline-flex shrink-0 items-center rounded-md bg-zinc-100 px-2 py-0.5 text-xs font-medium text-zinc-600 dark:bg-zinc-800 dark:text-zinc-300">
        {typeLabel(type)}
      </span>

      <h2 className="min-w-0 flex-1 truncate text-sm font-medium text-zinc-900 dark:text-zinc-100">
        {title}
      </h2>

      {standaloneHref ? (
        <Link
          href={standaloneHref}
          className="shrink-0 text-xs text-zinc-500 transition-colors hover:text-zinc-900 dark:hover:text-zinc-200"
        >
          open standalone ↗
        </Link>
      ) : null}

      <Link
        href={closeHref}
        aria-label="Close"
        className="shrink-0 rounded-md p-1 text-zinc-400 transition-colors hover:bg-zinc-100 hover:text-zinc-900 dark:hover:bg-zinc-800 dark:hover:text-zinc-100"
      >
        <svg
          width="18"
          height="18"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden
        >
          <path d="M18 6 6 18" />
          <path d="m6 6 12 12" />
        </svg>
      </Link>
    </header>
  );
}
