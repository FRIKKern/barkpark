<!-- doc-tier: cold | canonical-for: legendary-paper-survey-42-evidence | budget: 1200tok -->
# Survey 42 — Cloud Console wave 28 / email semantics

Verdict: `partial`. Heading and list semantics survive, but data tables falsely declare themselves presentational, callouts lack accessible severity, all 67 inline marks disappear, and no plain-text alternative or revision identity exists.

- Authority: deployed projection SHA-256 `cfe862c4f7b2c69dd7e88c2c914754d88a7b1effb447ce18f3e667b82e7aa621`; all 134 nonblank source blocks occur in exact order and 103 empty paragraphs emit nothing.
- All 43 headings render as real H1/H2/H3 elements. All seven lists render as semantic `<ul>` with 35 `<li>` elements.
- All 18 tables emit `<thead>`, 57 `<th>`, 155 body rows, and 466 `<td>`, yet every table has `role="presentation"` and none has caption, scope, or headers relationships. The role contradicts their data-table content.
- Thirteen callouts render as generic divs with no role, ARIA, or textual tone label. Source effective tones are info ×6, `warn` ×4, and `warning` ×3; output paints ten as info and three as warning because `warn` is unrecognized.
- All 67 string marks (strong ×26, code ×41) flatten to plain spans: output has zero `<strong>` and zero `<code>`. Text and order survive, semantics and styling do not.
- Source has zero structural links/task nodes. All 31 task-like IDs remain frozen prose and output has zero anchors, so no live lifecycle semantics can appear.
- The exact title exists, but Paper slug/ID and pinned revision do not. The response exposes only `text/html`; no `text/plain`, multipart alternative, or plain-text projection was found.
- The root `<html>` has no `lang`, and the body has no main/article landmark. Existing HTML audit coverage checks meaningful text, heading count, and link validity, not these semantic failures.

Focused Mix tests could not run because local test dependencies are absent; no dependency installation was attempted. Verify must cover table roles/header relationships, string marks, callout severity, document language/landmark, identity headers, and an actual plain-text or multipart delivery contract. No state mutation occurred.
