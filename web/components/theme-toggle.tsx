"use client";

import { useSyncExternalStore } from "react";

/**
 * Explicit light/dark toggle — the AC3 island for the Unified Aesthetic web
 * adoption. NO next-themes dependency: it flips `document.documentElement
 * .dataset.theme` (which the emitted `[data-theme="dark"]` block in globals.css
 * cascades over every --color-* var) and persists the choice to localStorage.
 *
 * The initial theme is seeded before paint by the inline script in layout.tsx
 * (localStorage.theme, falling back to prefers-color-scheme), so this component
 * only mirrors + mutates that value — it never causes a page-level flash.
 *
 * State is read through useSyncExternalStore rather than an effect: it reads the
 * already-applied `dataset.theme` on the client, a stable "light" on the server,
 * and re-renders on our own `themechange` event when the toggle flips it — the
 * hydration-safe, lint-clean way to surface a client-only DOM value.
 */
type Theme = "light" | "dark";

const THEME_EVENT = "bp:themechange";

function currentTheme(): Theme {
  return document.documentElement.dataset.theme === "dark" ? "dark" : "light";
}

function subscribe(onChange: () => void): () => void {
  window.addEventListener(THEME_EVENT, onChange);
  return () => window.removeEventListener(THEME_EVENT, onChange);
}

export function ThemeToggle({ className }: { className?: string }) {
  const theme = useSyncExternalStore<Theme>(
    subscribe,
    currentTheme,
    () => "light", // server snapshot — real value lands right after hydration
  );

  const toggle = () => {
    const next: Theme = currentTheme() === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    try {
      localStorage.setItem("theme", next);
    } catch {
      /* private mode / storage disabled — the in-memory flip still applies */
    }
    window.dispatchEvent(new Event(THEME_EVENT));
  };

  const label = theme === "dark" ? "Switch to light" : "Switch to dark";

  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={label}
      title={label}
      className={className}
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 8,
        padding: "6px 12px",
        borderRadius: 8,
        border: "1px solid var(--color-border)",
        background: "var(--color-surface)",
        color: "var(--color-text)",
        font: "inherit",
        fontSize: 13,
        cursor: "pointer",
      }}
    >
      <span aria-hidden>{theme === "dark" ? "☾" : "☀"}</span>
      {theme === "dark" ? "Dark" : "Light"}
    </button>
  );
}
