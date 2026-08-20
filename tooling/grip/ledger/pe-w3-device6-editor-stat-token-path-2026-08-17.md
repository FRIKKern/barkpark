<!-- doc-tier: cold | canonical-for: pe-w3-device6-editor-stat-token-path-rederivation | budget: 900tok -->
# Device-6 (verdict color) — editor-free-ride + token-family re-derivation

Wave: Paper Excellence wave 3 (task-4792223ca9eb5a7d). Verifier lane device6-editor-stat-path.

## Claim 1 — Studio edit surface is a `.bp-paper-surface` sink; non-prose blocks paint the reader's own server HTML byte-for-byte, so a stat tone modifier in paper-surface.css lands in Edit for FREE (no editor-stylesheet mirror).
Re-derive:
    sed -n '506p' api/assets/paper-editor/src/index.js            # _mount.className = "bp-paper-editor-body"
    sed -n '845,893p' api/lib/barkpark_web/live/studio/studio_live/components/paper_editor.ex   # "Studio shell is a .bp-paper-surface sink … one producer, byte for byte" (raw(html) via Render.render_block)
    sed -n '1325,1336p' api/lib/barkpark_web/layouts/root.html.heex # .editor-body.editor-panel-main.bp-paper-body > .bp-paper-shell.bp-paper-surface
    grep -n "fleet_preview_types" api/lib/barkpark_web/live/studio/studio_live/components/paper_editor.ex  # @55: notes cards pipeline status-legend form questionnaire asciicast (NO "stats")

## Claim 2 — run-convert.js ships DARK (nothing imports it); it is NOT the live Edit mechanism.
Re-derive:
    sed -n '1,15p' api/assets/paper-editor/src/canvas/run-convert.js   # "It SHIPS DARK. Nothing imports it…"

## Claim 3 — stats CSS lives ONLY in paper-surface.css (not mirrored); `.bp-stat__v` today = plain --paper-ink, no tone.
Re-derive:
    grep -n "bp-stat__v\|bp-stat\b\|bp-stats\b" api/assets/paper-surface/paper-surface.css   # 1327-1341

## Claim 4 — Two token families + a THIRD (new) proposal:
- `--st-*` (info/ok/warn/danger/violet): GENERATED from design/status-manifest.json (paper-surface.css:669 BEGIN GENERATED: status-tones). Used as BARE FOREGROUND verdict/status color already: bp-g--done, bp-trow__p, board cols, roadmap bars, card left-accent.
- `--bp-tone-*` (info/success/warning/danger/neutral, each bg+fg PAIR): callout tints. tokens.json:524 — emits as Render.TokensGen.callout/1 (light) + bulldocs reader-skin re-stamp (dark). A bg+fg PAIR contract for tinted callout grounds — NOT a bare value color.
- NEW `loss/peace(+soft)` via derive SLOTS: task pe-bl-verdict-accent-tokens (OPEN) wants terracotta/green semantic verdict tokens through the derive contract, gated by check.mjs Part F + Part H (WCAG). pe-bl-stat-tile-dots "verdict coloring on values" DEPENDS on it.
Re-derive:
    sed -n '669,675p' api/assets/paper-surface/paper-surface.css
    sed -n '46,74p;488,492p' api/assets/paper-surface/paper-surface.css
    bp task get pe-bl-verdict-accent-tokens -o json
    bp task get pe-bl-stat-tile-dots -o json

## Claim 5 — NO existing contrast gate covers paper stat/tone tokens as stat-VALUE foregrounds.
check.mjs Part F reds derive-SLOTS colors only; Part H checks CURATED Studio chrome pairings only. --st-* (status-manifest) and --bp-tone-* (hand/callout) are outside both. Routing loss/peace through derive SLOTS (pe-bl-verdict-accent-tokens) is the ONLY path that earns Part F/H contrast enforcement.
Re-derive:
    sed -n '746,760p;855,885p' design/check.mjs   # Part H curated PAIRINGS
    sed -n '570,580p' design/check.mjs            # Part F derive-returned-color contrast red

## Recommendation
For CONSISTENCY + the wave's "zero new tokens / measure-and-name" mandate: stat VALUES ride `--st-*` (st-danger=loss, st-ok=kept) — the family already used as bare verdict foregrounds and as the card left-accent. `--bp-tone-*` is the wrong family for a bare colored number (bg+fg pair contract). Caveat for Decide: this path is contrast-UNGATED; pe-bl-verdict-accent-tokens's derive-SLOTS loss/peace path is the only gated one and directly contradicts "zero new tokens" — the two are competing designs of the same feature and Decide must pick one.
