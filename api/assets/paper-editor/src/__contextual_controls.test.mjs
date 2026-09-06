import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const styles = readFileSync(new URL("./styles.css", import.meta.url), "utf8");
const shell = readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-shell.css", import.meta.url), "utf8");
const surface = readFileSync(new URL("../../paper-surface/paper-surface.css", import.meta.url), "utf8");
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
const buttons = shell.match(/\.bp-paper-contextual-panel button\s*\{([^}]*)\}/);
assert.match(buttons?.[1] ?? "", /min-height:\s*2rem/, "public controls have explicit usable button sizing");

const gaugeOpen = shell.match(/\.bp-paper-contextual-controls--gauge-list\[open\],\s*\.bp-paper-contextual-controls--tabs\[open\],\s*\.bp-paper-contextual-controls--form\[open\]\s*\{([^}]*)\}/);
assert.ok(gaugeOpen, "an open gauge disclosure has a bounded gauge-only layout override");
assert.match(gaugeOpen[1], /position:\s*relative/, "open gauge controls participate in document flow");
assert.match(gaugeOpen[1], /width:\s*100%/, "open gauge controls use the available editor width");
assert.match(gaugeOpen[1], /max-width:\s*none/, "open gauge controls are not capped to the floating-panel width");
const gaugePanel = shell.match(/\.bp-paper-contextual-controls--gauge-list\[open\]\s*>\s*\.bp-paper-contextual-panel,\s*\.bp-paper-contextual-controls--tabs\[open\]\s*>\s*\.bp-paper-contextual-panel,\s*\.bp-paper-contextual-controls--form\[open\]\s*>\s*\.bp-paper-contextual-panel\s*\{([^}]*)\}/);
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

console.log("PASS contextual labels: scoped readable token and light/dark contrast");
