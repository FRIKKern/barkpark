# ttw20 anchor-currency re-derivation (wave 20 verify) — 2026-08-17

Re-derives the corrected file:line anchor set for the five wave-20 slice briefs
against origin/main (not the polluted primary checkout). Every row below is
reproducible with the one command in its `rerun`.

## One-shot: dump every cited anchor from origin/main

    cd /Volumes/SATECHI/github/barkpark && git fetch origin -q
    show(){ git show origin/main:internal/taskboard/$1 | sed -n "${2},${3}p"; }

## Corrected anchors (origin/main @ fetch 2026-08-17)

| capability | symbol | origin/main anchor | stale anchor cited in task | rerun |
|---|---|---|---|---|
| conn-flap: 5s default | `const DefaultTimeout` | internal/apiclient/client.go:25 | (digest) client.go:25 ✓ | `git show origin/main:internal/apiclient/client.go \| sed -n 25p` |
| conn-flap: client omits Timeout | `apiclient.New(Config{…})` in `Run` | program.go:1774-1780 (no Timeout field) | digest said :1753 | `git show origin/main:internal/taskboard/program.go \| sed -n '1774,1780p'` |
| conn-flap: board feed | `fetch: FetchSnapshotFull` | program.go:232 | — | `git show origin/main:internal/taskboard/program.go \| sed -n 232p` |
| conn-flap: heavy corpus GET | `getJSON(c,"/v1/tasks?limit=1000")` | detail_data.go:67 (in FetchSnapshotFull :55) | fetch.go comment :19 names it | `git show origin/main:internal/taskboard/detail_data.go \| sed -n 67p` |
| conn-flap: prime clamp | `primeReadyLimit=100` / `fetchPrime` | fetch.go:54 / :125 | — | `git show origin/main:internal/taskboard/fetch.go \| sed -n '54p;125p'` |
| conn-flap: default→"offline" | `snapshotErrorLabel` default | live.go:321 (func) / :339-340 (default→"offline") | task cites :330-345 range | `git show origin/main:internal/taskboard/live.go \| sed -n '321,342p'` |
| conn-flap: stickiness | `handlePulse` won't lift ConnOffline | live.go:126 (func) / :128 (guard) | digest :128 ✓ | `git show origin/main:internal/taskboard/live.go \| sed -n '126,134p'` |
| conn-flap: liveIsFresh | `liveIsFresh` | live.go:347 | — | `git show origin/main:internal/taskboard/live.go \| sed -n 347p` |
| conn-flap: TEST pins label | `ConnProblem != "offline"` + table `{"dial tcp: connection refused","offline"}` + pulse-no-clear | live_test.go:107-108, :133, :483 | (Decide asked) | `git show origin/main:internal/taskboard/live_test.go \| sed -n '107,108p;133p;483p'` |
| wide-focus: reader set | `m.wideFocus = wideFocusReader` in `enterTask` | program.go:1246 (func) / :1248 (set) | task :1228 | `git show origin/main:internal/taskboard/program.go \| sed -n '1246,1248p'` |
| wide-focus: ONLY board-set | `m.wideFocus = wideFocusBoard` (mouse press) | compose.go:670 | task :658 | `git show origin/main:internal/taskboard/compose.go \| sed -n 670p` |
| wide-focus: esc handler (fix locus) | `case "esc","backspace": popFrame()` | program.go:548-549 | (digest) :548-555 ✓ | `git show origin/main:internal/taskboard/program.go \| sed -n '548,549p'` |
| wide-focus: board-key gate (reads only) | `if m.wide && m.wideFocus==wideFocusBoard` | program.go:555 | — | `git show origin/main:internal/taskboard/program.go \| sed -n 555p` |
| geom: composeAt floor | `if width < 20 { width = 20 }` | compose.go:234-237 (func :234, floor :235-237) | task :234-236 ≈ ✓ | `git show origin/main:internal/taskboard/compose.go \| sed -n '234,237p'` |
| geom: readingWidth (no re-floor) | `func (m Model) readingWidth()` — subtracts 3/4, no re-floor | program.go:1692 | task :1544/:1672 | `git show origin/main:internal/taskboard/program.go \| sed -n '1692,1705p'` |
| geom: minReadingWidth | `minReadingWidth = 24` | compose.go:35 | (digest) :35 ✓ | `git show origin/main:internal/taskboard/compose.go \| sed -n 35p` |
| geom: docBodyRow seam twin | `func docBodyRow(pl int) int { return pl - 1 }` | compose.go:232 | (task) :232 ✓ | `git show origin/main:internal/taskboard/compose.go \| sed -n 232p` |
| geom: GUARDED renderDocPane | `avail := paneH - 1` | compose.go:211 | (task) :211 ✓ | `git show origin/main:internal/taskboard/compose.go \| sed -n 211p` |
| geom: GUARDED narrow footer | `paneH := height - 1` | compose.go:258 | (task) :258 ✓ | `git show origin/main:internal/taskboard/compose.go \| sed -n 258p` |
| geom: UNGUARDED rightPaneStopAt | `avail := inner - 1` | compose.go:911 (func) / :926 (avail) | task :905 | `git show origin/main:internal/taskboard/compose.go \| sed -n '911p;926p'` |
| geom: UNGUARDED scrollPreview | `maxTop := len(body) - (inner - 1)` | compose.go:952 (func) / :959 (maxTop) | task :938 | `git show origin/main:internal/taskboard/compose.go \| sed -n '952p;959p'` |
| geom: 4th height-2 copy | `avail := height - 2` | hitmap.go:208 | (task) :208 ✓ | `git show origin/main:internal/taskboard/hitmap.go \| sed -n 208p` |
| geom: pendingClose clear (mouse) | `m.pendingClose = ""` | compose.go:665-666 | task :653-654 | `git show origin/main:internal/taskboard/compose.go \| sed -n '665,666p'` |
| drafts: NOW predicate (NO drafts filter) | `if t.Claim!=nil && …Worker!="" && …Lifecycle==lifeInProgress` | board.go:356-360 (if at :357) | (task) :356-360 ✓ | `git show origin/main:internal/taskboard/board.go \| sed -n '355,360p'` |
| drafts: bareID join-norm only | `bareID` / `draftsPrefix` uses | detail_data.go:108, repoctx.go:32/94/102 | — | `git grep -n draftsPrefix origin/main -- internal/taskboard/` |
| hue (STALE wish): detail | `const detailProfile = pdrender.NoColor` | detail_render.go:65 | (digest) :65 ✓ | `git show origin/main:internal/taskboard/detail_render.go \| sed -n 65p` |
| hue (STALE wish): paper | `paperRailProfile = pdrender.ANSI256` | paper.go:36 | (digest) :36 ✓ | `git show origin/main:internal/taskboard/paper.go \| sed -n 36p` |

