"use client";

import { useSyncExternalStore } from "react";

/**
 * Theme IDENTITY picker — the D36 web affordance for the theme-system epic.
 *
 * This is the orthogonal twin of <ThemeToggle/>: that flips light/dark MODE
 * (`data-theme`); this swaps the whole PALETTE (`data-bp-theme`) — evergreen,
 * ember, fjord. The two switches never touch each other's attribute.
 *
 * Mechanics mirror theme-toggle.tsx exactly: the initial identity is seeded
 * before paint by the inline script in layout.tsx (localStorage `bp_theme`,
 * defaulting to "evergreen"), so this component only mirrors + mutates that
 * value — never a page-level flash. State is read through useSyncExternalStore
 * off the already-applied `dataset.bpTheme`; it re-renders on the SAME
 * `bp:themechange` event the toggle dispatches, so the two stay in lockstep.
 *
 * The option list is hardcoded (D36 accepts this) — the emitted per-theme CSS
 * blocks in globals.css re-skin every --color-* var off the attribute. An id
 * with no matching block falls back to the bare (evergreen) declarations.
 */
const THEME_EVENT = "bp:themechange";

// Kept in sync with design/themes/*.json and the emitted [data-bp-theme] blocks.
const THEMES = ["evergreen", "ember", "fjord"] as const;
type BpTheme = (typeof THEMES)[number];

const LABELS: Record<BpTheme, string> = {
  evergreen: "Evergreen",
  ember: "Ember",
  fjord: "Fjord",
};

function normalize(id: string | undefined): BpTheme {
  return (THEMES as readonly string[]).includes(id ?? "") ? (id as BpTheme) : "evergreen";
}

function currentBpTheme(): BpTheme {
  return normalize(document.documentElement.dataset.bpTheme);
}

function subscribe(onChange: () => void): () => void {
  window.addEventListener(THEME_EVENT, onChange);
  return () => window.removeEventListener(THEME_EVENT, onChange);
}

export function ThemePicker({ className }: { className?: string }) {
  const theme = useSyncExternalStore<BpTheme>(
    subscribe,
    currentBpTheme,
    () => "evergreen", // server snapshot — real value lands right after hydration
  );

  const onChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    const next = normalize(e.target.value);
    document.documentElement.dataset.bpTheme = next;
    try {
      localStorage.setItem("bp_theme", next);
    } catch {
      /* private mode / storage disabled — the in-memory swap still applies */
    }
    window.dispatchEvent(new Event(THEME_EVENT));
  };

  return (
    <select
      value={theme}
      onChange={onChange}
      aria-label="Theme palette"
      className={className}
      style={{
        display: "inline-flex",
        alignItems: "center",
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
      {THEMES.map((id) => (
        <option key={id} value={id}>
          {LABELS[id]}
        </option>
      ))}
    </select>
  );
}
