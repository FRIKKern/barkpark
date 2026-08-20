# ttw22 — close-bar adjudication re-derivation recipes (vf-close-bar-adjudication, 2026-08-17)

Anchors are origin/main c37a2924. Each row: claim → the one command that re-derives it.

| # | Claim | Rerun |
|---|---|---|
| 1 | bottomChrome lives in render.go (NOT compose.go — the tasked path was stale); footer = statusFooter + verbs line | `git grep -n 'func bottomChrome' origin/main -- internal/taskboard/` |
| 2 | (a) momentumLine paints Counts["in_progress"] unconditionally; BuildBoard copies s.Counts verbatim | `git show origin/main:internal/taskboard/render.go \| sed -n '281,287p'; git show origin/main:internal/taskboard/board.go \| sed -n '320,326p'` |
| 3 | (a) cache-primed paint is NOT "syncing…" — primeFromCache sets LastSync=snap.FetchedAt (non-zero), isSyncing needs LastSync.IsZero() | `git show origin/main:internal/taskboard/program.go \| sed -n '278,288p'; git show origin/main:internal/taskboard/render.go \| sed -n '611,613p'` |
| 4 | (a) Snapshot has NO version field — an old-binary cache unmarshals silently into a new binary | `git grep -n -A9 'type Snapshot struct' origin/main -- internal/taskboard/types.go` |
| 5 | (b) windowSpine/windowTargets are named by ZERO test files (mutation survivors unguarded) | `git grep -ln 'windowSpine\|windowTargets' origin/main -- internal/taskboard/*_test.go` (empty) |
| 6 | (c) Breadcrumb has zero non-test callers — kept alive by compose_test.go:350 only | `git grep -n '\bBreadcrumb(' origin/main -- internal/taskboard/` |
| 7 | (d) cacheKey hashes server+workspace+project only — no Dataset | `git show origin/main:internal/taskboard/cache.go \| sed -n '41,45p'` |
| 8 | (e-A/B) board grammar = j/k/g/G/enter/h/l/c/x/o; space/u/d/pgdn fall through to silent no-op; footer documents only "jk move" | `git grep -n -A52 'func (m Model) handleBoardKey' origin/main -- internal/taskboard/program.go` |
| 9 | (e-C) handlePreviewKey reachable only via wideFocus==reader at depth 0; only MOUSE sets that (compose.go:679); enterTask pushes depth; D117 rejected a pane key | `git show origin/main:internal/taskboard/program.go \| sed -n '564,575p'; git show origin/main:internal/taskboard/compose.go \| sed -n '677,680p'` |
| 10 | (f) ● + "server timeout" is two truth sources by design: pulse lifts dot on liveIsFresh, label cleared only by a landed snapshot | `git show origin/main:internal/taskboard/live.go \| sed -n '121,145p'` |
| 11 | (g depth 0) wide c/x/o clicks fully routed: verb-first hit-test in handleWideMouse; footerVerbAt wide branch at live boardPaneCols | `git show origin/main:internal/taskboard/compose.go \| sed -n '638,650p'; git show origin/main:internal/taskboard/program.go \| sed -n '939,957p'` |
| 12 | (g depth >0) left pane paints full board footer (Render unconditional in composeAt wide) while footerVerbAt bails on pushed frame → painted verbs, no click route, no hover tint | `git show origin/main:internal/taskboard/compose.go \| sed -n '287,292p'; git show origin/main:internal/taskboard/program.go \| sed -n '940,942p'` |
| 13 | (g mitigation) keys stay honest at depth>0: wideFocus==board routes ALL keys to handleBoardKey; reader focus routes c/x/o to the reading subject | `git show origin/main:internal/taskboard/program.go \| sed -n '564,575p'` |

Verdicts (full rationale in the verifier's structured output; the wave paper carries them):
(a) FIX — clause 1, run-proof-gated. (b) test-debt, NOT clause 3; guard slice per D116 lineage or bequest.
(c) FIX-as-rider, no clause. (d) RATIFY-WITH-A-D (hygiene, out of bar; rider on (a) permitted).
(e) A/B/C all RATIFY-WITH-A-D — clause 2 unviolated. (f) RATIFY — D114 stands.
(g) depth-0 concern REFUTED; depth>0 painted-verbs-no-click-route FOUND → RATIFY-WITH-A-D
(key-help, depth-0-only click affordance; no-tint is the honesty mechanism; footnote D121).
