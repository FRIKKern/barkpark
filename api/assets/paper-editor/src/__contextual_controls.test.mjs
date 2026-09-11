import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const styles = readFileSync(new URL("./styles.css", import.meta.url), "utf8");
const shell = readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-shell.css", import.meta.url), "utf8");
const mediaStyles = readFileSync(new URL("../../../priv/static/assets/bp-media-picker.css", import.meta.url), "utf8");
assert.match(shell, /\.bp-paper-figure-editor-frame\s*\{[^}]*display:\s*flow-root/s,
  "Figure contains the reader image's trailing margin even when caption is empty");
assert.match(mediaStyles, /\.bp-ab-grid\s*\{[^}]*display:\s*grid/s,
  "the shared media library defines its grid without depending on Studio utilities");
assert.match(mediaStyles, /var\(--surface-raised, var\(--paper-bg\)\)/,
  "media dialogs use the current Paper palette when Studio tokens are absent");
assert.match(shell, /\.bp-paper-figure-image-controls\s*\{[^}]*position:\s*absolute/s,
  "resting Figure image options cannot move the reader image or caption");
assert.match(shell, /\.bp-paper-figure-image\[data-image-src=""\] > \.bp-paper-figure-image-controls\s*\{[^}]*opacity:\s*1[^}]*pointer-events:\s*auto/s,
  "an empty image keeps its source recovery controls visibly pointer reachable");
assert.match(shell, /\.bp-paper-figure-image\[data-image-src=""\] > \.bp-paper-figure-image-controls\s*\{[^}]*position:\s*relative[^}]*min-height:\s*44px/s,
  "missing image recovery reserves a touch row rather than covering caption or following prose");
assert.match(shell, /\.bp-paper-figure-caption-form:not\(:focus-within\)\s*\{[^}]*position:\s*absolute[^}]*clip-path:\s*inset\(50%\)/s,
  "resting captions use canonical reader paint rather than textarea whitespace layout");
assert.match(shell, /\.bp-paper-figure-caption-paint\s*\{[^}]*letter-spacing:\s*inherit[^}]*word-spacing:\s*inherit/s,
  "native caption buttons retain reader character spacing at wrapping thresholds");
assert.match(shell, /\[data-paper-figure-image-trigger\]:focus-visible\s*\{[^}]*outline:\s*2px solid var\(--paper-accent\)/s,
  "the rendered Figure image has a visible keyboard target without changing its box");
assert.match(shell, /\.bp-paper-figure-image-picker\s*\{[^}]*max-height:\s*min\(70vh, 42rem\)[^}]*overflow:\s*auto/s,
  "Figure image options remain reachable in a bounded mobile overlay");
assert.match(shell, /\.bp-paper-edit-form\.bp-paper-figure-caption-form\s*\{[^}]*display:\s*block[^}]*margin:\s*0[^}]*padding:\s*0/s,
  "Figure caption form cannot add a second layout around reader typography");
assert.match(shell, /textarea\.bp-paper-figure-caption-input\s*\{[^}]*font:\s*inherit[^}]*resize:\s*none/s,
  "the growing Figure caption inherits the reader's font and avoids native resize chrome");
assert.match(shell, /\[data-paper-figure-caption-empty="true"\]:not\(:focus-within\)\s*\{[^}]*height:\s*0[^}]*margin:\s*0/s,
  "captionless Figures retain zero resting caption height until intentional focus");
assert.match(shell, /\[data-paper-figure-caption-empty="true"\]:not\(:focus-within\) > \.bp-paper-figure-caption-form\s*\{[^}]*position:\s*absolute[^}]*clip-path:\s*inset\(50%\)/s,
  "empty caption authoring stays mounted and focusable without entering resting flow");
