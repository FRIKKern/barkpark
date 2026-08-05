# SALVAGE — pds_hetzner_offline_door_test.exs (wave 44 slice `pds-w44-hetzner-offline-door`, never landed)

Recorded by the wave-47 rescue-salvage verifier, 2026-08-04. NOT committed by me; Decide commits this file.

## Why this row exists

`find /Volumes/SATECHI/github/barkpark -name 'pds_hetzner_offline_door_test.exs'` returns exactly ONE path, and it is
untracked inside a worktree: `.claude/worktrees/wf_42737b38-0d2-22/api/test/barkpark/pds_hetzner_offline_door_test.exs`
(6703 bytes, sha256 4444bff7cabc81a20163c8e0781cb06d06df3d02692a0d4f158bcd559c228800, mtime 2026-08-03 17:14).
`git ls-tree -r --name-only origin/main | grep -c hetzner_offline` = 0 and `git log --all --diff-filter=A` for the
basename is EMPTY: no commit on any branch has ever contained it. One `git worktree prune` and it is gone with no
record anywhere. This file IS the record.

It is preserved here as a fenced verbatim body rather than as a live `api/test/**/*.exs` because dropping the `.exs`
into the tree is not inert: proven below, it changes `scripts/pds-door-census.sh`'s classification of the hetzner
instrument (LEG-A `no` -> `yes`) and would be collected by `mix test`. Restoring it is `sed`-out of the fence.

## Re-derivation recipe

    git -C /Volumes/SATECHI/github/barkpark ls-tree -r --name-only origin/main | grep -c hetzner_offline    # 0
    shasum -a 256 .claude/worktrees/wf_42737b38-0d2-22/api/test/barkpark/pds_hetzner_offline_door_test.exs
    EX=$(mktemp -d); git archive origin/main | tar -x -C "$EX"; cd "$EX"
    bash scripts/pds-live-hetzner-placement-group.sh --selftest-offline; echo "rc=$?"        # rc=0, verdict prints
    printf 'scripts/pds-live-hetzner-placement-group.sh\n' | bash scripts/elixir-path-escape-check.sh --match test  # false
    printf 'internal/cli/testdata/pds_live_hetzner_firewall_404.json\n' | bash scripts/elixir-path-escape-check.sh --match test  # false
    printf 'scripts/pds-door-census.sh\n' | bash scripts/elixir-path-escape-check.sh --match test            # true (control)
    bash scripts/pds-door-census.sh --check | grep -E 'THROUGH a required gate|ERRORS'       # 4 of 20 / 0
    cp <this file's fenced body> api/test/barkpark/pds_hetzner_offline_door_test.exs
    bash scripts/pds-door-census.sh --check | grep hetzner   # row flips to LEG-A yes, COUNTS block byte-identical

## What its four arms pin (all still hold at origin/main 49345a98c)

`setup_all` flunks (never skips) if the instrument file is missing or `bash` is absent — D26 discipline. The one
test shells `bash scripts/pds-live-hetzner-placement-group.sh --selftest-offline` from the repo root and asserts:

  1. `rc == 0`  — the credential-free arm exits clean with no credential (`--selftest` refuses at rc=3).
  2. `~r/PASS\s+the credential-free arm holds/`  — the arm's own VERDICT PROSE, not the exit code alone.
  3. `~r/0 hetzner\/hcloud variables/`  — the scrub receipt; without it the "offline" label is unearned.
  4. `~r/the deposit fail-open reproduced and closed/`  — `deposit_or_refuse/4`, the wave-32 fail-open.

All four strings are present verbatim at `scripts/pds-live-hetzner-placement-group.sh:1300` and `:1491` on
origin/main 49345a98c, and a live run at load1 8.54 printed all of them at rc=0. THE ARMS ARE REUSABLE AS WRITTEN.

## Three defects in the salvaged artifact — do NOT paste it forward unedited

1. ITS MODULEDOC ASSERTS A CHANGE THAT NEVER LANDED AND THAT THE SLICE LATER REFUSED. Lines 33-37 claim
   `internal/cli/testdata/**` "had to be added to ELIXIR_TEST_ONLY_PATHS alongside the instrument itself" and that
   before that entry the escape check "answered FALSE for a fixture path". At origin/main NEITHER entry exists and
   BOTH paths still answer `false`. Task `pds-w44-hetzner-offline-door` criterion [7] explicitly REFUSES the
   testdata entry as unenforceable and routes the real hole to `.github/workflows/go-tests.yml`
   (filed: `pds-w46-bl-go-tests-testdata-carveout`). The rider's own "BOTH LEGS OR NEITHER" comment at :62-74 is
   therefore currently UNSATISFIED: landing the file without the one permitted `ELIXIR_TEST_ONLY_PATHS` entry
   (criterion [6]: exactly `scripts/pds-live-hetzner-placement-group.sh`) ships an ungated door.

