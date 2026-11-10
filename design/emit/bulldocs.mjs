// design/emit/bulldocs.mjs — the /papers reader skin.
// Part of design/emit.mjs, the W1.2 emitter, moved here with no change in behaviour.
// design/emit.mjs imports this module and re-exports its public names.

import { loadThemes, THEME_BANNER, themeBlocks, tokens } from "./source.mjs";
import { hslToHex, motionVars } from "./vocab.mjs";

// ── surface: /papers reader skin (api/lib/barkpark_web/layouts/bulldocs.html.heex)
// The reader article's `--paper-*` skin overrides (color.paper.reader) PLUS the
// mail-client popup chrome (color.mailChrome, the ONLY --mail-* copy, relocated
// into this one marker region). The reader is a HYBRID surface: default mode
// follows prefers-color-scheme, but the reader's dark/light toggle stamps
// html[data-theme] (pre-paint, localStorage `barkpark_theme` shared with
// Studio) and the explicit stamp wins — so every mode pair emits THREE ways:
// bare light fallback, @media dark (the no-JS/first-paint owner), and
// [data-theme] companions. The reader DELIBERATELY diverges from the shared
// paper-surface skin on --paper-rule (solid vs rgba) — never collapsed onto the
// shared tokens this wave (charter D4). The load-bearing rationale comments are
// emitted VERBATIM so `emit --write` preserves them; the callout --bp-tone-*
// dark re-stamps are sourced from color.paperCallout.dark (the light pairs feed
// TokensGen.callout/1) — byte-identical emission, single-sourced tone values.
// Indented 4 spaces to sit inside the reader <style>; the marker block is CSS
// comments, invisible to the browser.
// Bulldocs reader theme block. The reader defaults to the OS scheme, so the
// per-theme dark re-declarations nest inside the same @media idiom, prefixed
// with the theme attribute — PLUS `[data-theme]` companions (two attrs, so a
// toggled mode beats both the theme-light block and the base [data-theme]
// blocks that precede the themed region in the cascade). The reader page never
// stamps data-bp-theme today, so this block is the structural hook (a theme
// swap reaches the reader skin the moment a surface sets the attribute);
// reader-dark-parity stays green because the guard's edit-side scan reads
// paper-surface.css only, and the reader-coverage scan still finds these dark
// re-skins inside prefers-color-scheme blocks.
// PRINT — the reader's paged output. A paper prints as ink on white whatever
// the screen was wearing, and BOTH dark routes survive into paged output: a
// print preview keeps the OS `prefers-color-scheme` AND keeps whatever
// `data-theme` the pre-paint toggle stamped. The reader's @media print block
// (the hand region of bulldocs.html.heex) forces a white ground but never
// re-stamped the ink, so an OS-dark reader printed the DARK palette's ink onto
// that white — #e7ede9 on #fff, ~1.2:1, a page that looks blank.
//
// This re-stamps the LIGHT palette under print, from the SAME token data the
// light blocks above emit — never a hand-copy, so a palette edit reaches print
// with the rest of it (and the values stay inside the GENERATED marker, where
// check.mjs Part E's literal ledger does not count them).
//
// TWO selector shapes because the dark palette arrives two ways:
//   * the bare pair matches the `@media (prefers-color-scheme: dark)` block's
//     specificity exactly and wins on source order (it is emitted later);
//   * the `[data-theme]` pair matches `[data-theme="dark"]`'s specificity, so a
//     reader who explicitly toggled dark prints light as well.
// `root` is the ROOT-element selector the palette hangs off: `html` for the base
// palette, `html[data-bp-theme="x"]` for a theme. `[data-theme]` is appended as a
// COMPOUND (no space) because data-bp-theme and data-theme both sit on <html>.
const printRestamp = (root, lightLines) => {
  const sel = (tail) => `      ${root} ${tail}`;
  const selStamped = (tail) => `      ${root}[data-theme] ${tail}`;
  const art = "body:has(.bp-paper-article)";
  const shell = `${art} .bp-paper-shell.bp-paper-article`;
  return [
    "    /* PRINT: the LIGHT palette, re-stamped from the same token data as the",
    "       light blocks above — paged output is ink on white whatever the screen",
    "       scheme or the stamped [data-theme] was. See printRestamp in",
    "       design/emit.mjs; the white ground + chrome hiding stay in the hand",
    "       region's @media print block further down this sheet. */",
    "    @media print {",
    sel(art + ","),
    sel(shell + ","),
    selStamped(art + ","),
    selStamped(shell + " {"),
    ...lightLines.map((l) => "        " + l.trim()),
    "      }",
    "    }",
  ];
};

