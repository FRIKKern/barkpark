<!-- doc-tier: agent | canonical-for: go-client-correctness-epic | budget: 4000tok -->
# Go Client Correctness & Robustness Epic — Charter

Epic task: `go-client-correctness-audit` · Wave 1 Paper: `go-client-correctness-wave-2026-08-18`

## Vision

The Go bp client (`internal/`) — the CLI plus the TUI (rendering, the pdrender layout
engine, command dispatch, the manifest-driven command tree) — must be correct and robust
under adversarial, empty, multibyte, and narrow-terminal input. This is a NON-security lens,
disjoint from the already-merged Go security bundle (imageTag charset, docker-load argv,
manifest name-charset, config redaction, completion quoting). Four correctness classes:
panic-safety, error-handling, TUI render correctness, CLI robustness. Improvement-only,
evidence-based: every candidate finding is re-derived against `origin/main` by grep pattern
(line numbers drift), a SAFE verdict NAMES its guard, and a REAL finding carries its exact
triggering input plus a table-driven test that reds without the fix. The honest per-class
verdict — the count even when zero — is the deliverable, not a manufactured finding.

## Decisions

- **Breadth-with-honest-verdicts, weighted to thin-guard surfaces.** — The richest-LOOKING
  vein (pdrender width math) is the best-defended; reachable defects concentrate where guards
  are thin and inputs hostile (CLI parse, manifest ingest, live-terminal TUI). Grounding + 14
  survey lanes proved this: near-total SAFE with cited guards.
- **pdrender / layout solver / manifest / strconv / type-asserts / goroutines = CERTIFY, not mine.** — All swept SAFE with a named guard per site; the layout solver's only divide is clamped (tracks<1→1) and mutation-proven (removing it reds `TestFlexMeasureClampsTracks`). Manufacturing a finding on guarded code violates the audit's honesty.
- **Two confirmed render findings are FIXED this wave, both LOW/cosmetic, both offline-provable.** — `servers_cmd.go` measures/pads columns by rune-count (`%-*s` + `utf8.RuneCountInString`) not display cells, shearing columns on wide-CJK/emoji names; `chat/render.go` `truncate()` has a wide-rune off-by-one (hardcoded `+1` assumes a width-1 tail). Both have a red-without-fix table test in hand from verify.
- **cloudclient decode-swallow is FILED, not fixed.** — `TeamMembers`/`TeamInvitations` swallow the inner-array decode; the human path prints "(no members)" for an undecodable-but-valid-JSON array while `-o json` (Raw) stays correct. REAL-low; the remedy is a render-contract choice better filed with the failing input than force-fixed in a verify pass.
- **The bare `go test ./internal/...` red is pre-existing and environmental.** — `TestNoInlineDivideFormulaOutsideSolver` matches untracked `.omx`/`mainbase` shadow copies of `joincols.go` in the shared primary checkout; `TestMomentumInFlightDenominatorCollapsed` is an intermittent taskboard flake. Gate every slice per-package/`-run`, in a clean worktree, `CC=/usr/bin/clang CGO_ENABLED=1`.
- **The security bundle is off-limits.** — Six merged seams (runtime imageTag + docker-load argv, manifest safeName, config MarshalJSON redaction, completion quoting, scaffy-pull path containment, grip screenCommand) are SAFE-BY-FIX; the correctness lens never re-paves them. Manifest panic-safety on the DECODED tree remains fair game and is distinct from the name-charset gate.

## Roadmap

Wave 1 (this wave) — build the two confirmed fixes + lock the one genuinely load-bearing
untested guard; file the deferred finding:

- **W1-S1 servers_cmd runewidth column fix** (small, opus, round 1) — `internal/cli/servers_cmd.go` + test. Measure/pad with `runewidth.StringWidth`/`FillRight` mirroring `table.go`.
- **W1-S2 chat truncate wide-rune off-by-one** (small, opus, round 1) — `internal/chat/render.go` + new `truncate_test.go`. Reserve one cell for the ellipsis by actual per-rune width.
- **W1-S3 pdrender narrow-terminal guard regressions** (small, opus, round 1) — `internal/pdrender/*_test.go`. Red-on-removal tests for the divider `gw>=w` guard (probe-proven panic at `Width:2`) and `padOrTruncate` `w<=0`.
- Backlog: cloudclient decode-swallow (file); taskboard composeAt/Compose floor coverage-gap (file, defense-in-depth, low).

Future waves (only if a real vein appears): the corners no surveyor deeply read — `internal/agent` df/size parse, `internal/hetzner`, `internal/backup` bodies, `internal/builder`; a live-terminal fuzz of taskboard/chat resize math. File findings as standalone `go-correctness` children; no fresh build wave without evidence.

## Wave log

### Wave 2026-08-18

**Landed** — three round-1 slices, all Opus, file-disjoint, each proven red-without-fix (or red-on-removal), reviewed with no fixes needed:

- **W1-S1 servers_cmd runewidth column fix** (`gocorrect-w1-servers-runewidth`, PR #12406) — `internal/cli/servers_cmd.go` now measures/pads NAME/KIND columns with `runewidth.StringWidth`/`FillRight` (display cells) instead of `utf8.RuneCountInString`/`%-*s` (rune-count), so wide-CJK/emoji DisplayNames no longer shear the SERVER column. `-o json/yaml` byte-identical. `TestServersTableWideRuneColumnAlignment` mutation-proven (reds on origin/main, delta 3).
- **W1-S2 chat truncate wide-rune off-by-one** (`gocorrect-w1-chat-truncate`, PR #12407) — `internal/chat/render.go` `truncate()` now reserves one display cell for the ellipsis by actual per-rune width; a width-2 rune at the boundary no longer overshoots `w` by one cell. `TestTruncateWidthBound` (10 cases) mutation-proven by the reviewer (reverting the break condition reds emoji_overshoot 5>4 and mixed 5>4).
- **W1-S3 pdrender narrow-terminal guard regressions** (`gocorrect-w1-pdrender-guard-tests`, PR #12408) — test-only; `blocks.go`/`sheet.go` byte-identical to origin. `TestDividerNarrowWidthGuard` (divider at Width:2 panics `strings: negative Repeat count` on guard removal) and `TestPadOrTruncateZeroWidth` (returns `…` not input on guard removal) lock two load-bearing guards uncovered by the golden suite (min width 40).

**Grade A.** Honest per-class verdict delivered: 14 survey lanes swept near-total SAFE with cited guards; only two confirmed render findings (both LOW/cosmetic rune-vs-cell), both fixed with mutation-proven table tests; one genuinely load-bearing untested guard pair locked. No manufactured findings. Reviewer re-ran every gate green, independently mutation-checked the chat test, and found nothing to fix.

**Filed, not built** — `gocorrect-cloudclient-decode-swallow` (REAL-low: `TeamMembers`/`TeamInvitations` swallow the inner-array decode, human path prints "(no members)" for an undecodable array while `-o json` stays correct — a render-contract choice) and `gocorrect-taskboard-floor-coverage-gap` (defense-in-depth `composeAt`/`Compose` floors untested, removal reds nothing). Both `open` under the epic.

**Next wave** — dispatch is trivially parallel: all three PRs are file-disjoint, merge in any order. Then, only if a real vein appears, mine the unread corners the survey flagged: `internal/agent` df/size parse, `internal/hetzner`, `internal/backup` bodies, `internal/builder`; a live-terminal fuzz of taskboard/chat resize math; and consider the two filed backlog findings. No fresh build wave without fresh failing-input evidence.
