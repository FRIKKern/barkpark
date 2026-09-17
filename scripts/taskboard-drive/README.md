<!-- doc-tier: human | canonical-for: taskboard-drive-harness | budget: 6000tok -->
# taskboard-drive — the tmux gesture harness for the Go task board

`drive.sh` builds the real `bp` binary from `./cmd/barkpark`, launches it in
**detached** tmux sessions at pinned geometry (130x40 wide, 70x24 narrow),
injects raw SGR-1006 mouse bytes per gesture, captures frames with
`capture-pane`, and asserts each gesture's visible delta. It is the only thing
in this repo that judges the board the way a person uses it: with a mouse, on a
painted terminal.

## THE LAW

**Before you push a change to `internal/taskboard/**` or to this harness, the
hermetic drive must pass from your own worktree — `DRIVE_MODE=hermetic bash
scripts/taskboard-drive/drive.sh` exits 0 with every assert green, and `bash
scripts/taskboard-drive/hermetic-proof.sh` prints its byte-identical PASS.**

That is the gate. It is one command plus its determinism proof, it needs no
token and no network, it takes ~25s including both Go builds, and CI's copy of
it is advisory (below) — so the local run is where the board is actually
defended.

```bash
DRIVE_MODE=hermetic bash scripts/taskboard-drive/drive.sh   # the 18-assert floor
bash scripts/taskboard-drive/hermetic-proof.sh              # two runs, empty diff
```

Requirements: `tmux >= 3.4` (detached `-x/-y` geometry does not stick before
3.4 — a 3.2a run judges columns the app never painted), Go per `go.mod`, and a
working C compiler. `drive.sh` pins `CC=/usr/bin/clang` for both builds; that
is a **Darwin** workaround for a shadowing `cc` on `PATH` and it is the harness's
one host-conditional line. On linux, make sure `/usr/bin/clang` exists (the CI
workflow installs it in a named guard step rather than letting the build die
inside the harness).

## The hermetic floor: 18 asserts

`DRIVE_MODE=hermetic` points the board at the committed fixture server
(`fixture/main.go` — a stdlib-only HTTP server serving a fixed corpus over the
board's LIVE-pinned surface: list + prime + a held-open SSE listen whose welcome
frame pins `● live`) and redirects `XDG_CONFIG_HOME` into the run's tempdir, so
the user's real config and preferences are neither read nor written. The floor
is 18 asserts:

| # | assert | what it defends |
|---|---|---|
| 1 | fixture serves the live-pinned surface | the mode is actually hermetic |
| 2-3 | wide 130x40 / narrow 70x24 detached geometry | tmux honours `-x/-y` |
| 4 | wide board painted task rows | the board booted |
| 5 | header pins the literal `● live` glyph | the ttw19 conn-flap class |
| 6 | header `↔` divider affordance located | the resize handle is painted |
| 7 | G7 divider hover bounds: exactly 2 contiguous cols respond | the gutter hit-test is `boardW .. boardW+paneGutter2` |
| 8 | G5 hover accent paints and restores exactly | no accent leak |
| 9 | G4 leaf descends on the FIRST click | there is no click-again-descend |
| 10 | esc after descend ascends cleanly | |
| 11 | G6 drag paints the `↔↔` grabbed affordance | |
| 12 | G6 divider follows the drag to the target col | |
| 13 | G6 release rewrote `taskboard-preferences.json` | persistence |
| 14 | G6 split PERSISTED across kill+relaunch | persistence is read back |
| 15 | narrow footer sheds the `M mouse` note | the shed ladder |
| 16 | narrow first-click descend reaches the reading frame | |
| 17 | narrow esc ascends back to the board | |
| 18 | `● live` STILL pinned at run end | the stream held across the G6 relaunch |

Evidence (normalized frames, located single rows, a machine-written
`report.md`) lands in `evidence-hermetic/`; the committed copy is the last
judged hermetic run.

### Byte determinism