const bulldocsThemeBlock = (name, t) => {
  const rl = t.color.paper.reader.light;
  const rd = t.color.paper.reader.dark;
  const mc = t.color.mailChrome;
  const cd = t.color.paperCallout.dark;
  const p = `html[data-bp-theme="${name}"]`;
  // S7 stub: the warm reading accent (color.reading-accent, theme-derived),
  // UNCONSUMED until S8 reads it for the article terracotta.
  const ra = (theme) => `--paper-reading-accent: ${hslToHex(t.color["reading-accent"][theme])};`;
  const readerVars = (r, theme, extra = []) =>
    [
      `--paper-bg: ${r["bg"]};`,
      `--paper-bg-deep: ${r["bg-deep"]};`,
      `--paper-ink: ${r["ink"]};`,
      `--paper-ink-soft: ${r["ink-soft"]};`,
      `--paper-rule: ${r["rule"]};`,
      `--paper-accent: ${r["accent"]};`,
      `--paper-accent-soft: ${r["accent-soft"]};`,
      ra(theme),
      ...extra,
    ].map((l) => "        " + l);
  const darkExtra = [
    `--paper-ink-faint: ${rd["ink-faint"]};`,
    `--paper-ink-faint-line: ${rd["ink-faint-line"]};`,
    `--paper-chrome-bg: ${rd["chrome-bg"]};`,
    `--paper-chrome-border: ${rd["chrome-border"]};`,
    `--bp-tone-info-bg: ${cd.info.bg}; --bp-tone-info-fg: ${cd.info.fg};`,
    `--bp-tone-success-bg: ${cd.success.bg}; --bp-tone-success-fg: ${cd.success.fg};`,
    `--bp-tone-warning-bg: ${cd.warning.bg}; --bp-tone-warning-fg: ${cd.warning.fg};`,
    `--bp-tone-danger-bg: ${cd.danger.bg}; --bp-tone-danger-fg: ${cd.danger.fg};`,
    `--bp-tone-neutral-bg: ${cd.neutral.bg}; --bp-tone-neutral-fg: ${cd.neutral.fg};`,
  ];
  // The [data-theme="light"] companion must re-declare every token the reader's
  // @media dark block re-skins — the media block's selector outranks the bare
  // paper-surface light fallbacks, so a forced-light reader under an OS-dark
  // scheme would otherwise keep DARK callout tones / faint ink / chrome (the
  // mirror image of the #1217 bug). Light values come from the shared surface
  // family + paperCallout.light — the same values the un-stamped light path
  // resolves through paper-surface.css.
  const sf = t.color.paper.surface;
  const cl = t.color.paperCallout.light;
  const lightExtra = [
    `--paper-ink-faint: ${sf["ink-faint"].light};`,
    `--paper-ink-faint-line: ${sf["ink-faint-line"].light};`,
    `--paper-chrome-bg: ${sf["chrome-bg"].light};`,
    `--paper-chrome-border: ${sf["chrome-border"].light};`,
    `--bp-tone-info-bg: ${cl.info.bg}; --bp-tone-info-fg: ${cl.info.fg};`,
    `--bp-tone-success-bg: ${cl.success.bg}; --bp-tone-success-fg: ${cl.success.fg};`,
    `--bp-tone-warning-bg: ${cl.warning.bg}; --bp-tone-warning-fg: ${cl.warning.fg};`,
    `--bp-tone-danger-bg: ${cl.danger.bg}; --bp-tone-danger-fg: ${cl.danger.fg};`,
    `--bp-tone-neutral-bg: ${cl.neutral.bg}; --bp-tone-neutral-fg: ${cl.neutral.fg};`,
  ];
  const mailVars = (theme) =>
    [
      `--mail-paper: ${mc.paper[theme]}; --mail-bar: ${mc.bar[theme]}; --mail-rule: ${mc.rule[theme]};`,
      `--mail-ink: ${mc.ink[theme]}; --mail-soft: ${mc.soft[theme]}; --mail-accent: ${mc.accent[theme]};`,
    ].map((l) => "      " + l);
  return [
    `    ${p} body:has(.bp-paper-article),`,
    `    ${p} body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {`,
    ...readerVars(rl, "light").map((l) => l.replace(/^ {8}/, "      ")),
    "    }",
    "    @media (prefers-color-scheme: dark) {",
    `      ${p} body:has(.bp-paper-article),`,
    `      ${p} body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {`,
    ...readerVars(rd, "dark", darkExtra),
    "      }",
    "    }",
    `    ${p} #bp-mailapp {`,
    ...mailVars("light"),
    "    }",
    "    @media (prefers-color-scheme: dark) {",
    `      ${p} #bp-mailapp {`,
    ...mailVars("dark").map((l) => "  " + l),
    "      }",
    "    }",
    `    ${p}[data-theme="light"] body:has(.bp-paper-article),`,
    `    ${p}[data-theme="light"] body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {`,
    ...readerVars(rl, "light", lightExtra).map((l) => l.replace(/^ {8}/, "      ")),
    "    }",
    `    ${p}[data-theme="dark"] body:has(.bp-paper-article),`,
    `    ${p}[data-theme="dark"] body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {`,
    ...readerVars(rd, "dark", darkExtra).map((l) => l.replace(/^ {8}/, "      ")),
    "    }",
    `    ${p}[data-theme="light"] #bp-mailapp {`,
    ...mailVars("light"),
    "    }",
    `    ${p}[data-theme="dark"] #bp-mailapp {`,
    ...mailVars("dark"),
    "    }",
    ...printRestamp(p, readerVars(rl, "light", lightExtra)),
  ].join("\n");
};

