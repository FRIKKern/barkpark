export const meta = {
  name: 'view-edit-parity',
  description: 'View↔Edit parity audit — diff every block type\'s View inline styles against its Edit CSS rules; adversarially verify each divergence; write a parity matrix HTML report.',
  whenToUse: 'Run after touching render.ex heading_style/paragraph/list/callout styling, or after touching root.html.heex .bp-paper-surface or .bp-paper-editor-body rules, to catch View↔Edit drift before it ships. INVOKE: Workflow({scriptPath: ".claude/workflows/view-edit-parity.workflow.js"}) — launch by scriptPath, not by name (the name registry is a session-start snapshot). Paths are repo-relative: run it from the repo root.',
  phases: [
    { title: 'Enumerate', detail: 'list every block type that emits visible HTML' },
    { title: 'Sources',   detail: 'extract render.ex inline emitters + root.html.heex CSS rules' },
    { title: 'Diff',      detail: 'one parity check per block × variant' },
    { title: 'Verify',    detail: 'adversarial refute on each divergence (2 voters)' },
    { title: 'Report',    detail: 'write the parity matrix HTML to docs/specs/' },
  ],
};

const ENUM_SCHEMA = {
  type: 'object',
  properties: {
    blocks: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          variants: { type: 'array', items: { type: 'string' } },
          notes: { type: 'string' },
        },
        required: ['name'],
      },
    },
  },
  required: ['blocks'],
};

const FINDING_SCHEMA = {
  type: 'object',
  properties: {
    block: { type: 'string' },
    variant: { type: 'string' },
    property: { type: 'string' },
    viewValue: { type: 'string' },
    editValue: { type: 'string' },
    severity: { enum: ['high', 'medium', 'low'] },
    viewSource: { type: 'string' },
    editSource: { type: 'string' },
    notes: { type: 'string' },
  },
  required: ['block', 'property', 'viewValue', 'editValue', 'severity'],
};

const FINDINGS_LIST_SCHEMA = {
  type: 'object',
  properties: { findings: { type: 'array', items: FINDING_SCHEMA } },
  required: ['findings'],
};

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    isReal: { type: 'boolean' },
    reasoning: { type: 'string' },
    confidence: { enum: ['high', 'medium', 'low'] },
  },
  required: ['isReal', 'reasoning', 'confidence'],
};

// Repo-relative on purpose: agents resolve these against the session cwd (the repo root),
// so the workflow runs on any checkout, any machine. No machine-local prefixes here — ever.
const RENDER_EX = 'api/lib/barkpark/portable_doc/render.ex';
const ROOT_HEEX = 'api/lib/barkpark_web/layouts/root.html.heex';
// The Beta editor's rules moved out of root.html.heex (edit-on-the-link slice 2); both files are the Edit side.
const SHELL_CSS = 'api/priv/static/assets/bp-paper-editor-shell.css';

// Workflow scripts cannot call Date (it breaks resume): the run date arrives via args.run_date.
const RUN_DATE = (typeof args === 'object' && args && args.run_date) || 'undated';
const REPORT_PATH = `docs/specs/${RUN_DATE}-view-edit-parity-matrix.html`;

phase('Enumerate');

const enumeration = await agent(
  `Read ${RENDER_EX} and enumerate every block type that compose_block/2 handles
in :article mode. Block names are the string values matched in
\`def compose_block(%{"type" => "<name>"} = b, :article)\` (and any matching
\`_style\` fallthrough that still emits styled HTML).

For each block, list its variants. Examples:
  • heading → ["level1", "level2", "level3"]
  • callout → ["info", "success", "warning", "danger", "neutral"]
  • list    → ["unordered", "ordered"]
  • table   → ["with-head", "headless"]
  • action  → ["primary", "secondary"]
  • diagram → ["with-caption", "no-caption"]
  • figure  → ["with-caption", "no-caption"]
  • section → ["default"]
  • paragraph, pullquote, eyebrow, byline, code, divider — ["default"]

Skip blocks that don't render visible HTML. Skip inline marks. Return via schema.`,
  { schema: ENUM_SCHEMA, agentType: 'general-purpose', phase: 'Enumerate', label: 'enumerate' }
);