for (const [name, css] of [["standalone", styles], ["host shell", shell]]) {
  assert.match(css, /\[data-test-id="paper-canvas-resume-warning"\]\s*\{[^}]*font-family:\s*var\(--paper-font-ui/s,
    `${name} reconnect recovery uses editor chrome rather than document prose`);
  assert.match(css, /\[data-test-id="paper-canvas-resume-warning"\] button\s*\{[^}]*min-height:\s*44px/s,
    `${name} recovery actions have themed touch-sized controls`);
}
assert.match(shell, /\.bp-paper-surface \.bp-paper-add-block :is\(select, button\)\s*\{[^}]*background: var\(--paper-bg-deep\);[^}]*color: var\(--paper-ink\);/s,
  "public article add-block controls use the Paper theme without Studio button CSS");
const surface = readFileSync(new URL("../../paper-surface/paper-surface.css", import.meta.url), "utf8");
const documentFlow = shell.match(/\.bp-paper-editor\s*\{([^}]*)\}/);
assert.match(documentFlow?.[1] ?? "", /display:\s*flow-root/,
  "mixed reader-shaped blocks must collapse sibling margins while containing the document's outer margins");
assert.match(shell, /\.bp-paper-edit-form\[hidden\]\s*\{\s*display:\s*none/,
  "a hidden native field-owner form cannot create a flex box that interrupts sibling margin collapse");
assert.doesNotMatch(shell, /\[data-block-type="(?:blockquote|terminal)"\]\s*\+\s*\.bp-paper-edit-(?:block|canvas)/,
  "normal block flow replaces pair-specific quote and terminal margin suppression");
assert.match(surface, /\.bp-paper-surface \.bp-blockquote\s*\{[^}]*margin:\s*1\.4rem 0/,
  "the reader and lone quotes keep their existing vertical rhythm");
const narrowToolbar = shell.match(/@media\s*\(max-width:\s*720px\)\s*\{\s*\.bp-paper-edit-toolbar\s*\{([^}]*)\}/);
assert.ok(narrowToolbar, "narrow screens cannot rely on an off-screen left margin for block controls");
assert.match(narrowToolbar[1], /left:\s*0/, "narrow controls stop using the desktop left offset");
assert.match(narrowToolbar[1], /right:\s*0/, "narrow controls occupy a dedicated viewport strip");
assert.match(narrowToolbar[1], /position:\s*fixed/,
  "controls dock outside document flow instead of covering preceding prose");
assert.match(narrowToolbar[1], /safe-area-inset-bottom/, "the dock respects the device safe area");
assert.match(narrowToolbar[1], /transform:\s*none/, "the desktop off-screen translation is removed");
assert.match(shell, /\.bp-paper-editor\s*\{\s*padding-bottom:\s*calc\(4rem \+ env\(safe-area-inset-bottom/,
  "editor footer actions can scroll clear of the fixed strip without shifting authored blocks");
assert.match(shell, /body:has\(\.bp-paper-editor\) > \.bp-view-controls\s*\{\s*padding-bottom:\s*calc\(4rem \+ env\(safe-area-inset-bottom/,
  "public view-mode buttons can also scroll clear of the editing strip");
assert.match(narrowToolbar[1], /flex-direction:\s*row/, "narrow controls use a compact horizontal group");
assert.match(shell, /\.bp-paper-edit-toolbar \.bp-paper-edit-actions\s*\{[^}]*flex-direction:\s*row/,
  "the action buttons also switch from a vertical rail to a row");
assert.match(shell, /\.bp-paper-edit-block:focus-within:not\(:has\(\.bp-paper-edit-block:focus-within\)\) > \.bp-paper-edit-toolbar\s*\{[^}]*opacity:\s*1/,
  "only the innermost focused block reveals a dock, not its ancestors or siblings");
assert.match(shell, /\.bp-paper-edit-toolbar\s*\{[^}]*position:\s*absolute/,
  "toolbar placement remains outside document flow");
const quoteWrapper = shell.match(/\.bp-paper-edit-block\[data-block-type="blockquote"\]:has\(\.bp-paper-quote-editor\)\s*\{([^}]*)\}/);
assert.match(quoteWrapper?.[1] ?? "", /margin-top:\s*0/,
  "an inline citation form cannot add a second wrapper gap above its reader-shaped quote");
assert.match(shell, /\.bp-paper-edit-block:has\(\.bp-paper-edit-field\)\s*\{[^}]*margin-top:\s*6pt/,
  "ordinary bound fields retain their own spacing");
const luminance = hex => hex.match(/\w\w/g).map(value => parseInt(value, 16) / 255)
  .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
  .reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);

// Both mounted hosts load the shared shell; standalone supplies the evergreen
// token pairs, while the shell additionally carries warm-theme overrides.
const labels = shell.match(/\.bp-paper-contextual-panel \.bp-paper-edit-fieldlabel\s*\{([^}]*)\}/);
assert.ok(labels, "shared shell scopes the configuration-label rule");
assert.match(labels[1], /color:\s*var\(--paper-ink-soft\)/,
  "small form labels use readable text, not faint decorative text");
assert.match(labels[1], /display:\s*grid/, "wrapped field labels stack their inputs");
const rows = shell.match(/\.bp-paper-contextual-panel fieldset\.bp-paper-edit-form\s*\{([^}]*)\}/);
assert.ok(rows, "collection rows have a scoped layout instead of inherited inline flex");
assert.match(rows[1], /display:\s*grid/, "each authored row field has its own line");
assert.match(rows[1], /min-inline-size:\s*0/, "fieldset intrinsic width cannot force panel overflow");
const actions = shell.match(/\.bp-paper-contextual-panel \.bp-paper-edit-actions\s*\{([^}]*)\}/);
assert.match(actions?.[1] ?? "", /flex-direction:\s*row/, "row actions remain a compact wrapping group");
const buttons = shell.match(/\.bp-paper-contextual-panel button\s*,\s*\.bp-paper-history-controls button\s*\{([^}]*)\}/);
assert.match(buttons?.[1] ?? "", /min-height:\s*2rem/, "public controls have explicit usable button sizing");
assert.match(buttons?.[1] ?? "", /color:\s*var\(--paper-ink-soft\)/,
  "history and fallback controls share readable Paper tokens in both hosts");

const gaugeOpen = shell.match(/\.bp-paper-contextual-controls--gauge-list\[open\](?:\s*,[^{}]+)?\s*\{([^}]*)\}/);
assert.ok(gaugeOpen, "an open gauge disclosure has a bounded gauge-only layout override");
assert.match(gaugeOpen[1], /position:\s*relative/, "open gauge controls participate in document flow");
assert.match(gaugeOpen[1], /width:\s*100%/, "open gauge controls use the available editor width");
assert.match(gaugeOpen[1], /max-width:\s*none/, "open gauge controls are not capped to the floating-panel width");
const gaugePanel = shell.match(/\.bp-paper-contextual-controls--gauge-list\[open\]\s*>\s*\.bp-paper-contextual-panel(?:\s*,[^{}]+)?\s*\{([^}]*)\}/);
assert.ok(gaugePanel, "the gauge-only open panel overrides overlay scrolling");
assert.match(gaugePanel[1], /max-height:\s*none/, "open gauge rows are not clipped to an overlay viewport");
assert.match(gaugePanel[1], /overflow:\s*visible/, "open gauge rows do not create a nested scroll region");
assert.match(shell, /\.bp-paper-contextual-controls\s*\{[^}]*position:\s*absolute/s,
  "closed contextual controls retain zero-flow floating geometry");
