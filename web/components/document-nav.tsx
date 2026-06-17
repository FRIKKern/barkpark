"use client";

import { useEffect, useRef, type ReactNode } from "react";
import { usePathname } from "next/navigation";
import { useFinderNav } from "@/lib/finder-nav-context";

/** Everything a reader can land on, in document order. Excludes the roving
 * tabIndex=-1 sinks and hidden nodes. */
const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

/**
 * The Document column's keyboard layer — the right pane of the (finder) split.
 * Renders the detail <section> (persisted in the layout across doc navigations)
 * and owns the in-document key model:
 *
 *   • opened by keyboard (→/Enter in the list) → take WHOLE-DOC focus (this
 *     container). Signalled via the nav context's docFocusNonce.
 *   • whole-doc + ↓        → enter content (first focusable element)
 *   • content   + ↑/↓      → roving focus through every focusable element
 *   • content   + ↑-at-top → back to whole-doc focus
 *   • Esc                  → back to whole-doc focus
 *   • whole-doc + ←        → back to the List (hand focus to <Finder>)
 *
 * It works purely on rendered DOM (querySelector over FOCUSABLE), so every
 * document renderer — post-article, the Bulldocs reader, sheets — is handled
 * with zero per-renderer wiring. Inert unless the current route is a document
 * (`/d/…`); on `/` the right pane is the graph, which owns its own canvas keys.
 */
export function DocumentNav({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLElement | null>(null);
  const pathname = usePathname();
  const { docFocusNonce, requestListFocus } = useFinderNav();
  const isDoc = pathname?.startsWith("/d/") ?? false;

  // Keyboard opened a doc → grab whole-doc focus. Not path-gated: the container
  // always exists in the layout, and the nonce only ever bumps on a doc-open,
  // so focusing it the instant the intent fires is correct even mid-navigation.
  useEffect(() => {
    if (docFocusNonce > 0) ref.current?.focus();
  }, [docFocusNonce]);

  const onKeyDown = (e: React.KeyboardEvent<HTMLElement>) => {
    if (!isDoc) return;
    const root = ref.current;
    if (!root) return;

    const items = Array.from(
      root.querySelectorAll<HTMLElement>(FOCUSABLE),
    ).filter((el) => el.offsetParent !== null || el === document.activeElement);
    const atWholeDoc = document.activeElement === root;

    if (atWholeDoc) {
      if (e.key === "ArrowDown" && items.length) {
        e.preventDefault();
        items[0].focus();
      } else if (e.key === "ArrowLeft") {
        e.preventDefault();
        requestListFocus();
      }
      return;
    }

    const idx = items.indexOf(document.activeElement as HTMLElement);
    if (e.key === "ArrowDown") {
      e.preventDefault();
      if (idx >= 0 && idx < items.length - 1) items[idx + 1].focus();
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      if (idx > 0) items[idx - 1].focus();
      else root.focus(); // at the top → whole-doc focus
    } else if (e.key === "Escape") {
      e.preventDefault();
      root.focus();
    }
  };

  return (
    <section
      ref={ref}
      tabIndex={-1}
      onKeyDown={onKeyDown}
      aria-label={
        isDoc ? "Document — ↓ to read through it, ← back to results" : undefined
      }
      className="min-w-0 flex-1 overflow-y-auto outline-none"
    >
      {children}
    </section>
  );
}