const blocks = enumeration.blocks;
log(`Enumerated ${blocks.length} block types, ${blocks.reduce((a,b) => a + (b.variants?.length || 1), 0)} total variants`);

phase('Sources');

const [renderEx, rootHeex] = await parallel([
  () => agent(
    `Read ${RENDER_EX} and produce a stable text reference of every inline-style
emitter that runs in :article mode. The next phase will grep this output by
block name, so format CONSISTENTLY.

For each emitter, output a block like:

  ── block=<block-name> variant=<variant-or-"default"> ────────────────
  function: <function_name>/<arity>
  line:     <line-number>
  emits:    <literal style="…" attribute the function produces>
  notes:    <one short line on what wraps it>

Cover: heading_style/2 (all 3 clauses), paragraph article path, list/3,
list_item/3, callout/3, code_block_html/1, section_divider_html/0,
diagram_html/3 :article, button/2 :article, pullquote, eyebrow, byline,
figure_html/3 :article, table walker (header + body cells in :article),
section block.

When the style is composed across multiple call sites, document both the
outer tag and any nested span styles. Use actual values as emitted
(e.g. \`margin:0\` not \`margin:1.6rem 0 0.8rem\` after the recent zeroing).

Return ONLY the structured text reference, no preamble.`,
    { agentType: 'general-purpose', phase: 'Sources', label: 'render.ex emitters' }
  ),
  () => agent(
    `Read ${ROOT_HEEX} AND ${SHELL_CSS} (the editor rules live in the second file) and produce a stable text reference of every CSS rule
under \`.bp-paper-surface\` AND \`.bp-paper-editor-body\` that targets block
content (h1-h6, p, ul, ol, li, blockquote, code, pre, a, table, th, td,
figure, figcaption, hr, .bp-paper-callout, .bp-paper-pullquote,
.bp-paper-eyebrow, .bp-paper-byline).

Format each rule as:

  ── selector=<selector> surface=<view|edit|shared> ────────────────
  line:        <line-number>
  declaration: |
    property: value;
    property: value;

Tag surface=view for .bp-paper-surface, surface=edit for .bp-paper-editor-body,
surface=shared for comma-list unions. Include every property verbatim, in
source order — don't summarise.

Also include the \`--paper-*\` CSS variable definitions on both surfaces
(light + dark + fallback) since some inline emitters resolve to those vars.

Return ONLY the structured text reference, no preamble.`,
    { agentType: 'general-purpose', phase: 'Sources', label: 'root.html.heex rules' }
  ),
]);

log(`Source extraction complete: render.ex ${renderEx.length} chars, root.html.heex ${rootHeex.length} chars`);

phase('Diff');

const expanded = blocks.flatMap(b => {
  const variants = (b.variants && b.variants.length) ? b.variants : ['default'];
  return variants.map(v => ({ name: b.name, variant: v, notes: b.notes }));
});

