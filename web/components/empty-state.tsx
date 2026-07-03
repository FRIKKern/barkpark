import type { ReactNode } from "react";

interface EmptyStateProps {
  /**
   * Decorative glyph shown above the message. Defaults to a subtle outlined
   * document that matches the reader's mono aesthetic; pass your own node to
   * override. Always rendered `aria-hidden` — the message carries the meaning.
   */
  icon?: ReactNode;
  /** The empty-state message (the "there's nothing here yet" copy). */
  children: ReactNode;
}

/** The default glyph — a quiet outlined document. */
function DocumentGlyph() {
  return (
    <svg
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.5}
      strokeLinecap="round"
      strokeLinejoin="round"
      className="h-8 w-8"
      aria-hidden
    >
      <path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z" />
      <path d="M14 3v5h5" />
    </svg>
  );
}

/**
 * Shared empty state for list routes (papers, tags, posts). Replaces the bare
 * one-line `<p className="text-zinc-500">No … yet.</p>` variants that had
 * drifted in tone/spacing across those routes with one centered, dashed-border
 * card so every "nothing here" reads the same. Presentation only — no behavior.
 */
export function EmptyState({ icon, children }: EmptyStateProps) {
  return (
    <div className="flex flex-col items-center gap-3 rounded-lg border border-dashed border-zinc-200 px-6 py-14 text-center dark:border-zinc-800">
      <div
        aria-hidden
        className="text-zinc-300 select-none dark:text-zinc-700"
      >
        {icon ?? <DocumentGlyph />}
      </div>
      <p className="text-sm text-zinc-500 dark:text-zinc-400">{children}</p>
    </div>
  );
}
