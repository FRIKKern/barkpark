// design/emit/pages.mjs — the page-scoped Studio surfaces: login, error, status, /sheets.
// Part of design/emit.mjs, the W1.2 emitter, moved here with no change in behaviour.
// design/emit.mjs imports this module and re-exports its public names.

import { loadThemes, THEME_BANNER, themeBlocks, tokens } from "./source.mjs";
import { alpha, hsl, motionVarLines, softAlpha } from "./vocab.mjs";

// ── page-scoped surfaces (self-contained Studio pages) ───────────────────────
// The login / error / status / sheets pages each carry their OWN scoped <style>
// (:root or a scoped selector) — the root-layout emitted tokens do NOT cascade
// in — so each de-literalizes onto its OWN page-scoped marker-splice block.
// These are CSS artifacts like the surfaces above, but their marker sits inside
// an .ex/.heex <style> (heredoc or ~H), so each builder bakes the page's own
// indentation. An "hsl OR var() OR #hex passthrough" value formatter lets a
// value be a token channel (→ hsl()), a var(--role) reference, or a raw hex.
const pageVal = (v) => (v.startsWith("var(") || v.startsWith("#") ? v : hsl(v));

// ── surface: login (api/lib/barkpark_web/controllers/session_html.ex) ────────
// The auth pages' brand override — evergreen --primary/--ring (the exact emitted
// primary/ring tokens) + the decoupled auth button fills (color.authButton),
// scoped under .bp-auth. Light on the scoped selector; dark keyed on
// html[data-theme="dark"] .bp-auth (Studio themes via the data-theme attribute).
// Indented 6 spaces to sit inside the ~H <style>. The ring-soft alpha reuses the
// shared softAlpha convention (0.15 light / 0.2 dark).
// The auth brand-override rows for one mode, from a palette `t`. primary/primary-
// fg/ring are theme-varying; the --btn-* auth-button fills are theme-invariant
// passthrough (color.authButton), but they are NOT positionally counted by
// check.mjs, so they are safely re-declared in the per-theme block (D25 only bans
// --life-*/--provider-*/.bp-lg--/.bp-inst--).
const authRows = (theme, t = tokens) => {
  const c = t.color;
  const ab = c.authButton;
  return [
    `--primary: ${hsl(c.primary[theme])};`,
    `--primary-fg: ${hsl(c["primary-fg"][theme])};`,
    `--ring: ${hsl(c.ring[theme])};`,
    `--ring-soft: hsl(${c.ring[theme]} / ${alpha(softAlpha[theme])});`,
    `--btn-bg: ${pageVal(ab.bg[theme])};`,
    `--btn-fg: ${pageVal(ab.fg[theme])};`,
    `--btn-bg-hover: ${pageVal(ab.bgHover[theme])};`,
  ];
};

const sessionAuthThemeBlock = (name, t) => {
  const ind = "      ";
  return [
    ind + `html[data-bp-theme="${name}"] .bp-auth {`,
    ...authRows("light", t).map((l) => ind + "  " + l),
    ind + "}",
    ind + `html[data-bp-theme="${name}"][data-theme="dark"] .bp-auth {`,
    ...authRows("dark", t).map((l) => ind + "  " + l),
    ind + "}",
  ].join("\n");
};

function sessionAuthBlock(themes = loadThemes()) {
  const ind = "      ";
  const lines = [
    ind + ".bp-auth {",
    ...authRows("light").map((l) => ind + "  " + l),
    // Motion ladder on the login card's own root scope (the page has no other):
    // `.bp-auth-btn` is a descendant, so the ladder reaches it by inheritance.
    ...motionVarLines().map((l) => ind + "  " + l),
    ind + "}",
    ind + 'html[data-theme="dark"] .bp-auth {',
    ...authRows("dark").map((l) => ind + "  " + l),
    ind + "}",
  ];
  const themed = themeBlocks(themes, sessionAuthThemeBlock);
  if (themed) lines.push(ind + THEME_BANNER, themed);
  return lines.join("\n");
}

