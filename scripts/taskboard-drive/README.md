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
token and no network, and CI's copy of it is advisory (below) — so the local run
is still where the board is actually defended.

```bash
DRIVE_MODE=hermetic bash scripts/taskboard-drive/drive.sh   # the 25-assert hermetic floor
bash scripts/taskboard-drive/hermetic-proof.sh              # two runs, three empty diffs
```

Measured 2026-09-17 on Darwin/arm64 (tmux 3.4, warm Go build cache): the drive
takes ~30s including both Go builds, `hermetic-proof.sh` ~60s because it runs
the drive twice. On a GitHub `ubuntu-24.04` runner the drive step took ~60s and
the proof step ~45s.

Requirements: `tmux >= 3.4` (detached `-x/-y` geometry does not stick before
3.4 — a 3.2a run judges columns the app never painted), Go per `go.mod`, and a
working C compiler. `drive.sh` pins `CC=/usr/bin/clang` for both builds; that
is a **Darwin** workaround for a shadowing `cc` on `PATH` and it is the harness's
one host-conditional line. On linux, make sure `/usr/bin/clang` exists (the CI
workflow installs it in a named guard step rather than letting the build die
inside the harness).

### `CI` is what decides whether the styled asserts can see anything

`termenv.go:28` — `isTTY()` returns false the moment `CI` is non-empty, **before
`TERM` or `COLORTERM` is read at all** — so `ColorProfile()` degrades to `Ascii`,
the board paints with zero SGR, and every style-keyed assert here (G5 hover
accent, G7 divider bounds) compares two unstyled rows and reports "no response"
rather than "I could not see". That is not a hypothetical: it is exactly what
`ubuntu-latest` did to PR #18858's first advisory run.