const findingsLists = await parallel(expanded.map(b => () =>
  agent(
    `View↔Edit parity audit for block "${b.name}" (variant "${b.variant}").

PARITY CONTRACT
- View pane: render.ex Render.render_block/2 with style: :article emits HTML
  carrying INLINE styles. Used by /papers/:slug AND the Studio View pane.
- Edit pane: Studio Edit pane renders the block via ProseMirror inside
  .bp-paper-editor-body as RAW semantic tags (<h1>, <h2>, <p>, etc.) with
  NO inline styles. Styling comes from CSS rules in root.html.heex.

PARITY GOAL: a user toggling View ↔ Edit on the same paper sees the SAME
visual layout, character-for-character.

INPUTS (the only sources of truth for this audit):

────────── RENDER.EX INLINE EMITTERS ──────────
${renderEx}

────────── ROOT.HTML.HEEX RULES ──────────
${rootHeex}

YOUR JOB
List EVERY CSS property where View and Edit diverge for THIS block × variant.
For each finding:
  block: "${b.name}"
  variant: "${b.variant}"
  property: e.g. "line-height", "letter-spacing", "margin", "font-family"
  viewValue: literal value from the inline style
  editValue: literal value from the CSS rule (or "(unset)" if no rule → browser default)
  severity:
    - "high"   = clearly visible (line-height delta > 0.1, margin delta > 4pt, color/font-family swap)
    - "medium" = subtle (letter-spacing delta > 0.01em, padding delta < 4pt)
    - "low"    = cosmetic noise (equivalent forms)
  viewSource: "render.ex:<line>"
  editSource: "root.html.heex:<line>" or "(no rule)"
  notes: one short sentence on the visible shift

Axes to check: font-family, font-size, font-weight, line-height,
letter-spacing, color, background, margin, padding, border, text-align,
text-transform, list-style, white-space, font-style, hyphens.

Return {findings: []} if View and Edit match on every axis.

DO NOT false-positive:
- Inline value matches CSS variable resolution → not a divergence.
- Property unset on both sides → not a divergence.
- Editor-only UI (caret, focus ring, drag handle) → not a divergence.
- Same colour resolved via different fallback hex in the SAME --paper-* var → not a divergence.`,
    { schema: FINDINGS_LIST_SCHEMA, label: `diff:${b.name}/${b.variant}`, phase: 'Diff' }
  )
));

const rawFindings = findingsLists
  .filter(Boolean)
  .flatMap(r => r.findings || [])
  .filter(f => f && f.viewValue && f.editValue && f.viewValue !== f.editValue);

log(`Diff produced ${rawFindings.length} raw divergence candidates across ${expanded.length} block×variant combos`);

phase('Verify');

const verified = await parallel(rawFindings.map((f) => () =>
  parallel([
    () => agent(
      `Try to REFUTE this View↔Edit parity claim. Default to refuted (isReal=false)
if not certain it's a real visible mismatch.

claim:
  block: ${f.block} (variant: ${f.variant || 'default'})
  property: ${f.property}
  viewValue: ${f.viewValue}
  editValue: ${f.editValue}
  viewSource: ${f.viewSource || '?'}
  editSource: ${f.editSource || '?'}
  notes: ${f.notes || '(none)'}

READ ${RENDER_EX}, ${ROOT_HEEX} and ${SHELL_CSS} at the cited lines (and a few lines
around). Verify values are accurately quoted AND a user toggling View↔Edit
would visually notice.

Reject when:
  • Quoted value is misquoted or stale.
  • Cited CSS selector doesn't match the rendered editor element.
  • Difference is below visible threshold (line-height < 0.05, margin < 1pt).
  • Property is intentionally surface-specific.

Return isReal=true only when values are accurate AND visible.`,
      { schema: VERDICT_SCHEMA, agentType: 'general-purpose', label: `refute:${f.block}/${f.property}`, phase: 'Verify' }
    ),
    () => agent(
      `Independent second-vote refute. Different verifier; same claim; default
refuted when uncertain.

claim:
  block: ${f.block} (variant: ${f.variant || 'default'})
  property: ${f.property}
  viewValue: ${f.viewValue}
  editValue: ${f.editValue}
  viewSource: ${f.viewSource || '?'}
  editSource: ${f.editSource || '?'}
  notes: ${f.notes || '(none)'}

Look at ${RENDER_EX}, ${ROOT_HEEX} and ${SHELL_CSS}. Designer-with-pixel-ruler question:
would this show as visible drift side-by-side, or noise? Half of CSS diffs
are noise — be skeptical.`,
      { schema: VERDICT_SCHEMA, agentType: 'general-purpose', label: `refute2:${f.block}/${f.property}`, phase: 'Verify' }
    ),
  ]).then(votes => {
    const valid = votes.filter(Boolean);
    const realVotes = valid.filter(v => v.isReal).length;
    const confirmed = realVotes >= 2;
    return { ...f, votes: realVotes, total: valid.length, confirmed };
  })
));