const readerTabs = surface.match(/\.bp-paper-surface \.bp-tabs,\s*\.bp-paper-surface \.bp-code-tabs\s*\{([^}]*)\}/);
assert.match(readerTabs?.[1] ?? "", /overflow:\s*hidden/,
  "canonical reader tabs retain their clipped rounded shell");
const editorTabs = surface.match(/\.bp-paper-surface \.bp-tabs--editor\s*\{([^}]*)\}/);
assert.match(editorTabs?.[1] ?? "", /overflow:\s*visible/,
  "stacked editor tabs cannot clip nested contextual controls");
const nestedTabsOpen = shell.match(/\.bp-tabs--editor \.bp-paper-contextual-controls\[open\]\s*\{([^}]*)\}/);
assert.match(nestedTabsOpen?.[1] ?? "", /position:\s*relative/,
  "an open nested Tabs control participates in its panel's document flow");
assert.match(nestedTabsOpen?.[1] ?? "", /width:\s*100%/,
  "an open nested Tabs control uses the panel width");
const nestedTabsPanel = shell.match(/\.bp-tabs--editor \.bp-paper-contextual-controls\[open\]\s*>\s*\.bp-paper-contextual-panel\s*\{([^}]*)\}/);
assert.match(nestedTabsPanel?.[1] ?? "", /max-height:\s*none/,
  "nested Tabs controls do not clip tall authored collections");
