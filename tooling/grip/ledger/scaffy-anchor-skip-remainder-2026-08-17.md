# Scaffy repocheck — the 5 undissected token-anchor skips (anchor-skip-remainder)

Re-derives the recoverability census for the EXAMPLES-with-file-existence-guard
slice. All commands run from repo root on origin/main (HEAD a653550420). `bp`
is the installed CLI (`bp scaffy validate --repo`).

## Skip inventory (no-vars → the 5 skips)

    for f in remove-docs-card add-canonical-marker add-cli-verb ensure-import; do
      bp scaffy validate --repo . scaffy/commands/$f.scaffy -o json; done

remove-docs-card → anchors_skipped_token:2 ; the other three → :1 each = 5 total.
None of the 4 files carry ONEOF (`grep -l ONEOF` on them = none). @section-style
ONEOF lives only in classify-block-type.

## Per-skip verdict (each proven by a --var probe with declared EXAMPLES)

1. remove-docs-card op1  IN docs/INDEX.md REPLACE — ANCHOR token ({{.card-name}}); path static.
2. remove-docs-card op2  IN CLAUDE.md REMOVE — ANCHOR token ({{.card-name}}/{{.Group}}/{{.TaskPattern}}); path static.
   Probe: --var CardName=Wavecheck --var Group=Ops --var TaskPattern='render path / paper surface'
   → BOTH R-002 anchor-not-found. Files EXIST; anchors are add-docs-card's PLANTED
   state, absent on a clean tree (grep ",wavecheck,tui" / "MARK:claude-route-wavecheck" = 0).
   VERDICT: FALSE-RED under naive expansion. File-existence guard INSUFFICIENT (files present).
   MUST STAY SKIPPED — needs a "forward command applied" precondition validate cannot give.

3. add-canonical-marker  IN {{.TargetFile}} INSERT BEFORE FIRST — PATH token; anchor {{.HeadLine}} also token.
   Probe A: --var TargetFile=internal/apiclient/client.go --var HeadLine='func New(cfg Config) *Client {'
            --var slug=api-client-new --var Aka=New,client,constructor --var CommentToken=//  → anchors_ok:1, 0 findings
   Probe B: --var TargetFile=api/lib/barkpark/content/graph.ex --var HeadLine='  def clamp_depth(nil), do: @default_depth'
            --var slug=graph-depth-clamp --var Aka=depth,clamp,bound --var CommentToken=#   → anchors_ok:1, 0 findings
   Both example TargetFiles EXIST; both HeadLine examples resolve (client.go:169, graph.ex:87).
   VERDICT: RECOVERABLE — the ONLY of the 5 that becomes CHECKABLE under the guard.

4. add-cli-verb  IN api/lib/barkpark/plugins/{{.plugin}}.ex INSERT AFTER FIRST — PATH token; anchor static (def cli_commands do / [).
   Plugin EXAMPLES = bookmarks, analytics → BOTH files ABSENT on HEAD.
   Probe bookmarks (Plugin/Noun/Verb/Summary/PathTemplate) → R-001 missing-file.
   Probe tickets (exists) → R-002: tickets.ex:315 `def cli_commands do` DELEGATES (if Code.ensure_loaded?…),
   not `    [`. NO plugin in api/lib/barkpark/plugins/*.ex carries the open shape.
   VERDICT: STAYS SKIPPED — existence guard correctly skips the absent examples (no false-red),
   but the command is uncheckable on HEAD (anchor is add-plugin's generated OPEN shape, on no live file).

5. ensure-import  IN {{.TargetFile}} INSERT AFTER FIRST — PATH token; anchor {{.AnchorLine}} also token.
   TargetFile EXAMPLES exist (content.ex, tickets.ex); AnchorLine EXAMPLES are GENERIC/unpaired
   ("  use Ecto.Schema" / "  use Barkpark, :context" / "  require Logger") — none present in either example file.
   Probe (content.ex + 'use Barkpark, :context'), (tickets.ex + 'use Ecto.Schema') → BOTH R-002.
   VERDICT: FALSE-RED under naive expansion. Existence guard INSUFFICIENT (file present, anchor absent
   because EXAMPLES are per-variable lists, not coherent tuples). MUST STAY SKIPPED absent a curated tuple.

## Census for the guard slice (my 5 of the 17)

- CHECKABLE (recovered): add-canonical-marker            — 1 skip
- STAYS SKIPPED (guard skips absent-file examples, safe): add-cli-verb — 1 skip
- WOULD FALSE-RED, must stay skipped: remove-docs-card×2 + ensure-import×1 — 3 skips

## Load-bearing design finding

The file-existence guard only defends against R-001 (absent file). It does NOTHING
for R-002 (file present, anchor absent) — the exact failure mode of remove-docs-card
(planted-state anchors) and ensure-import (unpaired per-variable EXAMPLES). A skip is
safely promotable to a CHECK only when a COHERENT example tuple resolves on HEAD, which
today is true for exactly one of the five (add-canonical-marker). Naive "expand every
EXAMPLES value" is unsafe. Slice scope = curate coherent tuples + skip-on-R-002, not
just skip-on-R-001.
