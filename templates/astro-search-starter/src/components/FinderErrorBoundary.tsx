// Defense-in-depth for the finder island. `index.astro` mounts ONLY this island
// (`client:only`), so an uncaught throw anywhere in the finder tree unmounts the
// React root with NO SSR fallback — the entire page goes blank. That is exactly
// the failure the user hit ("everything disappears"): a single render error in a
// deep child took the whole surface down.
//
// A fix + a unit gate stop the KNOWN cause (the seed-shape mismatch), but any
// future render error would blank the page again. This boundary makes the worst
// case a graceful, on-brand fallback instead: the page keeps its chrome, tells
// the visitor what happened, and offers a reload — the finder never fully
// disappears again. Error boundaries must be class components (there is no hook
// equivalent for `getDerivedStateFromError`).
import { Component, type ReactNode } from 'react'

interface Props {
  children: ReactNode
}
interface State {
  error: Error | null
}

export class FinderErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error): void {
    // Surface it for diagnosis — a render crash should be loud in the console,
    // never a silent blank. (No network beacon: a static site has no collector.)
    // eslint-disable-next-line no-console
    console.error('[finder] render crashed — showing the fallback:', error)
  }

  render(): ReactNode {
    if (!this.state.error) return this.props.children

    return (
      <main className="mx-auto flex min-h-screen w-full max-w-4xl flex-col gap-8 px-6 py-12">
        <header className="flex flex-col gap-3 border-b border-zinc-200 pb-6 dark:border-zinc-800">
          <a
            href="/"
            className="text-sm text-zinc-500 transition-colors hover:text-zinc-900 dark:hover:text-zinc-200"
          >
            ← Barkpark
          </a>
          <h1 className="text-4xl font-semibold tracking-tight">Search hit a snag</h1>
        </header>

        <div className="flex flex-col items-start gap-4 rounded-lg border border-zinc-200 bg-zinc-50 p-6 dark:border-zinc-800 dark:bg-zinc-900/40">
          <p className="text-zinc-600 dark:text-zinc-300">
            Something went wrong loading search on this page. Your content is fine —
            this is just the search interface. Reloading usually clears it.
          </p>
          <button
            type="button"
            onClick={() => {
              if (typeof window !== 'undefined') window.location.reload()
            }}
            className="rounded-lg bg-zinc-900 px-4 py-2 text-sm font-medium text-zinc-50 transition-colors hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-zinc-300"
          >
            Reload search
          </button>
        </div>
      </main>
    )
  }
}