assert.match(nestedTabsPanel?.[1] ?? "", /overflow:\s*visible/,
  "nested Tabs controls do not overlay following editor actions through a scroll viewport");

for (const [name, css] of [["standalone", styles], ["host shell", shell]]) {
  let checked = 0;
  for (const [, body] of css.matchAll(/\{([^{}]*)\}/g)) {
    const background = body.match(/--paper-bg:\s*#([0-9a-f]{6})\s*;/i)?.[1];
    const foreground = body.match(/--paper-ink-soft:\s*#([0-9a-f]{6})\s*;/i)?.[1];
    if (!background || !foreground) continue;
    const [low, high] = [luminance(background), luminance(foreground)].sort((a, b) => a - b);
    assert.ok((high + 0.05) / (low + 0.05) >= 4.5, `${name} theme labels meet normal-text contrast`);
    checked += 1;
  }
  assert.ok(checked >= 2, `${name} checks light and dark authored token pairs`);
}

assert.match(shell, /\.bp-paper-quote-editor \.bp-blockquote__cite\s*\{[^}]*display:\s*block/,
  "wrapped attribution lines retain the reader's full width instead of a narrowed flex column");
assert.match(shell, /\.bp-paper-quote-editor \.bp-blockquote__cite::before\s*\{[^}]*position:\s*absolute/,
  "the decorative prefix is independent of the native text field's line width");
assert.match(surface, /\.bp-paper-surface \.bp-blockquote__cite::before\s*\{ content: "\\2014\\00a0";/,
  "canonical reader prefix and flow remain unchanged");

const studioLayout = readFileSync(new URL("../../../lib/barkpark_web/layouts/root.html.heex", import.meta.url), "utf8");
assert.match(studioLayout, /href="\/assets\/bp-media-picker\.css"/,
  "Studio loads the same media styles as the Public editor");
assert.doesNotMatch(studioLayout, /\.bp-ab-overlay\s*\{/,
  "media styling has one shared owner rather than a duplicate Studio inline copy");
const narrowPaperHeader = studioLayout.match(/@container panel\s*\(max-width:\s*720px\)\s*\{\s*\.editor-panel\[data-test-id="studio-paper-editor"\] > \.editor-header\s*\{([^}]*)\}/);
assert.ok(narrowPaperHeader, "Paper header actions must not spill over the title in a narrow content pane");
assert.match(narrowPaperHeader[1], /display:\s*grid/, "title and actions get separate rows without changing the shared desktop header");
assert.match(narrowPaperHeader[1], /grid-template-columns:\s*minmax\(0,\s*1fr\)/, "long titles cannot grow the narrow grid beyond its pane");
assert.match(narrowPaperHeader[1], /height:\s*auto/, "two header rows are not squeezed into the legacy 42px height");
assert.match(narrowPaperHeader[1], /flex-shrink:\s*0/, "the scrolling editor cannot shrink the header over its actions");
assert.match(studioLayout, /\.editor-panel\[data-test-id="studio-paper-editor"\] > \.editor-header > div:last-child\s*\{[^}]*flex-wrap:\s*wrap/,
  "Publish, View, standalone and Share actions wrap rather than disappearing off the pane");

console.log("PASS contextual labels: scoped readable token and light/dark contrast");
