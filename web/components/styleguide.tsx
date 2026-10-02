import type { CSSProperties } from "react";
import { ThemeToggle } from "@/components/theme-toggle";
import { ThemePicker } from "@/components/theme-picker";
import {
  chromeType,
  chromeTypeOrder,
  readingType,
  readingTypeOrder,
} from "@/lib/tokens.gen";

/* The living token spec for the web demo. Every swatch is painted with
 * `var(--color-…)`, resolving live from the GENERATED block in app/globals.css,
 * and BOTH type ladders below are read straight out of `lib/tokens.gen.ts` —
 * the same design/emit.mjs pass, from the same design/tokens.json leaves.
 * Retune a token, re-emit, and this page moves with it. There is no hand-kept
 * size table on this page: if a number here is wrong, tokens.json is wrong. */

// The emitted web color roles use the `--color-` prefix (Tailwind v4 @theme).
const PALETTE = [
  "primary",
  "primary-fg",
  "bg",
  "surface",
  "muted-surface",
  "text",
  "muted-text",
  "border",
  "ring",
  "accent",
] as const;

// The four semantic status voices (no -soft/-hsl on the web prefix).
const STATUS = ["ok", "warn", "danger", "info"] as const;

// UI chrome type ladder — the EMITTED `type.chrome` steps (size + line height +
// weight), in the emitter's own display order. Nothing is restated here.
const TYPE_SCALE = chromeTypeOrder.map((label) => ({ label, ...chromeType[label] }));

// Reading (prose) type ladder — the EMITTED `type.reading` steps. These are the
// very leaves paper-surface.css emits as --tok-reading-<step>-size/-lh, which
// `.bp-paper-surface h1/h2/h3` consume, so what this ladder shows is what
// @barkpark/react PortableDoc paints on /papers. The rendered h1 clamps
// responsively (clamp(28px, 8vw, …)); the token is the ceiling, shown here.
const READING_SCALE = readingTypeOrder.map((label) => ({ label, ...readingType[label] }));

const mono: CSSProperties = { fontFamily: "var(--font-mono, ui-monospace, monospace)" };

/* The page's OWN chrome spends the same emitted ladder it documents. A style
 * guide that sets its headings by hand while preaching the token is the exact
 * drift this page exists to catch, so every heading and lede below is a step. */
const step = (k: (typeof chromeTypeOrder)[number]): CSSProperties => ({
  fontSize: chromeType[k].size,
  lineHeight: chromeType[k].lineHeight,
  fontWeight: chromeType[k].weight,
});