function bulldocsBlock(themes = loadThemes()) {
  const rl = tokens.color.paper.reader.light;
  const rd = tokens.color.paper.reader.dark;
  const mc = tokens.color.mailChrome;
  const cd = tokens.color.paperCallout.dark; // dark callout tone re-stamps
  const cl = tokens.color.paperCallout.light; // light re-stamps for [data-theme="light"]
  const sfl = Object.fromEntries(
    ["ink-faint", "ink-faint-line", "chrome-bg", "chrome-border"].map((r) => [r, tokens.color.paper.surface[r].light])
  );
  // S7 stub: the warm reading accent (color.reading-accent), UNCONSUMED until S8.
  const ra = (theme) => hslToHex(tokens.color["reading-accent"][theme]);
  const themed = themeBlocks(themes, bulldocsThemeBlock);
  return [
    "    /* MOTION ladder (tokens.motion) — theme-invariant, so it sits on the",
    "       page root rather than inside any of the reader's palette scopes. The",
    "       reader's own chrome (view toggle, action bar, mail popup) is the",
    "       consumer; a duration does not flip with a skin. */",
    "    :root {",
    motionVars("      "),
    "    }",
    "    /* Article chrome — applied only when BulldocsLive marks the doc as",
    "       `content[\"style\"] == \"article\"` (the LiveView stamps the",
    "       `.bp-paper-article` class on its <main>). Cool bp-theme page, a",
    "       centered ~720px reading column (incl. padding), serif base — so the",
    "       inline-styled article blocks sit on a proper page, not bare white",
    "       full-width. Non-article papers keep the dark chrome above, untouched.",
    "",
    "       READER SKIN: token overrides layered over the canonical paper-surface",
    "       source (embedded above). These `--paper-*` values are the historical",
    "       bp-theme reader look. They are set on the <body> AND on the reader",
    "       <main> (`.bp-paper-shell.bp-paper-article`, which now also carries",
    "       `bp-paper-surface`) so they WIN over the shared source's fallback",
    "       `.bp-paper-surface { --paper-* }` block — otherwise render.ex's inline",
    "       `var(--paper-*, hex)` block HTML would resolve to the Studio defaults on",
    "       the reader on the bp-theme (a shared ink #15211d, rule #e2e6e5,",
    "       etc.). Dark-mode note: the reader stamps `html[data-theme]` only via",
    "       its pre-paint toggle script (localStorage `barkpark_theme`, shared",
    "       with Studio); before that script runs — and with JS off — the",
    "       `prefers-color-scheme: dark` block below (also carried onto <main>)",
    "       owns reader dark mode, flipping the palette to cool bp-dark with",
    "       light ink so the inline `var(--paper-*)` HTML stays readable. The",
    "       `html[data-theme]` companions further down repeat both palettes so an",
    "       explicit toggle beats the OS scheme. Without the <main>-scoped",
    "       override the shared light fallback would paint dark ink on the",
    "       browser's dark theme — the visibility bug. */",
    "    body:has(.bp-paper-article),",
    "    body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {",
    `      --paper-bg:         ${rl["bg"]};`,
    `      --paper-bg-deep:    ${rl["bg-deep"]};`,
    `      --paper-ink:        ${rl["ink"]};`,
    `      --paper-ink-soft:   ${rl["ink-soft"]};`,
    `      --paper-rule:       ${rl["rule"]};`,
    `      --paper-accent:     ${rl["accent"]};`,
    "      /* Link border-bottom tone (`.bp-paper-surface a` + walk.ex inline links",
    "         read it). Light value matches the shared source's fallback; the dark",
    "         block below MUST re-skin it — otherwise dark-mode link borders resolve",
    "         to this light rgba and vanish against the dark page. */",
    `      --paper-accent-soft: ${rl["accent-soft"]};`,
    `      --paper-reading-accent: ${ra("light")}; /* S7 stub — S8 consumes */`,
    "    }",
    "    /* GROUND (task-ddb1e0ab09a62466): the reader body stands on --paper-bg —",
    "       the SAME token the Studio editor paints on .bp-paper-surface",
    "       (root.html.heex) — so --paper-bg-deep is free to be the FILL tone under",
    "       pre / code / .bp-stat / .bp-card / figure. With both on bg-deep every",
    "       fill measured delta-L 0 against the page (2026-09-02 audit).",
    "       measure_parity_test.exs pins the two shells to one token. */",
    "    body:has(.bp-paper-article) {",
    "      background: var(--paper-bg);",
    "      color: var(--paper-ink);",
    "      /* THE READING SERIF, on the reader's <body>. This used to be a FOURTH",
    "         hand-kept copy of the stack (paper-surface.css, root.html.heex and",
    "         the paper-editor bundle carry the other three). It is now emitted",
    "         from design/tokens.json `font.reading.stack` like every other",
    "         `--tok-*`, so the ratified order has ONE source and the eventual",
    "         Source-Serif-first cutover is still a one-token edit.",
    "",
    "         The token is DECLARED here rather than merely consumed: paper-surface.css",
    "         scopes `--tok-reading-font` to `.bp-paper-surface, .bp-paper-body`, and",
    "         <body> is neither — the reader's surface class rides the <main> inside",
    "         it. Declaring it on the reader body makes `var()` below resolve for",
    "         real instead of silently living on a fallback, and the value is",
    "         byte-identical to the one .bp-paper-surface re-declares, so the",
    "         inner scope is a no-op re-statement rather than an override.",
    "         view_edit_parity_test.exs §10 pins this against the other three. */",
    `      --tok-reading-font: ${tokens.font.reading.stack};`,
    "      font-family: var(--tok-reading-font);",
    "    }",
    "    @media (prefers-color-scheme: dark) {",
    "      body:has(.bp-paper-article),",
    "      body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {",
    `        --paper-bg:         ${rd["bg"]};`,
    `        --paper-bg-deep:    ${rd["bg-deep"]};`,
    `        --paper-ink:        ${rd["ink"]};`,
    `        --paper-ink-soft:   ${rd["ink-soft"]};`,
    `        --paper-rule:       ${rd["rule"]};`,
    `        --paper-accent:     ${rd["accent"]};`,
    "        /* Warm-dark link border (same value as Studio's html[data-theme=dark]",
    "           block in paper-surface.css) — without it links keep the light-theme",
    "           rgba(162,57,37,0.10) border, invisible on the dark page. */",
    `        --paper-accent-soft: ${rd["accent-soft"]};`,
    `        --paper-reading-accent: ${ra("dark")}; /* S7 stub — S8 consumes */`,
    "        /* Callout TONE tokens + faint ink + chrome — the SAME reason as the",
    "           --paper-* above: paper-surface.css keys their DARK values on",
    "           `html[data-theme=\"dark\"]`, which the reader stamps only after its",
    "           pre-paint toggle script runs, so an OS-dark reader (no JS / first",
    "           paint) was left with the LIGHT callout tones (#eff6ff on a #131d19",
    "           page — a light box on the dark article). Re-skin them here,",
    "           byte-mirroring the dark values in paper-surface.css's",
    "           `html[data-theme=\"dark\"] .bp-paper-surface` block. Edit surfaces",
    "           stamp data-theme and get those directly; this is the reader's",
    "           prefers-color-scheme companion. */",
    `        --paper-ink-faint:    ${rd["ink-faint"]};`,
    `        --paper-ink-faint-line: ${rd["ink-faint-line"]};`,
    `        --paper-chrome-bg:    ${rd["chrome-bg"]};`,
    `        --paper-chrome-border: ${rd["chrome-border"]};`,
    `        --bp-tone-info-bg:    ${cd.info.bg}; --bp-tone-info-fg:    ${cd.info.fg};`,
    `        --bp-tone-success-bg: ${cd.success.bg}; --bp-tone-success-fg: ${cd.success.fg};`,
    `        --bp-tone-warning-bg: ${cd.warning.bg}; --bp-tone-warning-fg: ${cd.warning.fg};`,
    `        --bp-tone-danger-bg:  ${cd.danger.bg}; --bp-tone-danger-fg:  ${cd.danger.fg};`,
    `        --bp-tone-neutral-bg: ${cd.neutral.bg}; --bp-tone-neutral-fg: ${cd.neutral.fg};`,
    "      }",
    "    }",
    "    /* Mail-client popup chrome (color.mailChrome) — the --mail-* window skin",
    "       for the Email view, relocated here (from #bp-mailapp) so the reader",
    "       palette + the mail chrome are single-sourced in ONE marker region; the",
    "       #bp-mailapp consumers stay below. Theme-aware like a real dark mail",
    "       client showing a light HTML email; the served email bytes never change",
    "       with the theme. */",
    "    #bp-mailapp {",
    `      --mail-paper: ${mc.paper.light}; --mail-bar: ${mc.bar.light}; --mail-rule: ${mc.rule.light};`,
    `      --mail-ink: ${mc.ink.light}; --mail-soft: ${mc.soft.light}; --mail-accent: ${mc.accent.light};`,
    "    }",
    "    @media (prefers-color-scheme: dark) {",
    "      #bp-mailapp {",
    `        --mail-paper: ${mc.paper.dark}; --mail-bar: ${mc.bar.dark}; --mail-rule: ${mc.rule.dark};`,
    `        --mail-ink: ${mc.ink.dark}; --mail-soft: ${mc.soft.dark}; --mail-accent: ${mc.accent.dark};`,
    "      }",
    "    }",
    "    /* Explicit mode stamp — html[data-theme] companions to the light",
    "       fallback + prefers-color-scheme pair above. The reader's pre-paint",
    "       <head> script stamps data-theme from localStorage `barkpark_theme`",
    "       (shared with Studio) or the OS scheme, and the dark/light toggle",
    "       pill rewrites it — one attribute of extra specificity, so a toggled",
    "       choice beats the @media blocks in BOTH directions. The @media pair",
    "       stays byte-complete as the no-JS / first-paint fallback (it is also",
    "       what the reader-dark-parity guard scans for coverage). */",
    '    html[data-theme="light"] body:has(.bp-paper-article),',
    '    html[data-theme="light"] body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {',
    `      --paper-bg:         ${rl["bg"]};`,
    `      --paper-bg-deep:    ${rl["bg-deep"]};`,
    `      --paper-ink:        ${rl["ink"]};`,
    `      --paper-ink-soft:   ${rl["ink-soft"]};`,
    `      --paper-rule:       ${rl["rule"]};`,
    `      --paper-accent:     ${rl["accent"]};`,
    `      --paper-accent-soft: ${rl["accent-soft"]};`,
    `      --paper-reading-accent: ${ra("light")}; /* S7 stub — S8 consumes */`,
    "      /* Light re-declarations for every token the @media dark block above",
    "         re-skins — its selector outranks the bare paper-surface light",
    "         fallbacks, so WITHOUT these a forced-light reader under an OS-dark",
    "         scheme keeps dark callout tones / faint ink / chrome (the mirror",
    "         image of the #1217 bug). Values match the un-stamped light path. */",
    `      --paper-ink-faint:    ${sfl["ink-faint"]};`,
    `      --paper-ink-faint-line: ${sfl["ink-faint-line"]};`,
    `      --paper-chrome-bg:    ${sfl["chrome-bg"]};`,
    `      --paper-chrome-border: ${sfl["chrome-border"]};`,
    `      --bp-tone-info-bg:    ${cl.info.bg}; --bp-tone-info-fg:    ${cl.info.fg};`,
    `      --bp-tone-success-bg: ${cl.success.bg}; --bp-tone-success-fg: ${cl.success.fg};`,
    `      --bp-tone-warning-bg: ${cl.warning.bg}; --bp-tone-warning-fg: ${cl.warning.fg};`,
    `      --bp-tone-danger-bg:  ${cl.danger.bg}; --bp-tone-danger-fg:  ${cl.danger.fg};`,
    `      --bp-tone-neutral-bg: ${cl.neutral.bg}; --bp-tone-neutral-fg: ${cl.neutral.fg};`,
    "    }",
    '    html[data-theme="dark"] body:has(.bp-paper-article),',
    '    html[data-theme="dark"] body:has(.bp-paper-article) .bp-paper-shell.bp-paper-article {',
    `      --paper-bg:         ${rd["bg"]};`,
    `      --paper-bg-deep:    ${rd["bg-deep"]};`,
    `      --paper-ink:        ${rd["ink"]};`,
    `      --paper-ink-soft:   ${rd["ink-soft"]};`,
    `      --paper-rule:       ${rd["rule"]};`,
    `      --paper-accent:     ${rd["accent"]};`,
    `      --paper-accent-soft: ${rd["accent-soft"]};`,
    `      --paper-reading-accent: ${ra("dark")}; /* S7 stub — S8 consumes */`,
    `      --paper-ink-faint:    ${rd["ink-faint"]};`,
    `      --paper-ink-faint-line: ${rd["ink-faint-line"]};`,
    `      --paper-chrome-bg:    ${rd["chrome-bg"]};`,
    `      --paper-chrome-border: ${rd["chrome-border"]};`,
    `      --bp-tone-info-bg:    ${cd.info.bg}; --bp-tone-info-fg:    ${cd.info.fg};`,
    `      --bp-tone-success-bg: ${cd.success.bg}; --bp-tone-success-fg: ${cd.success.fg};`,
    `      --bp-tone-warning-bg: ${cd.warning.bg}; --bp-tone-warning-fg: ${cd.warning.fg};`,
    `      --bp-tone-danger-bg:  ${cd.danger.bg}; --bp-tone-danger-fg:  ${cd.danger.fg};`,
    `      --bp-tone-neutral-bg: ${cd.neutral.bg}; --bp-tone-neutral-fg: ${cd.neutral.fg};`,
    "    }",
    '    html[data-theme="light"] #bp-mailapp {',
    `      --mail-paper: ${mc.paper.light}; --mail-bar: ${mc.bar.light}; --mail-rule: ${mc.rule.light};`,
    `      --mail-ink: ${mc.ink.light}; --mail-soft: ${mc.soft.light}; --mail-accent: ${mc.accent.light};`,
    "    }",
    '    html[data-theme="dark"] #bp-mailapp {',
    `      --mail-paper: ${mc.paper.dark}; --mail-bar: ${mc.bar.dark}; --mail-rule: ${mc.rule.dark};`,
    `      --mail-ink: ${mc.ink.dark}; --mail-soft: ${mc.soft.dark}; --mail-accent: ${mc.accent.dark};`,
    "    }",
    ...printRestamp("html", [
      `--paper-bg:         ${rl["bg"]};`,
      `--paper-bg-deep:    ${rl["bg-deep"]};`,
      `--paper-ink:        ${rl["ink"]};`,
      `--paper-ink-soft:   ${rl["ink-soft"]};`,
      `--paper-rule:       ${rl["rule"]};`,
      `--paper-accent:     ${rl["accent"]};`,
      `--paper-accent-soft: ${rl["accent-soft"]};`,
      `--paper-reading-accent: ${ra("light")}; /* S7 stub — S8 consumes */`,
      `--paper-ink-faint:    ${sfl["ink-faint"]};`,
      `--paper-ink-faint-line: ${sfl["ink-faint-line"]};`,
      `--paper-chrome-bg:    ${sfl["chrome-bg"]};`,
      `--paper-chrome-border: ${sfl["chrome-border"]};`,
      `--bp-tone-info-bg:    ${cl.info.bg}; --bp-tone-info-fg:    ${cl.info.fg};`,
      `--bp-tone-success-bg: ${cl.success.bg}; --bp-tone-success-fg: ${cl.success.fg};`,
      `--bp-tone-warning-bg: ${cl.warning.bg}; --bp-tone-warning-fg: ${cl.warning.fg};`,
      `--bp-tone-danger-bg:  ${cl.danger.bg}; --bp-tone-danger-fg:  ${cl.danger.fg};`,
      `--bp-tone-neutral-bg: ${cl.neutral.bg}; --bp-tone-neutral-fg: ${cl.neutral.fg};`,
    ]),
    ...(themed ? ["    " + THEME_BANNER, themed] : []),
  ].join("\n");
}

// The cloud SPA theme-id enum (app.js `var BP_THEMES = [ … ]`). loadThemes()
// leads with the default skin (evergreen) then dir order, so the emitted list is
// the SAME ordering every other generated enumeration uses (Go Themes(), the
// Studio picker, the CSS blocks). Indented 4 spaces to sit inside the array
// literal in the IIFE; no trailing comma or newline (the marker's END line
// carries the newline). This kills the GR12 drift: the SPA's identity picker
// reads BP_THEMES at runtime, so a new design/themes/<id>.json reaches the picker
// the moment `emit --write` runs — no second hand-list to forget.

export { bulldocsBlock };