**The harness handles this itself** — `drive.sh` launches every `new-session`
through `BP_ENV="env -u CI TERM=screen-256color COLORTERM=truecolor
TERM_PROGRAM=tmux"`, so the board process never sees `CI` no matter what the
caller's shell holds. MEASURED 2026-09-17: `CI=true DRIVE_MODE=hermetic bash
scripts/taskboard-drive/drive.sh` → `25 pass, 0 fail`, identical to the run
without it. So `env -u CI` in front of your own invocation is harmless but
**not required**, and the CI workflow correctly does not need it either.

The arm that keeps this honest is assert 13: before the G7 hover probe runs,
the harness asserts that the captured header row carries SGR at all. An
unstyled pane now fails loudly with a named reason instead of quietly reporting
a healthy gutter as dead.

## The 25-assert hermetic floor

`DRIVE_MODE=hermetic` points the board at the committed fixture server
(`fixture/main.go` — a stdlib-only HTTP server serving a fixed **32-doc** corpus
over the board's LIVE-pinned surface: list + prime + a held-open SSE listen whose
welcome frame pins `● live`) and redirects `XDG_CONFIG_HOME` into the run's
tempdir, so the user's real config and preferences are neither read nor written.
The corpus size is not decoration: `corpusFloorDocs = 32` is the floor at which
the wide spine measurably overflows at 130x40, and the fixture **refuses to
serve** below it, because under that floor the overflow-marker asserts stop
measuring anything. The floor is 25 asserts:

| # | assert | what it defends |
|---|---|---|
| 1 | fixture serves the live-pinned surface | the mode is actually hermetic |
| 2-3 | wide 130x40 / narrow 70x24 detached geometry | tmux honours `-x/-y` |
| 4 | wide board painted task rows | the board booted |
| 5 | header pins the literal `● live` glyph | the ttw19 conn-flap class |
| 6 | G9 the wide spine OVERFLOWS: a counted `↓ N more below` is painted | the marker asserts below have a subject |
| 7 | G9 no counted `↑ N more above` at boot | markers track the window, they are not unconditional chrome |
| 8 | G10 a click on the counted `↓` marker steps the cursor EXACTLY one row — the same row one `j` selects | charter decision 119 `wideBoardMarkerAt` → `moveCursor` |
| 9 | G9 both counted markers paint once the window has scrolled off the top | |
| 10 | G10b a click on the counted `↑` marker steps EXACTLY one row back | |
| 11 | G10 the board is restored to its boot cursor row | the asserts that follow see the baseline board |
| 12 | header `↔` divider affordance located | the resize handle is painted |
| 13 | **G7 precondition**: the captured header row carries SGR | an unstyled pane is UNMEASURABLE, not merely failing |
| 14 | G7 divider hover bounds: exactly 2 contiguous cols light the divider cell, and their neighbours do not | the gutter hit-test is `boardW .. boardW+paneGutter2` |
| 15 | G5 hover accent paints and restores exactly | no accent leak |
| 16 | G4 leaf descends on the FIRST click | there is no click-again-descend |
| 17 | esc after descend ascends cleanly | |
| 18 | G6 drag paints the `↔↔` grabbed affordance | |
| 19 | G6 divider follows the drag to the target col | |
| 20 | G6 release rewrote `taskboard-preferences.json` | persistence |
| 21 | G6 split PERSISTED across kill+relaunch | persistence is read back |
| 22 | narrow footer sheds the `M mouse` note | the shed ladder |
| 23 | narrow first-click descend reaches the reading frame | |
| 24 | narrow esc ascends back to the board | |
| 25 | `● live` STILL pinned at run end | the stream held across the G6 relaunch |

Evidence (normalized frames, located single rows, a machine-written
`report.md`) lands in `evidence-hermetic/`; the committed copy is the last
judged hermetic run.

### The floor number has an arm — do not hand-edit it

The number above used to be prose, and prose rots: it said **18** for the four
merges that carried it to 25. It is now checked mechanically. `drive.sh` in
hermetic mode reads every occurrence of the literal phrase `N-assert hermetic
floor` out of THIS file and compares it against `PASS + FAIL` from the run it
just did, and calls `bad` — reddening the run, and with it the local law and the
advisory CI job — when:

* the phrase appears fewer than **twice** (deleting the number must not read as
  "no drift");
* two occurrences disagree with **each other**;
* the stated floor disagrees with what the run **measured**.

It is deliberately not counted as an assert of its own, so the floor it guards
stays the count of board asserts in the table above and cannot chase its own
tail. **So: add an assert, run the drive, and let its red tell you both places
to correct** — the two `N-assert hermetic floor` phrases and the table row.

### Byte determinism

`hermetic-proof.sh` runs the hermetic drive twice back to back, normalizes only
genuine per-run variance (ISO timestamps, the `tbdrive-<pid>` socket suffix,
mktemp paths) and diffs **three** things — the transcripts, the reports, and
every committed evidence `.txt` (as directories, so a file one run stops writing
is a difference too). Assert order, assert text, located columns and lines, row
titles, ratio values and the pass/fail counts must be byte-equal. Anything else
is not hermetic and the script exits 1 with the diff on stdout.

The evidence arm is not theoretical: it was added (charter decision 130) after a
row save that landed on a CLAIMED task captured the live braille spinner raw, so
two runs differed by one glyph (`⠧` vs `⠦`) in an evidence file while the
transcript and the report stayed byte-identical and the proof said PASS.

## Live vs hermetic — the coverage split

`DRIVE_MODE=live` (the default) runs the board against the user's configured
Barkpark server. The two modes are **not** subset and superset — each asserts
things the other structurally cannot:

* **hermetic-only (9 asserts)**: the fixture-surface check, `● live` at boot and
  at run end (the fixture's held-open stream makes the glyph deterministic; live
  mode has to MASK the conn header, `offline|polling|live -> CONN`, because it
  genuinely flaps against a real server), and the six charter-decision-119
  overflow-marker asserts, which need a corpus pinned to overflow the spine.
* **shared (16 asserts)**: everything else in the table above.
* **live-only (9-10 asserts across 6 gesture families)**: the *churn-coupled*
  ones, live-only on purpose (charter decision 118: a row's identity is its
  rendered title, and only a real, reordering board makes selection identity
  mean anything) —
  **G1** wheel down x3 then up x3 returns the `▎` selection to the SAME task, by
  title; **G2** a single click selects the clicked leaf task in one gesture;
  **G3** clicking an epic root cycles its section (2 or 3 asserts, depending on
  whether the root starts full or partial — which is why live has no fixed
  floor); **G4** the reading-pane heading shows the clicked task; **G8** with
  mouse released (`M`) a click is ignored, and after re-enable the same click
  lands; and narrow wheel moves the selection to a different task.

So the ttw19 conn-flap defect class has a tripwire in hermetic mode that live
mode cannot have, and the selection-identity class has one in live mode that
hermetic cannot. **The live total is derived from the source, not measured here**
— it was not run for this pass, because live mode rewrites the user's real
`taskboard-preferences.json` during the G6 drag (that IS the persistence proof;
the original is backed up and restored on exit), so two concurrent live runs
race — run one at a time. Hermetic runs have no such side effect.

## CI status: ADVISORY, and what promotion would take

`.github/workflows/taskboard-drive.yml` runs the hermetic drive plus
`hermetic-proof.sh` on `ubuntu-latest`, path-gated on `internal/taskboard/**`,
`scripts/taskboard-drive/**`, `cmd/barkpark/**` and the workflow file itself.

The job carries `continue-on-error: true` and a name (`taskboard hermetic drive
(ADVISORY)`) that is in no required set, so **it cannot stop a merge**.

**Determinism on linux is no longer unobserved.** MEASURED 2026-09-17 at the job
level (not the run conclusion — a `continue-on-error` job reads `success` on the
RUN while the JOB failed):

| run | head | image | drive | proof |
|---|---|---|---|---|
| `35183079841` | PR #18858 head | ubuntu-24.04 | 25 pass, 0 fail, divider cols `(84 85)` | `hermetic-proof: PASS` |
| `35183546624` | `main` after that merge | ubuntu-24.04 | 25 pass, 0 fail, divider cols `(84 85)` | `hermetic-proof: PASS` |

Same assert count, same located columns and same PASS as Darwin/arm64. Every
job run before those two was a `failure`, on the `G7 divider hover bounds` probe
that #18858 replaced.

**Promotion is the lead's call, and the bar this workflow set for itself is not
met yet.** The header of `taskboard-drive.yml` says "a handful of unrelated
PRs"; there are two green job runs, and they are not unrelated — one is the fix
and the other is main immediately after it. What promotion would take, in order:

1. **More green runs, on PRs that are not about this harness.** The
   path filter means only PRs touching `internal/taskboard/**`,
   `scripts/taskboard-drive/**` or `cmd/barkpark/**` even render the check, so
   "unrelated" means unrelated task-board work, and the sample accumulates
   slowly. Read JOB conclusions, never run conclusions.
2. **Drop `continue-on-error: true`** from the `hermetic-drive` job and rename
   it without the `(ADVISORY)` suffix.
3. **Register the new name in `.github/required-checks.json`.** Note that the
   path filter makes it a context that does not render on most PRs — a required
   context that is absent on a head is its own class of merge deadlock, so this
   step needs the same treatment every other path-filtered required name got.
4. **Edit branch protection** to require the new name. **OWNER-ONLY** — no agent
   does this, under any round brief.

Until steps 2-4 happen together, a red here is a signal to read, never a merge
blocker.

The workflow's `tmux >= 3.4` and `/usr/bin/clang` guards are LOUD: each fails
the job with a named reason rather than skipping, because a skipped drive and a
passing drive are indistinguishable on a PR page.

### Historical — the G7 red of 2026-09-17 is FIXED

Between the corpus enrichment and #18858 the hermetic floor ran **17 pass / 1
fail**, stably, on Darwin AND on `ubuntu-latest`: `G7 divider hover bounds:
responding cols {84 85 86} (want exactly 2)`. The guarded property was always
healthy — `wideMouseMotion` sets `wideDividerHover` for
`cx >= boardW && cx < boardW+paneGutter2`, exactly two columns. **The probe was
what was wrong**: it compared the whole styled header row, and that row ends
with the right pane's preview heading, which reverts to the cursor's title the
moment the pointer leaves the board — so col 86 "responded" carrying no hover
accent at all. #18858 rescoped the comparison to the divider cell and added the
SGR precondition (assert 13) that would have named an unstyled pane instead of
letting it read as a dead gutter. Assert 14 now passes on both platforms. This
note is kept because the failure mode — a churn-coupled comparison inside a
harness whose own evidence law forbids one — is worth recognising again.
