"use client";

import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
} from "react";
import type { KeyboardEvent as ReactKeyboardEvent } from "react";
import { useRouter } from "next/navigation";
import { readerHref, typeLabel, type FindHit, type FindResponse } from "@/lib/find";

/**
 * Obsidian-style quick-switcher (Cmd-O / Ctrl-O).
 *
 * A global client island — mounted ONCE in the root layout, renders `null` until
 * opened, so it adds no SSR cost beyond a keydown listener and zero layout shift.
 * Speaks the SAME data path as the finder: it calls the existing same-origin
 * `/api/find` route (`?q=<query>` → {@link FindResponse}) and renders the returned
 * {@link FindHit}s, navigating with {@link readerHref}. No new search path.
 *
 * Shape used:
 *   request  GET /api/find?q=<query>          (engine defaults to postgres server-side)
 *   response { hits: FindHit[], ... }         — we read `.hits` only
 *   FindHit  { type, slug, title, ... }       — title (bold) + typeLabel(type) + /slug
 *   navigate readerHref(type, slug) → /d/<type>/<slug>  via useRouter().push
 */

const DEBOUNCE_MS = 150;

/** True when focus sits in a real text-entry surface OTHER than the switcher's
 * own input — so typing "o" in a search box or editor never triggers the
 * shortcut. The switcher input lives inside the dialog (data-quick-switcher),
 * which we explicitly exclude. */
function isEditableTarget(el: EventTarget | null): boolean {
  if (!(el instanceof HTMLElement)) return false;
  if (el.closest("[data-quick-switcher]")) return false;
  const tag = el.tagName;
  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return true;
  if (el.isContentEditable) return true;
  return false;
}

