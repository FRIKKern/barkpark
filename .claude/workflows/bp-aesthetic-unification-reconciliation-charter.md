# Aesthetic unification — reconcile the ledger with the shipped lockstep (aesthetic-unification epic charter)

> NOTE ON THIS PATH: this filename is the epic-cycle charter slot and has carried earlier
> epics. Preserved verbatim: **self-update W5** at `bp-self-update-w5-charter.md`,
> **gui-premium W5** at `bp-gui-premium-w5-charter.md`, **p-quality-gate** at
> `bp-hollow-paper-gate-charter.md`, and **composition-doctrine** at
> `bp-composition-doctrine-charter.md`. This file is now the memory of the
> **aesthetic-unification** epic (reconciliation wave). The epic's ORIGINAL build history
> lives in `bp-unified-aesthetic-endgame-charter.md` (W1–W3 endgame) — read it for how the
> lockstep was built; read THIS file for how the epic closes.

Epic anchor: bp task slug **`aesthetic-unification-epic`** ("Apply the cloud design profile
to every Barkpark surface", published, priority 1, 55 children). Wave paper:
`aesthetic-unification-epic-wave-2026-07-11`. Server: guerrilla.

## Vision

The anchor's four criteria are either stamped met:true with file:line + PR + run-proof
evidence, or carry a written split with a single named human-gated remainder — and the
child ledger contains zero fabricated claims, zero superseded wishlist tasks, and exactly
the honest remainder (visual-audit ratification, brand mark, reading typography) plus a
small filed backlog. "Every Barkpark surface" is TRUE through one mechanism: the
tokens.json → derive.mjs → emit.mjs lockstep (17 artifacts, check.mjs Parts A–H), whose
Part E exemptions ledger is the COMPLETE registry of hand-stamped residue — nothing
un-gated, nothing silently parallel.

## Non-negotiable operational facts (builders read FIRST)

- Tokens ONLY via the 3-file lockstep (design/tokens.json + derive.mjs + emit.mjs).
  Go/Elixir tokens_gen files stay BYTE-STABLE unless a slice explicitly owns a regen —
  this wave, NO slice does (preflight proved the web-only slices ripple into
  web/app/globals.css + web/lib/tokens.gen.ts only).
- check.mjs must stay green incl. Part F byte-identity + Part H AA; studio-literal-check
  zero new lit-allows; a NEW color leaf must be registered in derive.mjs
  PASSTHROUGH_FAMILIES (and derive.test.mjs's hardcoded count bumped) or Part F reds.
- .ex/.heex changes WAIT for the Elixir Test CI gate before merge. Worktrees from
  origin/main after `git fetch` (the shared checkout carries foreign in-flight edits —
  a local check.mjs Part E red on root.html.heex 165→166 is another session's
  uncommitted edit, not yours). Claim your bp task BEFORE working. PR body carries
  `Task: <id>`. `cc` is a Claude wrapper — always `CC=/usr/bin/clang`.
- doc-gates is a blocking CI STEP, not a GitHub-required check: main has NO branch
  protection/rulesets (rulesets API `[]`, protection 404, re-proven 2026-07-11).
  Reviewer discipline is the merge net.

## Decisions

- **D1 Reconciliation, not construction.** The 17-artifact lockstep is alive and green
  (emit --check 17/17; check.mjs A–H incl. F byte-identity + H 162/162 AA; CI runs
  29128797161 push + 29129285343 PR, and green on d655b753 = current origin/main). The
  epic's gap was ledger-vs-reality, so this wave stamps evidence, cuts dead scope, and
  builds only 3 surgical slices.
- **D2 The wish's four suspected outside-surfaces DISSOLVED with file:line proof.**
  Email is IN the lockstep (fleet `:email` renderers ← Palettes.email_skin ←
  TokensGen artifact #11; one documented literal exception panels_email.ex:104-106;
  tones via governed status-manifest.json). /activate + CP login ride the cloud SPA
  artifact (router.ex:317-348 → index.html:14 → app.css, emit.mjs:1720). Marketing =
  web/ (already in lockstep); js/docs is dormant/unwired — scope-cut per
  docs/decisions/deferred.md:8. PDF/print = tokenized @media print blocks with one
  frozen literal each (exemptions.json:13); no PDF pipeline exists — scope-cut.
- **D3 C1 stamps only after Part E becomes the complete residue registry** (slice R1):
  ledger styles.css / bp-paper-editor.css / paper-surface.css / the bp-graph.js mirror
  pair with rationale, and teach Part E's LEDGER_MARKER to also blank
  `GENERATED: paper-surface` and `GENERATED: status-tones` blocks. Why: today 329
  ledgered vs ~646 un-ledgered literals makes "single source of color" materially false.
- **D4 Adopt, don't just freeze, the two LIVE ungated surfaces** (slice R3): tokenize
  inbox_live.ex (48 literals) + board_live.ex (32) and extend studio-literal-check.sh
  beyond api/lib/barkpark_web to api/lib/barkpark/plugins. Why: live chrome with
  parallel palettes that NO gate scans is the strongest C1 counterexample; both files
  have targeted tests (102 green locally) so the change is provable.
- **D5 bp-graph.js Canvas palette: exempt-with-rationale now, tokenize later** (backlog
  au-r6). Why: Canvas fillStyle can't consume var() directly (Mermaid-JS-init class);
  the pair is byte-frozen (5c10b76e) so it cannot drift while exempt.
- **D6 Graph-canvas + paper-callout web adoption are ONE slice** (au-w3-graph-canvas-token,
  widened). Why: both edit adjacent emit.mjs functions (webBlock ~551 / webTokensTs ~574)
  — parallel builders would merge-conflict; and the callout palette must come from
  color.paperCallout, NEVER color.status (tokens.json:229 forbids the substitution —
  the digest's status-token idea was wrong). Preflight proved the 4-file shape:
  tokens.json + emit.mjs + derive.mjs PASSTHROUGH_FAMILIES + derive.test.mjs count bump;
  web-only byte ripple.
- **D7 C3 wording law.** Stamp as: "blocking CI step in doc-gates.yml (no
  continue-on-error), green on HEAD and on PR-event runs, team-enforced per
  docs/ops/merge-gates.md — main has no GitHub ruleset or branch protection." NEVER
  "GitHub-required check" (proven false).
- **D8 C4 splits: generated TRUE / ratified FALSE.** The cross-surface instrument
  coherence.html is real (#1397/#1718), token-fed, 7 S5 tests green (383/383 harness);
  per-surface styleguides carry the sg-ratify gate (charter decision 27). But the
  ratification EVENT never happened — `au-w6-visual-audit` is the single named
  remainder (human-gated). coherence.html stays UNROUTED by design
  (verify-via-standalone-harness doctrine; routing would expose the __preview__ subtree).
- **D9 The W5.B component-block family is CUT** (10 unbuilt comp-* + view-remainder +
  authoring + gate + comp-styleguide + task-authoring + revamp-tokenize +
  figures-classes → closed `cancelled` with rationale). Why: composition-doctrine P2
  (ratified 2026-07-07) kills the read-only/server-painted `_raw` tier these tasks
  specify; rebuilding them would contradict shipped doctrine. Real content need
  re-expresses as an editable widget under the composition-doctrine epic — never a
  resurrection of these task ids. figures.ex is proven token-compliant (var() sourced
  fallbacks), so its class-refactor task is tree-tidiness and earns nothing.
- **D10 comp-chart closes on REAL evidence; comp-quote must not be laundered.** chart:
  compose.ex:1139 → DataViz.chart_html (data_viz.ex:416, server SVG, shipped by #1600);
  bars+line real, area deferred-with-record. quote: pullquote (compose.ex:262) carries
  no attribution — closing quote onto it would be a fresh false-done; it is cut with
  the family.
- **D11 Fabrication scrub.** The 11 tasks carrying the byte-identical "459 render tests
  green" summary get it replaced with honest text (comp-chart lacked even a
  reopen_note); paper-components-view loses "(SHIPPED)"/"DONE."; paper-components-
  authoring loses its "au-w5-comp-* all DONE" false premise. The 4 done styleguide
  tasks (#1338/#1439/#1448/#1466 all MERGED) get criteria back-stamped from PR evidence,
  marked PLAUSIBLE where not re-run.
- **D12 pdrender-web-tokens splits.** Go half closes NOW on fresh run-proof
  (build/vet/test -count=1 green; chart.go:421 + heatmap.go:384,674 consume Gen*; zero
  stray draw-site literals) + PRs #1395/#1691/#1984 — with the "via semrole" wording
  amended (pdrender may NEVER import semrole; the byte-identical sibling copy is the
  documented architecture). Web half lives in the widened graph-canvas slice.
- **D13 Honest remainder after this wave:** au-w6-visual-audit (ratification event,
  human — unblocked by the paper-components-gate cut), au-w6-brand-mark (needs a
  human-drawn mark; cloud/priv/static has NO favicon at all), au-w5-reading-typography
  (spec §7 human gate), plus filed backlog au-r4 (web type ladder — W3.9 closed without
  wiring TYPE_SCALE/HEADING to emitted --text-*), au-r5 (paperEmail "w3 reconciles"
  dangling note — divergence #1e5347 vs #1e5243 is deliberate but unowned), au-r6
  (bp-graph palette tokens via getComputedStyle).
- **D14 Epic close condition.** Lead stamps C1 after R1+R3 merge, C2+C3 now, C4 as the
  recorded split; the epic itself closes only when au-w6-visual-audit's human sign-off
  is recorded (or a human explicitly waives it) — never before.

## Roadmap

Wave R (2026-07-11, reconciliation — 3 build slices + lead-executed ledger work):

| id | slice | size | model |
|---|---|---|---|
| R0 | (lead, this phase) fabrication scrub, W5.B cuts, back-stamps, C2/C3 stamps, backlog filing | — | fable (Decide) |
| R1 | `au-r1-ledger-extension` — Part E complete-registry + marker fix | S | opus |
| R2 | `au-w3-graph-canvas-token` — web token adoption: graph-canvas + paper-callout | M | fable |
| R3 | `au-r3-plugin-liveview-tokens` — tokenize inbox/board LiveViews + scan-root extension | M | fable |

After wave R: lead stamps C1 (post-merge), closes R-slice tasks on merge. Remainder:
au-w6-visual-audit (human ratification → epic close), au-w6-brand-mark,
au-w5-reading-typography. Backlog: au-r4-web-type-ladder, au-r5-email-brand-reconcile,
au-r6-graph-palette-tokens.

## Wave log

### Wave 2026-07-11 (wave R — reconciliation; reviewed, grade A-)

All 3 slices built green and reviewed; zero code fixes needed. **R1
`au-r1-ledger-extension`** (branch `loop-epic/part-e-becomes-the-complete-residue-regi-0`):
Part E LEDGER_MARKER generalized to any `BEGIN/END GENERATED:<name>` block via a
captured-name backreference (abutting status-tones+tokens blocks in paper-surface.css each
strip cleanly — verified against the real markers); the 5 un-gated files ledgered with
measured counts (styles.css 57, bp-paper-editor.css 107, paper-surface.css 35,
bp-graph.js 91×2) + honest rationales; au-r6 backlog filed. **R2
`au-w3-graph-canvas-token`** (`…web-token-adoption-graph-canvas-surface--1`):
color.graphCanvas through the full 4-file lockstep shape (tokens.json + emit webBlock +
derive PASSTHROUGH 13→14 + test bump), web now ZERO lit-allows; paperCallout emitted into
web/lib/tokens.gen.ts and portable-doc.tsx repainted via CSS custom props + static class
strings — reviewer re-ran 232/232 web tests + tsc and tamper-proved the card-tone parity
leg non-vacuous (dropping the style vars reds exactly 1 test). **R3
`au-r3-plugin-liveview-tokens`** (`…tokenize-the-two-un-gated-plugin-livevie-2`):
inbox_live + board_live fully tokenized (dead var(--x,#hex) dark palette → the emitted
Studio vocabulary; the 12-line per-theme glyph fork deleted — --life-* flips at the root;
`layout: {Layouts,:studio}` verified via router.ex:768); scan root extended to
api/lib/barkpark/plugins (347 files) with zero new allowlist entries for the targets;
reviewer re-ran 104/104 targeted Elixir tests + mix format + a live tamper-probe red.

**Cross-slice:** an integration trial merge of all three onto origin/main (a4b14a2a) is
conflict-free with every gate green (check.mjs A–H, emit --check 17/17, derive 61/61,
web+studio literal checks, web 232/232). R1 and R2 carry a byte-identical root.html.heex
fix for the committed upstream Part E regression (2afbe5fc, 165→166) — identical changes
merge cleanly. Correction of record: Decide called that red "another session's
uncommitted edit"; it was in fact COMMITTED to main. **Merge order: R1 → R2 → R3** (R3's
branch alone still sees the upstream red; each later merge is a no-op on the shared
line). R1+R2 touch .heex → WAIT for Elixir Test CI. Lead closes merge-gated criteria on
merge, then stamps epic C1 per D3/D14.

Ledger fixes this review: r3 criteria 1–3 flipped met:true (proven locally,
non-merge-gated, reviewer re-verified). Backlog filed:
`au-r7-web-dark-variant-binding` (web `dark:` classes follow prefers-color-scheme while
the emitted --color-* vars follow the data-theme toggle — pre-existing split, now
touching token values via the callout classes).

**Next wave:** this was the LAST agent-buildable wave. Remainder per D13/D14:
au-w6-visual-audit (human ratification event → epic close), au-w6-brand-mark,
au-w5-reading-typography; backlog au-r4/r5/r6/r7. Nothing stands between these merges
and the close ceremony except the human sign-off.
