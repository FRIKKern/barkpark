/**
 * The "/" right pane — the empty/welcome state shown before any document is
 * opened. The <Finder> itself lives in the layout (left rail); this is the
 * `children` segment for "/".
 *
 * `hidden md:flex`: on mobile the finder owns the full screen, so the welcome
 * hint stays out of the way; on desktop it fills the right column with a
 * centered prompt until a hit is clicked.
 */
export default function FinderWelcome() {
  return (
    <div className="hidden h-full flex-col items-center justify-center gap-4 px-8 text-center md:flex">
      <div
        aria-hidden
        className="text-4xl text-zinc-300 select-none dark:text-zinc-700"
      >
        ←
      </div>
      <p className="max-w-xs text-sm text-zinc-500 dark:text-zinc-400">
        Select a document to read it here.
      </p>
      <p className="max-w-xs text-xs text-zinc-400 dark:text-zinc-600">
        Papers, posts, sheets, and metadata — every result opens in full, right
        in this pane.
      </p>
    </div>
  );
}