// ── surface: error page (api/lib/barkpark_web/controllers/error_html.ex) ─────
// The 404/500 page is INTENTIONALLY ALWAYS-DARK (a stark error card, no theme
// switch). De-literalized WITHOUT becoming theme-aware: a single fixed-dark
// :root carrying color.errorPage (bg/fg/muted, single values). Indented 10
// spaces to sit inside the heredoc <style>.
//
// Shared verbatim by `studio_refusal_html.ex` (task-47ab98b3226672ef) — the
// Studio membership-refusal page is the SAME self-contained, always-dark
// card family as the 404/500 page (no layout, no theme switch), so it reuses
// this exact builder + the same color.errorPage token rather than inventing
// a second palette for one more error-shaped page.
function errorPageBlock() {
  const e = tokens.color.errorPage;
  const ind = "          ";
  return [
    ind + ":root {",
    ind + `  --err-bg: ${e.bg};`,
    ind + `  --err-fg: ${e.fg};`,
    ind + `  --err-muted: ${e.muted};`,
    ind + "}",
  ].join("\n");
}

// ── surface: status page (api/lib/barkpark_web/controllers/status_controller.ex)
// The public /status page's self-contained chrome palette (color.statusChrome,
// theme-aware via prefers-color-scheme). color-scheme + the health-severity DATA
// tones stay OUTSIDE this block — the tones are inline-style DATA emitted via
// BarkparkWeb.Studio.TokensGen.status_health/0. Indented 6 spaces (heredoc
// <style>). Hex passthrough (bespoke zinc, byte-preserving the chrome).
// statusChrome is a theme-INVARIANT passthrough family (charter D21), so the
// per-theme block re-declares the same bespoke zinc under the attribute hook —
// the structural guarantee that theme identity reaches every surface even where
// its palette does not vary. MEDIA surface: mode stays prefers-color-scheme, so
// the per-theme dark re-declaration nests inside the same @media idiom.
const statusChromeVars = (sc, theme) =>
  ["bg", "fg", "muted", "card", "line"].map((r) => `--${r}:${sc[r][theme]};`).join(" ");

const statusChromeThemeBlock = (name, t) => {
  const sc = t.color.statusChrome;
  const ind = "      ";
  return [
    ind + `html[data-bp-theme="${name}"] { ${statusChromeVars(sc, "light")} }`,
    ind + `@media (prefers-color-scheme: dark){ html[data-bp-theme="${name}"]{ ${statusChromeVars(sc, "dark")} } }`,
  ].join("\n");
};

function statusChromeBlock(themes = loadThemes()) {
  const sc = tokens.color.statusChrome;
  const ind = "      ";
  const lines = [
    ind + `:root { ${statusChromeVars(sc, "light")} }`,
    ind + `@media (prefers-color-scheme: dark){ :root{ ${statusChromeVars(sc, "dark")} } }`,
  ];
  const themed = themeBlocks(themes, statusChromeThemeBlock);
  if (themed) lines.push(ind + THEME_BANNER, themed);
  return lines.join("\n");
}

// ── surface: /sheets reader (api/lib/barkpark_web/layouts/sheets.html.heex) ──
// The parchment reader's info-blue link + focus ring (color.readerInfo): a
// WCAG-safe darker blue-600 on the light parchment, lifting to info-role
// blue-500 on the dark parchment. --ring binds to --info so the reader's focus
// rings stay blue (their prior hardcoded fallback intent). Indented 4 spaces
// (heex <style>). Sits AFTER the hand-authored parchment :root; global :root
// vars, so they cascade to .sheet-link / .btn / .sheet-* focus rules.
// readerInfo is a theme-INVARIANT passthrough family (charter D21); the per-theme
// block carries the same info-blue under the attribute hook. MEDIA surface: the
// per-theme dark re-declaration nests inside the same prefers-color-scheme idiom.
const sheetsThemeBlock = (name, t) => {
  const ri = t.color.readerInfo;
  const ind = "    ";
  return [
    ind + `html[data-bp-theme="${name}"] { --info: ${ri.light}; --ring: var(--info); }`,
    ind + `@media (prefers-color-scheme: dark) { html[data-bp-theme="${name}"] { --info: ${ri.dark}; } }`,
  ].join("\n");
};

function sheetsBlock(themes = loadThemes()) {
  const ri = tokens.color.readerInfo;
  const ind = "    ";
  const lines = [
    ind + `:root { --info: ${ri.light}; --ring: var(--info); }`,
    ind + `@media (prefers-color-scheme: dark) { :root { --info: ${ri.dark}; } }`,
  ];
  const themed = themeBlocks(themes, sheetsThemeBlock);
  if (themed) lines.push(ind + THEME_BANNER, themed);
  return lines.join("\n");
}

export { errorPageBlock, sessionAuthBlock, sheetsBlock, statusChromeBlock };