const confirmed = verified.filter(Boolean).filter(v => v.confirmed);
log(`Verify confirmed ${confirmed.length}/${rawFindings.length} divergences (both refuters agreed)`);

const sevRank = { high: 0, medium: 1, low: 2 };
confirmed.sort((a, b) => (sevRank[a.severity] ?? 3) - (sevRank[b.severity] ?? 3) || a.block.localeCompare(b.block));

phase('Report');

const passedBlocks = expanded.filter(b => !confirmed.some(c => c.block === b.name && (c.variant || 'default') === b.variant));

await agent(
  `Write a native paper-article-style HTML parity report at this repo-relative path
  (resolve it against the repo root, i.e. your session cwd):
  ${REPORT_PATH}

CONFIRMED DIVERGENCES (sorted by severity, both refuters agreed):
${JSON.stringify(confirmed.map(c => ({
  block: c.block, variant: c.variant || 'default', property: c.property,
  viewValue: c.viewValue, editValue: c.editValue, severity: c.severity,
  viewSource: c.viewSource || '(unknown)', editSource: c.editSource || '(unknown)',
  notes: c.notes || '',
})), null, 2)}

PASSED (clean block × variant combos):
${JSON.stringify(passedBlocks.map(b => ({ block: b.name, variant: b.variant })), null, 2)}

WRITE THE REPORT
Strict paper-article conventions:
- Eyebrow "View ↔ Edit parity" + h1 "View ↔ Edit parity matrix" + byline (date string "${RUN_DATE}").
- Link <link rel="stylesheet" href="/paper/_lib/doc.css">
- Mermaid CDN <script> in <head>.
- Two <figure><pre class="mermaid">…</pre><figcaption><b>Figure N.</b> …</figcaption></figure>:
  1. Flowchart side-by-side:
     render.ex → inline style → .bp-paper-surface (View)
     ProseMirror → raw hN/p → .bp-paper-editor-body CSS (Edit)
  2. Severity bar of confirmed divergences (skip if 0).
- Ingress: parity goal + audit method (static analysis, 2-voter adversarial verify).
- H2 "Confirmed divergences" — table:
  Block | Variant | Property | View | Edit | Severity | Source
  Sorted high → low. Severity colour-coded badges: high=terracotta accent,
  medium=ink-soft, low=ink-faint. "No divergences detected" muted line if 0.
- H2 "Recommended fixes" — grouped by severity. Each fix one bullet:
    <code>property</code>: change View <code>value</code> → Edit <code>value</code>
    (or vice versa). Cite file:line. One-sentence rationale.
- H2 "Clean blocks" — passed list bulleted as "block / variant".
- H2 "Methodology" — short paragraph: workflow phases (Enumerate, Sources,
  Diff, Verify, Report), 2-voter adversarial gate, static-analysis basis
  (compares emitted inline styles against editor CSS rules; no browser).
- H2 "Re-run" — quote the launch line
  Workflow({scriptPath: ".claude/workflows/view-edit-parity.workflow.js"})
  and explain it re-runs from the repo root via the Workflow tool.
- Close with:
    <script>window.PAPER_NO_RAIL = true;</script>
    <script src="/paper/_lib/doc.js"></script>
- No inline <style> block.

Return the repo-relative path of the file you wrote.`,
  { agentType: 'general-purpose', phase: 'Report', label: 'parity matrix report' }
);

return {
  blocksEnumerated: blocks.length,
  variantsAudited: expanded.length,
  divergencesRaw: rawFindings.length,
  divergencesConfirmed: confirmed.length,
  passedCount: passedBlocks.length,
  highSeverity: confirmed.filter(c => c.severity === 'high').length,
  mediumSeverity: confirmed.filter(c => c.severity === 'medium').length,
  lowSeverity: confirmed.filter(c => c.severity === 'low').length,
  confirmedSample: confirmed.slice(0, 8),
  reportPath: REPORT_PATH,
};
