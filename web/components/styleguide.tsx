import type { CSSProperties } from "react";

/* Unified-aesthetic W1.4 scaffold — the living token spec for the web demo.
 * Every swatch is painted with `var(--color-…)`, resolving live from the
 * GENERATED block in app/globals.css (emitted by design/emit.mjs from
 * design/tokens.json). Retint a token, re-emit, and this page moves with it.
 * Scaffold only: palette + status roles + the UI type ladder. Full content
 * adoption (Tailwind utility migration, wiring emitted --text-* vars) is W3.9. */

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

// UI type ladder — mirrors tokens.json `type.ui`. NOTE: web emits only colors,
// not --text-* vars, so these sizes are a preview; W3.9 wires the emitted scale.
const TYPE_SCALE: Array<{ label: string; size: number; lh: number; weight: number }> = [
  { label: "2xl", size: 26, lh: 1.2, weight: 700 },
  { label: "xl", size: 20, lh: 1.3, weight: 700 },
  { label: "lg", size: 16, lh: 1.4, weight: 600 },
  { label: "base", size: 14, lh: 1.5, weight: 400 },
  { label: "sm", size: 13, lh: 1.45, weight: 400 },
  { label: "xs", size: 12, lh: 1.4, weight: 400 },
];

const mono: CSSProperties = { fontFamily: "var(--font-mono, ui-monospace, monospace)" };

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
      <h1 style={{ margin: "0 0 .25rem", fontSize: 26, fontWeight: 700 }}>Web style guide</h1>
      <p style={{ color: "var(--color-muted-text)", maxWidth: "66ch", margin: "0 0 1.75rem" }}>
        The living token spec for the web demo. Every swatch is painted with{" "}
        <code style={mono}>var(--color-…)</code> straight from the GENERATED block in{" "}
        <code style={mono}>app/globals.css</code> — emitted by <code style={mono}>design/emit.mjs</code>{" "}
        from <code style={mono}>design/tokens.json</code>. Retint a token, re-emit, and this page
        moves with it (W1.4 scaffold).
      </p>

      <section style={{ margin: "0 0 2.5rem" }}>
        <h2 style={{ margin: "0 0 .75rem", fontSize: 20, fontWeight: 700 }}>Palette</h2>
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
        <h2 style={{ margin: "0 0 .25rem", fontSize: 20, fontWeight: 700 }}>Status roles</h2>
        <p style={{ color: "var(--color-muted-text)", fontSize: 13, margin: "0 0 .75rem" }}>
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
        <h2 style={{ margin: "0 0 .25rem", fontSize: 20, fontWeight: 700 }}>
          Type ladder — UI chrome
        </h2>
        <p style={{ color: "var(--color-muted-text)", fontSize: 13, margin: "0 0 .75rem" }}>
          Mirrors <code style={mono}>tokens.json type.ui</code>. Web emits only color vars, so
          sizes here are a preview — W3.9 wires the emitted scale in.
        </p>
        {TYPE_SCALE.map(({ label, size, lh, weight }) => (
          <div
            key={label}
            style={{ display: "flex", alignItems: "baseline", gap: 16, marginBottom: 8 }}
          >
            <span style={{ ...mono, fontSize: 11, color: "var(--color-muted-text)", flex: "0 0 140px" }}>
              {label} · {size}px / {lh}
            </span>
            <span style={{ fontSize: size, lineHeight: lh, fontWeight: weight }}>
              Fleet at a glance
            </span>
          </div>
        ))}
      </section>
    </main>
  );
}