2. ITS PRICE PROSE IS A LOADED-HOST FIGURE AND DOES NOT REPRODUCE. Lines 14-21 stamp CPU 2.98-3.01 s with
   "`sys` EQUALS `user`" at load1 38.70-39.42. Three quiet-host trials at load1 8.54 -> 12.05 on the same
   byte-identical arm: 0.84+0.64=1.48 s (wall 2.347), 1.01+1.00=2.01 s (wall 2.911), 1.07+1.12=2.19 s (wall 3.033).
   The lowest is 2.0x below the moduledoc's own figure and its sys/user ratio is 0.76, not 1.0. The moduledoc's
   claimed "1.76x span" across three loads widens to 2.56x (1.48 / 3.79). Its own conclusion — a CPU figure is
   quotable only against its load stamp — is right; its numbers are not quotable.

3. IT PRESUMES AN INSTRUMENT THAT DOES NOT EXIST. Criterion [10] requires the price row be taken via `--measure`.
   `grep -c -- '--measure' scripts/pds-door-census.sh` = 0 on origin/main; the census has four modes
   (`--check|--selftest|--list-refs|--help`). The slice cannot complete its price criterion at this base.

## The silent-census finding this salvage produced

Planting the file into a clean origin/main export and re-running `--check`: the hetzner row moves LEG-A `no` -> `yes`
(and `--list-refs` gains `LEGA-BOUND-EXEC api/test/barkpark/pds_hetzner_offline_door_test.exs:75`), while its
DISPOSITION stays the stale `ENVIRONMENT ... --selftest rc=3 "needs one WORKING credential"` — evidence about a
DIFFERENT arm, which is precisely the defect this rider was written to expose. `diff` of the COUNTS block before vs
after is EMPTY and rc stays 0. A new door that changes the census's picture of the world moves no printed count:
the same lie-by-silence class as the price-orphan hole, one column over.

## VERBATIM BODY (6703 bytes, sha256 4444bff7...c228800) — restore with `sed -n '/^```elixir$/,/^```$/p'`