## Premise flags for Decide

- **ttw19-bl-drafts-now-drop AC#1 encodes the REFUTED premise.** It demands
  "the exact api/ code locus that omits draft-namespaced docs from the published
  tasks list." The Go tree has NO drafts filter (board.go:356-360 is pure
  claim/worker/lifecycle; every draftsPrefix is JOIN-normalization). Survey +
  charter D109 (line 2446) confirm no Go-side filter, and the digest reports
  /v1/tasks byte-identical across drafts/raw/none perspectives with zero
  drafts.* rows live-in_progress — the "7 of 9" does not reproduce. The real
  in-fence levers are the single limit=1000 window (detail_data.go:67) over a
  6679-row corpus and the client-side in_progress gate (board.go:357). Reshape
  to a NOW-completeness ruling; do NOT route an api/ code hunt.

- **ttw19-bl-conn-state-flap: live_test.go pins the current label.** :107-108
  and :133 pin transport failures → "offline"; :483 pins pulse-must-not-clear-
  ConnOffline. No test case pins a *timeout*/deadline-exceeded string, so a new
  snapshotErrorLabel timeout branch can land without breaking the
  connection-refused case — but the stickiness change at handlePulse (live.go:128)
  will collide with live_test.go:483 and must update it.

- **ttw18 old-fork DoD is dead** (task description already carries the PREMISE
  CORRECTION): the measure/paint width fork is gone; only the readingWidth
  re-floor gap (program.go:1692 subtracts 3/4 with no re-floor vs composeAt floor
  at compose.go:234) and the two unguarded seams remain.

- **Hue split is settled (D113c)** — detail_render.go:65 + paper.go:36 stamp it;
  the wish's NoColor-vs-ANSI256 item is stale, no slice owed.
