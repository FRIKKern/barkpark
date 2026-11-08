import assert from "node:assert/strict";
import { readAuthoredCss } from "./__css_source_graph.mjs";

const styles = readAuthoredCss();

assert.match(styles,
  /\.bp-canvas-card:has\(\[data-test-id="paper-card-action-label"\]:focus\) \.bp-canvas-card__controls \{ opacity: 0; pointer-events: none; \}/,
  "direct label typing does not overlay the previous prose with Card configuration controls");

console.log("PASS Card action label: package focus style");