export function QuickSwitcher() {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [hits, setHits] = useState<FindHit[]>([]);
  const [loading, setLoading] = useState(false);
  const [active, setActive] = useState(0);

  const inputRef = useRef<HTMLInputElement | null>(null);
  const listRef = useRef<HTMLUListElement | null>(null);
  // Element focused right before opening — restored on close so the shortcut is
  // non-destructive to where the user was working.
  const restoreFocusRef = useRef<HTMLElement | null>(null);

  const listboxId = useId();
  const inputId = useId();
  const optionId = useCallback(
    (i: number) => `${listboxId}-opt-${i}`,
    [listboxId],
  );

  /* ── open / close ─────────────────────────────────────────────────────── */

  const close = useCallback(() => {
    setOpen(false);
    setQuery("");
    setHits([]);
    setActive(0);
    // Restore focus to wherever we came from (kept out of effect deps on
    // purpose — only ever read here).
    const prev = restoreFocusRef.current;
    restoreFocusRef.current = null;
    if (prev && document.contains(prev)) prev.focus();
  }, []);

  // Global shortcut listener. Cmd-O on mac (metaKey), Ctrl-O elsewhere. We
  // preventDefault so the browser's native "open file" dialog never fires.
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      // Accept either Cmd-O (mac) or Ctrl-O (win/linux) — no platform sniffing
      // (navigator.platform is deprecated and "" in some contexts, which would
      // misfire on a real Mac). The in-field guard below prevents accidental
      // triggers either way.
      const combo =
        (e.metaKey || e.ctrlKey) &&
        !e.altKey &&
        !e.shiftKey &&
        e.key.toLowerCase() === "o";
      if (combo) {
        // Ignore when typing in a field OTHER than our own input — so "Cmd-O"
        // there still can't open-file, but a plain "o" keystroke is untouched.
        if (!open && isEditableTarget(e.target)) return;
        e.preventDefault();
        if (open) close();
        else {
          restoreFocusRef.current =
            document.activeElement instanceof HTMLElement
              ? document.activeElement
              : null;
          setOpen(true);
        }
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [open, close]);

  // Auto-focus the input when the dialog opens.
  useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [open]);

  // Lock body scroll while the dialog is open (no background scroll behind the
  // overlay); restored on close/unmount.
  useEffect(() => {
    if (!open) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = prev;
    };
  }, [open]);

  /* ── search (debounced, race-guarded) ─────────────────────────────────── */

  // Out-of-order guard: every fetch carries a monotonically increasing seq;
  // a resolved response only lands if it is still the latest issued — a stale
  // reply for an older query can never overwrite a newer one. Pairs with an
  // AbortController so superseded requests are also cancelled on the wire.
  const seqRef = useRef(0);

  useEffect(() => {
    if (!open) return;
    const q = query.trim();
    // Bump the seq SYNCHRONOUSLY (it's a ref, not state) so any reply for a now-
    // superseded query is dropped immediately — the race guard doesn't wait for
    // the debounce. All actual setState happens inside the deferred work below,
    // never synchronously in the effect body (avoids cascading-render churn).
    const seq = ++seqRef.current;
    const ctrl = new AbortController();

    if (!q) {
      // Empty query → clear rows (deferred so it's not a sync setState).
      const t = setTimeout(() => {
        if (seq !== seqRef.current) return;
        setHits([]);
        setLoading(false);
        setActive(0);
      }, 0);
      return () => clearTimeout(t);
    }

    // Mark loading + fire the debounced fetch together, off the effect body.
    const timer = setTimeout(() => {
      setLoading(true);
      fetch(`/api/find?q=${encodeURIComponent(q)}`, { signal: ctrl.signal })
        .then((r) => r.json() as Promise<FindResponse>)
        .then((data) => {
          // Drop any reply that isn't the most recent issued.
          if (seq !== seqRef.current) return;
          setHits(data.hits ?? []);
          setActive(0);
          setLoading(false);
        })
        .catch((err) => {
          if ((err as Error).name === "AbortError") return;
          if (seq !== seqRef.current) return;
          setHits([]);
          setLoading(false);
        });
    }, DEBOUNCE_MS);
    return () => {
      clearTimeout(timer);
      ctrl.abort();
    };
  }, [query, open]);

  /* ── navigation ───────────────────────────────────────────────────────── */

  const navigate = useCallback(
    (hit: FindHit) => {
      // A slug-less hit would push /d/<type>/ (trailing slash) → 404; skip it,
      // matching the finder's `!hit.href` guard.
      if (!hit.slug) return;
      close();
      router.push(readerHref(hit.type, hit.slug));
    },
    [close, router],
  );

  // Keep the active row scrolled into view as ↑/↓ move it.
  useEffect(() => {
    if (!open) return;
    const el = listRef.current?.querySelector<HTMLElement>(
      `#${CSS.escape(optionId(active))}`,
    );
    el?.scrollIntoView({ block: "nearest" });
  }, [active, open, optionId]);

  const onInputKeyDown = (e: ReactKeyboardEvent<HTMLInputElement>) => {
    switch (e.key) {
      case "Escape":
        e.preventDefault();
        close();
        break;
      case "ArrowDown":
        e.preventDefault();
        if (hits.length) setActive((i) => (i + 1) % hits.length);
        break;
      case "ArrowUp":
        e.preventDefault();
        if (hits.length) setActive((i) => (i - 1 + hits.length) % hits.length);
        break;
      case "Enter": {
        e.preventDefault();
        const hit = hits[active];
        if (hit) navigate(hit);
        break;
      }
    }
  };

  const trimmed = query.trim();

  const status = useMemo(() => {
    if (!trimmed) return "Type to search documents…";
    if (loading) return "Searching…";
    if (hits.length === 0) return "No matches";
    return null;
  }, [trimmed, loading, hits.length]);

  if (!open) return null;

  return (
    <div
      data-quick-switcher=""
      className="fixed inset-0 z-[100] flex items-start justify-center"
      // Backdrop click closes — only when the click lands on the backdrop
      // itself, not on the panel inside it.
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) close();
      }}
    >
      {/* dimmed backdrop — pointer-events-none so a click in the dim area falls
          through to the container's onMouseDown (which closes); the panel below
          stops propagation, so only true backdrop clicks dismiss. */}
      <div
        aria-hidden
        className="pointer-events-none absolute inset-0 bg-zinc-950/40 backdrop-blur-sm"
      />

      {/* panel */}
      <div
        role="dialog"
        aria-modal="true"
        aria-label="Quick switcher — search documents"
        className="relative z-10 mt-[12vh] flex max-h-[70vh] w-full max-w-xl flex-col overflow-hidden rounded-xl border border-zinc-200 bg-white shadow-2xl dark:border-zinc-800 dark:bg-zinc-900"
        onMouseDown={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          // aria-modal focus containment: the input is the only focusable child,
          // so trap Tab/Shift+Tab inside the dialog. Escape is handled here too
          // (in addition to the input) so it closes even if focus has left the
          // input — close() is idempotent, so the redundancy is harmless.
          if (e.key === "Tab") {
            e.preventDefault();
          } else if (e.key === "Escape") {
            e.preventDefault();
            close();
          }
        }}
      >
        {/* search input */}
        <div className="flex items-center gap-2 border-b border-zinc-200 px-4 dark:border-zinc-800">
          <span aria-hidden className="text-lg text-zinc-400">
            ⌕
          </span>
          <label htmlFor={inputId} className="sr-only">
            Search documents
          </label>
          <input
            id={inputId}
            ref={inputRef}
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={onInputKeyDown}
            placeholder="Search documents…"
            autoComplete="off"
            autoCorrect="off"
            autoCapitalize="off"
            spellCheck={false}
            data-1p-ignore
            data-lpignore="true"
            role="combobox"
            aria-expanded
            aria-controls={listboxId}
            aria-autocomplete="list"
            aria-activedescendant={
              hits.length ? optionId(active) : undefined
            }
            className="w-full bg-transparent py-3.5 text-base text-zinc-900 outline-none placeholder:text-zinc-400 dark:text-zinc-100"
          />
          <kbd className="hidden shrink-0 rounded border border-zinc-200 px-1.5 py-0.5 font-mono text-[0.65rem] text-zinc-400 sm:inline-block dark:border-zinc-700">
            Esc
          </kbd>
        </div>

        {/* results */}
        {status ? (
          <p className="px-4 py-6 text-sm text-zinc-500 dark:text-zinc-400">
            {status}
          </p>
        ) : (
          <ul
            ref={listRef}
            id={listboxId}
            role="listbox"
            aria-label="Search results"
            className="flex min-h-0 flex-col overflow-y-auto py-1"
          >
            {hits.map((hit, i) => {
              const isActive = i === active;
              return (
                <li
                  key={`${hit.type}:${hit.id}`}
                  id={optionId(i)}
                  role="option"
                  aria-selected={isActive}
                  onMouseMove={() => setActive(i)}
                  onMouseDown={(e) => {
                    // Prevent the input losing focus before we navigate.
                    e.preventDefault();
                  }}
                  onClick={() => navigate(hit)}
                  className={`flex cursor-pointer items-baseline gap-2 px-4 py-2.5 ${
                    isActive
                      ? "bg-zinc-100 dark:bg-zinc-800"
                      : "hover:bg-zinc-50 dark:hover:bg-zinc-800/50"
                  }`}
                >
                  <span className="min-w-0 flex-1 truncate font-medium text-zinc-900 dark:text-zinc-100">
                    {hit.title}
                  </span>
                  {hit.slug ? (
                    <span className="hidden shrink-0 truncate font-mono text-xs text-zinc-400 sm:inline">
                      /{hit.slug}
                    </span>
                  ) : null}
                  <span className="shrink-0 rounded-full bg-zinc-200/70 px-2 py-0.5 font-mono text-[0.65rem] uppercase tracking-wide text-zinc-500 dark:bg-zinc-800 dark:text-zinc-400">
                    {typeLabel(hit.type)}
                  </span>
                </li>
              );
            })}
          </ul>
        )}

        {/* footer hint */}
        <div className="flex items-center gap-3 border-t border-zinc-200 px-4 py-2 text-[0.7rem] text-zinc-400 dark:border-zinc-800">
          <span>
            <kbd className="font-mono">↑↓</kbd> navigate
          </span>
          <span>
            <kbd className="font-mono">↵</kbd> open
          </span>
          <span>
            <kbd className="font-mono">esc</kbd> close
          </span>
        </div>
      </div>
    </div>
  );
}
