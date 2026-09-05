# spd-/cchi- triage brief — READ-ONLY

You classify open, 0-criteria-met rows of two Barkpark epics in /Volumes/SATECHI/github/barkpark.

## HARD RULES
- READ-ONLY. Do NOT stamp, close, claim, build, compile, edit any file, or contact any *.barkpark.cloud
  server. Everything you need about the rows is in your shard file. ~25 builder agents hold api/, cloud/,
  internal/, js/, web/, scripts/, tooling/, docs/, .github/ and the test trees — never write there.
- Work from **origin/main** only (already fetched). The working tree is stale and other agents are editing it.
  `git grep <pat> origin/main -- <path>` and `git log -S "<string>" --oneline origin/main -- <path>`.
- Do NOT switch branches.

## SELF-TEST BEFORE TRUSTING ANY GREP
Run your instrument on a known positive AND an impossible control, e.g.
  git grep -c "defmodule" origin/main -- api/lib/barkpark.ex      # must be 1
  git grep -c "ZQXW_IMPOSSIBLE_44117" origin/main -- .            # must be rc 1, no output
A grep that cannot fail is not evidence. Re-self-test if you change instrument shape.

## MEASURED SHELL TRAPS — these produced wrong numbers today
- `--` ends option parsing: `grep -rln -- "$p" --include='*.sh'` makes the filter INERT (213 counted vs 25 real).
  Prefer `git grep` with a quoted pathspec after `--`.
- zsh does NOT word-split unquoted vars and EATS unquoted globs. Quote every pattern and pathspec.
- A truncated pipe (`| head -40`) makes a PRESENT symbol read ABSENT. Do not pipe a decisive grep to head.
- Capture `out=$(cmd 2>&1); rc=$?` — never read rc through a pipe (you get the LAST command's status).
- cwd RESETS between Bash calls. Use absolute paths.

## VERDICTS — exactly one per row
- ALREADY-DONE — the capability/fix EXISTS on origin/main. Evidence REQUIRED: symbol+file:line on origin/main
  AND the landing commit from `git log -S`. NEVER argue from ancestry: after a squash merge the PR head is
  ALWAYS a non-ancestor, so "the sha isn't on main" is the EXPECTED reading for a correctly merged PR.
  **EXEMPLAR TRAP**: a PR can DEMONSTRATE a row's pattern without implementing THAT ROW's target. Check the
  row's OWN named file/symbol, not merely that a related PR merged.
- SUPERSEDED — a NAMED successor row/PR/decision replaces it (name it).
- REFUTED — a POSITIVE contradiction of the row's premise (state the contradicting fact).
  **spd- CAUTION**: the governing law of the Studio space-priority desk is THE SCOPED COMPOUND SELECTOR IS LAW.
  A fix that drops the scoping is WRONG even when it looks simpler. Do NOT call a row REFUTED merely because a
  broader/unscoped selector would also work.
- STRANDED-PREDECESSOR — waits on a predecessor slice/PR that never landed and is now gone (name it).
- BLOCKED-HUMAN — needs a live prod probe or a human act: ssh to guerrilla/cloud boxes, prod psql, a live
  gh workflow run, an operator/owner decision, a credential, cutting a release. NAME the box/credential/repo/
  decision, AND check whether that gate has ALREADY CLEARED (four rows today were parked on open gates, one for
  four weeks). Say what ONE act would unblock.
- REAL-WORK — a genuine, still-valid, buildable task.
- DUPLICATE — same work as another OPEN row (name it). FLAG ONLY, never recommend cancelling. A pair is a
  duplicate ONLY IF ONE PATCH WOULD SATISFY BOTH. If accepting one would RED the other, that is a SPEC
  CONFLICT — say so explicitly instead.

## CHAINS — this is where the value is
If 2+ of your rows share one defect, one file, or an ordering dependency, add CHAIN-CANDIDATE lines naming them
and stating what ONE act collapses. **Trap**: `-followup-` and `-fu-` rows share their parent slice's prefix, so
prefix-matching INFLATES a chain (counts went 16->30->31->54 while the real backlog shrank). Group by the DEFECT
and the FILE, never by the id prefix.

## OUTPUT — required
Write EXACTLY one TSV line per row to YOUR output file:
  doc_id <TAB> VERDICT <TAB> detail <TAB> one-measurement
- full ids, never truncated. detail = symbol+line + landing commit (ALREADY-DONE) / successor (SUPERSEDED) /
  contradiction (REFUTED) / predecessor (STRANDED) / the needed human act + whether the gate is already open
  (BLOCKED-HUMAN) / one-line scope (REAL-WORK) / twin id + "one patch satisfies both" or "SPEC CONFLICT" (DUPLICATE).
- one-measurement = the single command+result anchoring the verdict (short, exact).
Then CHAIN-CANDIDATE lines in the same 4-column shape.
Finally reply with ONLY a 6-line summary: bucket counts, chains found, anything surprising.