export function Styleguide() {
  return (
    <main
      style={{
        maxWidth: 1080,
        margin: "0 auto",
        padding: "2.5rem 1.5rem 4rem",
        fontFamily: "var(--font-sans, system-ui, sans-serif)",
        color: "var(--color-text)",
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          gap: 16,
          margin: "0 0 .25rem",
        }}
      >
        <h1 style={{ margin: 0, ...step("2xl") }}>Web style guide</h1>
        {/* Two orthogonal switches (theme-system D36): the picker swaps the whole
            palette (data-bp-theme), the toggle flips light/dark (data-theme).
            Every swatch below re-skins live off the emitted vars for both. */}
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <ThemePicker />
          <ThemeToggle />
        </div>
      </div>
      <p style={{ color: "var(--color-muted-text)", maxWidth: "66ch", margin: "0 0 1.75rem" }}>
        The living token spec for the web demo. Every swatch is painted with{" "}
        <code style={mono}>var(--color-…)</code> straight from the GENERATED block in{" "}
        <code style={mono}>app/globals.css</code> — emitted by <code style={mono}>design/emit.mjs</code>{" "}
        from <code style={mono}>design/tokens.json</code>. Retint a token, re-emit, and this page
        moves with it (W1.4 scaffold).
      </p>

      <section style={{ margin: "0 0 2.5rem" }}>
        <h2 style={{ margin: "0 0 .75rem", ...step("xl") }}>Palette</h2>
        <div
          style={{
            display: "grid",
            gridTemplateColumns: "repeat(auto-fill, minmax(150px, 1fr))",
            gap: 10,
          }}
        >
          {PALETTE.map((role) => (
            <div
              key={role}
              style={{
                border: "1px solid var(--color-border)",
                borderRadius: 6,
                overflow: "hidden",
              }}
            >
              <div style={{ height: 44, background: `var(--color-${role})` }} />
              <div style={{ padding: "6px 8px", background: "var(--color-surface)" }}>
                <div style={{ ...mono, fontSize: 11, color: "var(--color-text)" }}>{role}</div>
                <div style={{ ...mono, fontSize: 10, color: "var(--color-muted-text)" }}>
                  var(--color-{role})
                </div>
              </div>
            </div>
          ))}
        </div>
      </section>

      <section style={{ margin: "0 0 2.5rem" }}>
        <h2 style={{ margin: "0 0 .25rem", ...step("xl") }}>Status roles</h2>
        <p style={{ color: "var(--color-muted-text)", ...step("sm"), margin: "0 0 .75rem" }}>
          The four semantic voices — ok / warn / danger / info.
        </p>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 12 }}>
          {STATUS.map((role) => (
            <div
              key={role}
              style={{
                display: "flex",
                alignItems: "center",
                gap: 10,
                padding: "10px 14px",
                borderRadius: 6,
                border: "1px solid var(--color-border)",
              }}
            >
              <span
                style={{
                  width: 18,
                  height: 18,
                  borderRadius: 999,
                  background: `var(--color-${role})`,
                }}
              />
              <span style={{ ...mono, fontSize: 12, color: "var(--color-text)" }}>
                {role} · var(--color-{role})
              </span>
            </div>
          ))}
        </div>
      </section>

      <section>
        <h2 style={{ margin: "0 0 .25rem", ...step("xl") }}>
          Type ladder — UI chrome
        </h2>
        <p style={{ color: "var(--color-muted-text)", ...step("sm"), margin: "0 0 .75rem" }}>
          Read live from <code style={mono}>tokens.json type.chrome</code> via the emitted{" "}
          <code style={mono}>lib/tokens.gen.ts</code> — size, line height and weight all come
          from the token. No copy of this scale lives in this file.
        </p>
        {TYPE_SCALE.map(({ label, size, lineHeight, weight }) => (
          <div
            key={label}
            style={{ display: "flex", alignItems: "baseline", gap: 16, marginBottom: 8 }}
          >
            <span style={{ ...mono, fontSize: 11, color: "var(--color-muted-text)", flex: "0 0 140px" }}>
              {label} · {size}px / {lineHeight} / {weight}
            </span>
            <span style={{ fontSize: size, lineHeight, fontWeight: weight }}>
              Fleet at a glance
            </span>
          </div>
        ))}
      </section>

      <section style={{ marginTop: "2rem" }}>
        <h2 style={{ margin: "0 0 .25rem", ...step("xl") }}>
          Type ladder — reading (paper surface)
        </h2>
        <p style={{ color: "var(--color-muted-text)", ...step("sm"), margin: "0 0 .75rem" }}>
          Read live from <code style={mono}>tokens.json type.reading</code> via the same emitted{" "}
          <code style={mono}>lib/tokens.gen.ts</code>. These are the leaves{" "}
          <code style={mono}>paper-surface.css</code> emits as{" "}
          <code style={mono}>--tok-reading-*</code>, which the{" "}
          <code style={mono}>.bp-paper-surface</code> heading rules consume — so this ladder and
          the headings <code style={mono}>PortableDoc</code> paints on <code style={mono}>/papers</code>{" "}
          move together. The shipped h1 clamps responsively; the token is its ceiling.
        </p>
        {READING_SCALE.map(({ label, size, lineHeight, weight }) => (
          <div
            key={label}
            style={{ display: "flex", alignItems: "baseline", gap: 16, marginBottom: 8 }}
          >
            <span style={{ ...mono, fontSize: 11, color: "var(--color-muted-text)", flex: "0 0 140px" }}>
              {label} · {size}px / {lineHeight} / {weight}
            </span>
            <span
              style={{
                fontSize: size,
                lineHeight,
                fontWeight: weight,
                fontFamily: 'var(--font-reading, "Iowan Old Style", Palatino, Georgia, serif)',
              }}
            >
              Fleet at a glance
            </span>
          </div>
        ))}
      </section>
    </main>
  );
}