```elixir
defmodule Barkpark.PdsHetznerOfflineDoorTest do
  @moduledoc """
  `scripts/pds-live-hetzner-placement-group.sh --selftest-offline` is the epic's
  CREDENTIAL-FREE arm (the script's own header, :13 and :964, calls it "the
  CI-able gate"). Until this case it was gated by nothing, and the door census
  disposed the whole instrument ENVIRONMENT on evidence taken from a DIFFERENT
  arm — `--selftest` rc=3 "needs one WORKING credential". That evidence is true
  about `--selftest` and says nothing about `--selftest-offline`, which exits 0
  with zero credentials.

  ## The blind spot this case does NOT close

  Every price ever taken on this door is a loaded 10-core Apple-Silicon mac.
  Measured here at CPU=1.49+1.49=2.98s / 1.50+1.51=3.01s / 1.51+1.48=2.99s
  (three runs, load1 38.70 -> 39.42) — `sys` EQUALS `user` here, so a user-only
  meter understates this door 2.0x, and wall spanned 6.59-7.03 s at essentially
  constant load. PDS-D648's stronger claim that `sys` EXCEEDS `user` on THIS
  door (it cites 2.00-2.07 vs 1.75-1.83) does not reproduce at load1 39. Nor is
  CPU load-independent the way D648 assumes: the same byte-identical arm has now
  metered 2.15 s, 2.98 s and 3.79 s of CPU at three different host loads — a
  1.76x span. A CPU figure is quotable only against its own load stamp. No pds door has ever executed on a
  foreign runner; the census row this case unlocks is labelled LOCAL for exactly
  that reason and the door's own first CI run should overwrite it.

  ## What this door assumes of its runner, and the FIFTH file the slice needs

  `bash`, `python3` and `curl` (the arm has 10 call sites of each of the latter
  two), plus the 12 committed `internal/cli/testdata/pds_live_hetzner_*.json`
  fixtures. A ONE-BYTE edit to any of those fixtures REDS this door — proven by
  run: changing `not found` to `NOT FOUND` in
  `pds_live_hetzner_firewall_404.json` makes the manifest-reproduction arm print
  `FAIL  the committed manifest is NOT what the emitter produces` and the whole
  arm exit 1. That is by design (the manifest is re-emitted and diffed, never
  asserted) and it is exactly why `internal/cli/testdata/**` had to be added to
  `ELIXIR_TEST_ONLY_PATHS` alongside the instrument itself: before that entry,
  `elixir-path-escape-check.sh --match test` answered FALSE for a fixture path,
  so a fixture-only PR would have red this door with the Elixir gate SKIPPED.

  No CI budget is projected from the numbers above. Every one of them is a
  loaded local mac; the door's own first run on `ubuntu-latest` is what decides
  the real budget, and it should overwrite the census row rather than confirm it.

  ## Why the assertion is on the arm's own VERDICT PROSE, not on rc alone

  The epic's law: NO BARKPARK VERB MAY REPORT SUCCESS ON AN EXIT CODE ALONE. The
  offline arm ends with `PASS  the credential-free arm holds: …`. A `set -e`
  script that dies before reaching its verdict exits non-zero, but a script
  edited to `exit 0` early exits ZERO having proven nothing — so rc is asserted
  AND the verdict line is asserted, and the mutation-block count is read out of
  the verdict rather than pinned as a separate number that could drift.

  `async: false`: the case shells a subprocess that re-execs itself with a
  scrubbed environment, writes fixture trees into temp dirs and burns ~3 s of
  CPU across ~hundreds of subprocesses.
  """
  use ExUnit.Case, async: false

  # Measured 2.98-3.01 s CPU locally but wall spanned 6.6-7.0 s under load, and
  # the arm re-execs itself. Generous headroom is cheaper than a runner flake.
  @moduletag timeout: 300_000

  # The "../../../scripts/…" STRING LITERAL is load-bearing, not cosmetic, and
  # its SHAPE is load-bearing too. `scripts/pds-door-census.sh`'s leg A accepts
  # a literal only when it is ATTRIBUTE-BOUND — the awk match is
  # `^@<name><space>"` — so the inline `@x Path.expand("…", __DIR__)` form is
  # NOT attribute-bound and classifies as an ERROR, not as a door. The bare
  # assignment here plus the `Path.expand(@instrument_rel, __DIR__)` hop in
  # `setup_all` is the shape every real door already uses.
  #
  # It is also what `scripts/elixir-path-escape-check.sh` resolves to build the
  # path set `.github/workflows/elixir.yml` dispatches on: without it AND its
  # matching `ELIXIR_TEST_ONLY_PATHS` entry, a PR touching ONLY the instrument
  # would compute `changes.outputs.test == 'false'` and mix-test would be
  # LEGITIMATELY skipped on the very PR that changed it. BOTH LEGS OR NEITHER.
  @instrument_rel "../../../scripts/pds-live-hetzner-placement-group.sh"

  setup_all do
    instrument = Path.expand(@instrument_rel, __DIR__)

    unless File.regular?(instrument) do
      flunk(
        "the gate is pointed at nothing: #{instrument} does not exist. " <>
          "Do not skip this test — a skip here is D26 (green fixtures executed by nothing)."
      )
    end

    bash =
      System.find_executable("bash") ||
        flunk(
          "the gate is pointed at nothing: no `bash` executable on PATH, so the hetzner " <>
            "credential-free arm cannot be run. Failing loud rather than skipping."
        )

    {:ok, instrument: instrument, bash: bash, root: Path.expand("../../..", __DIR__)}
  end

  test "the hetzner CREDENTIAL-FREE arm is GREEN and says so in its own words", ctx do
    {out, rc} =
      System.cmd(ctx.bash, [ctx.instrument, "--selftest-offline"],
        cd: ctx.root,
        stderr_to_stdout: true
      )

    assert rc == 0,
           "expected `bash #{@instrument_rel} --selftest-offline` to exit 0 with NO credential " <>
             "(that is the whole point of the offline arm — `--selftest` refuses at exit 3), " <>
             "got #{rc}.\n#{out}"

    assert out =~ ~r/PASS\s+the credential-free arm holds/,
           "the arm exited 0 without printing its own verdict — an exit code alone is not a " <>
             "receipt (the epic's law since wave 22). Output:\n#{out}"

    assert out =~ ~r/0 hetzner\/hcloud variables/,
           "the verdict no longer claims a scrubbed environment. The offline arm's credential-" <>
             "freeness is the property this door sells; if the count is gone, the door is a " <>
             "credential-gated green wearing an offline label.\n#{out}"

    assert out =~ ~r/the deposit fail-open reproduced and closed/,
           "the verdict dropped the deposit clause. `deposit_or_refuse/4` is the fixed " <>
             "fail-open (wave 32 deposited an HTML page as a JSON 404 fixture AT EXIT 0); a " <>
             "green arm that no longer exercises it is a green that costs nothing to " <>
             "produce.\n#{out}"
  end
end
```