`hermetic-proof.sh` runs the hermetic drive twice back to back, normalizes only
genuine per-run variance (ISO timestamps, the `tbdrive-<pid>` socket suffix,
mktemp paths) and diffs the transcripts **and** the reports. Assert order,
assert text, located columns and lines, row titles, ratio values and the
pass/fail counts must be byte-equal. Anything else is not hermetic and the
script exits 1 with the diff on stdout.

## Live vs hermetic — the coverage split

`DRIVE_MODE=live` (the default) runs the full matrix — **25 asserts** — against
the user's configured Barkpark server. The extra seven are the *churn-coupled*
ones, and they stay live-only on purpose (charter D118: a row's identity is its
rendered title, and only a real, reordering board makes selection identity mean
anything):

- **G1** wheel down x3 then up x3 returns the `▎` selection to the SAME task, by
  title;
- **G2** a single click selects the clicked leaf task in one gesture;
- **G3** clicking an epic root cycles its section partial → full → collapsed →
  full;
- **G4** the reading-pane heading shows the clicked task;
- **G8** with mouse released (`M`) a click is ignored, and after re-enable the
  same click lands;
- narrow wheel moves the selection to a different task.

The other split is the connection glyph. Live mode **masks** the conn header
(`offline|polling|live -> CONN`) because it genuinely flaps against a real
server; hermetic mode **drops the mask and asserts the literal `● live` glyph**
at boot and again at run end, because the fixture's held-open stream makes that
deterministic. The ttw19 conn-flap defect class therefore has a tripwire in
hermetic mode that live mode cannot have.

Live mode also rewrites the user's real `taskboard-preferences.json` during the
G6 drag (that IS the persistence proof; the original is backed up and restored
on exit), so two concurrent live runs race — run one at a time. Hermetic runs
have no such side effect.

## CI status: ADVISORY until promoted

`.github/workflows/taskboard-drive.yml` runs the hermetic drive plus
`hermetic-proof.sh` on `ubuntu-latest`, path-gated on `internal/taskboard/**`,
`scripts/taskboard-drive/**`, `cmd/barkpark/**` and the workflow file itself.

The job carries `continue-on-error: true` and a name that is in no required
set, so **it cannot stop a merge**. Determinism is proven on Darwin/arm64 and
has never been observed on a GitHub linux runner, where CPU contention moves the
board's hover settle timer. Promotion — dropping `continue-on-error` and adding
the check name to `.github/required-checks.json` — is the lead's call after the
job has gone green on several unrelated PRs, not after one.

The workflow's `tmux >= 3.4` and `/usr/bin/clang` guards are LOUD: each fails
the job with a named reason rather than skipping, because a skipped drive and a
passing drive are indistinguishable on a PR page.

### Known red on main (2026-09-17)

As of `174f97664` the hermetic floor runs **17 pass / 1 fail**, stably, three
runs for three: `G7 divider hover bounds: responding cols {84 85 86} (want
exactly 2)`. The guarded property is HEALTHY — `wideMouseMotion` sets
`wideDividerHover` for `cx >= boardW && cx < boardW+paneGutter2`, exactly two
columns, and the captured frames carry the hover accent SGR `38;2;161;161;170`
on cols 84 and 85 **only**. The probe is what is wrong: it compares the whole
styled header row, and that row ends with the right pane's preview heading,
which reverts from the hovered board row's title to the cursor's title the
moment the pointer leaves the board. Col 86 therefore "responds" with no accent
at all: its capture carries no accent SGR and differs from the off-gutter
baseline only in that heading (`Harbor lights epic` vs `Mulch the seedling
beds`). The judged run in `evidence-hermetic/` has no
`g5-hover-header-col86.txt` at all — the file is written only for a column that
responds, and in August col 86 did not. The same red reproduces byte-for-byte on `ubuntu-latest` (PR #18824's first
advisory run: `17 pass, 1 fail`, same assert text, same columns), so it is
neither a Darwin artifact nor scheduler latency. It is a churn-coupled assert — the one thing this harness's own evidence law
forbids — and it needs its comparison scoped to the divider cells.
