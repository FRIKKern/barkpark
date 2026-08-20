# Re-derivation recipes — w44 stranded-fold recovery (wave 44 verify, 2026-08-03)

Settles the surveyor contradiction over
`.claude/worktrees/wf_50c6d61a-402-36`: does it hold a working
`pds-w43-liveview-residual-32-fold`, and does it still reproduce RESIDUAL 32 -> 0?

Answer: YES. The diff is UNCOMMITTED (+273/-34 on
`scripts/pds-elixir-receipt-census.exs`), which is exactly why one surveyor's
grep found it and the other's found nothing — see R3.

Captured non-destructively to local branch
`rescue/pds-w43-liveview-residual-32-fold` (commit `80b8b2da0`) via
`git stash create`, which does NOT touch the worktree.

## R1 — the diff exists, and the branch capture

```bash
cd /Volumes/SATECHI/github/barkpark/.claude/worktrees/wf_50c6d61a-402-36
git status --porcelain            # ' M scripts/pds-elixir-receipt-census.exs'
git diff --stat                   # 1 file changed, 273 insertions(+), 34 deletions(-)

# non-destructive capture (does not alter the dirty worktree):
SHA=$(git stash create)
git branch rescue/pds-w43-liveview-residual-32-fold "$SHA"
```

## R2 — the AFTER run: RESIDUAL 32 -> 0 reproduces

```bash
cd /Volumes/SATECHI/github/barkpark/.claude/worktrees/wf_50c6d61a-402-36
/usr/bin/time -p elixir scripts/pds-elixir-receipt-census.exs 2>&1 |
  grep -E 'unreachable_|reachable_unconditional|RESIDUAL residual_no_derivable|sum +[0-9]+ == population|deny-by-default versus|CENSUS OK'
```
Expect (rc=0):
```
unreachable_component_lifecycle   87 / 322
unreachable_no_hook_in_chain      10 / 322
reachable_unconditional          225 / 322
RESIDUAL residual_no_derivable_chain   0 / 322  <- UNDECIDABLE, NEVER FOLDED
sum                              322 == population 322
is 137 / 322 deny-by-default versus 225 / 322 on the halt key.
CENSUS OK
```
Measured on a LOADED host: real 88.47s / user 22.71s / sys 5.36s. The host was
running concurrent wave worktrees — quote the user figure, not the wall.

## R3 — the BEFORE run (the A/B), and why the two surveyors disagreed

The baseline is the worktree's own HEAD version of the file, run over the SAME
corpus (cwd = the worktree), so only the diff varies:

```bash
cd /Volumes/SATECHI/github/barkpark/.claude/worktrees/wf_50c6d61a-402-36
git show HEAD:scripts/pds-elixir-receipt-census.exs > /tmp/census-baseline.exs
elixir /tmp/census-baseline.exs 2>&1 | grep -E 'LIVEVIEW-REACH-CLOSES|CENSUS OK'
```
Expect: `unreachable_no_hook_in_chain 9, reachable_unconditional 194 · RESIDUAL 32
... DENIES 137 / 194`. So the fold moves 31 clauses into
`reachable_unconditional` and 1 into `unreachable_no_hook_in_chain`, and the
headline deny fraction gets WORSE: 137/194 = 70.6% -> 137/225 = 60.9%.

THE GREP TRAP that split the surveyors — the diff is uncommitted, so every
git-based grep misses it while a filesystem grep finds it:

```bash
cd /Volumes/SATECHI/github/barkpark
grep -rl 'plugin mount callsite sits OUTSIDE' .claude/worktrees/
#   -> .claude/worktrees/wf_50c6d61a-402-36/scripts/pds-elixir-receipt-census.exs  (EXACTLY ONE)

git grep -l 'plugin mount callsite sits OUTSIDE' worktree-wf_50c6d61a-402-36
#   -> (no output). git grep reads COMMITTED trees only.
```

## R4 — D639 obligation (a): the plugin fixture, and the live_session split

```bash
cd /Volumes/SATECHI/github/barkpark/.claude/worktrees/wf_50c6d61a-402-36
grep -n 'api/lib/barkpark/plugins/filler_plugin.ex' scripts/pds-elixir-receipt-census.exs
grep -n 'plugin_routes(scope:' scripts/pds-elixir-receipt-census.exs
git diff scripts/pds-elixir-receipt-census.exs | grep -E '^\+\s+name: "'
```
PRESENT. The fixture is written at line 6656 inside `write_corpus!/3`
(defined at 6468). The fixture router carries THREE `plugin_routes/1`
callsites — 1 INSIDE `live_session :selftest_plugin_session` (line 6549),
2 OUTSIDE any live_session (6552 `scope: :api`, 6557 `scope: :admin`) — and
the selftest asserts the split as a fraction:
`"1 / 3 plugin_routes/1 callsite(s) sit INSIDE a live_session"`.
Three new selftest cases: LIVEVIEW-PLUGIN-MOUNT-FOLDS,
LIVEVIEW-PLUGIN-MOUNT-NOT-CONSTANT, LIVEVIEW-PLUGIN-VAR-DECLINES.

## R5 — the selftest price, measured (NOT 210 s wall)

```bash
cd /Volumes/SATECHI/github/barkpark/.claude/worktrees/wf_50c6d61a-402-36
grep -oE 'corpus: :[a-z]+' scripts/pds-elixir-receipt-census.exs | sort | uniq -c
```
33 cases — 23 `:full`, 9 `:repo`, 2 `:tiny`, 1 `:repaired`. The 33 matches
PDS-D633's "33 port children" exactly. The 9 `:repo` cases each re-run the
census over the REAL 804-file tree.

The driver is `Enum.map(@selftest_cases, &run_selftest_case/4)` — SERIAL, and
every PASS/FAIL line is printed only AFTER the last case returns. So an
in-flight `--selftest` is INDISTINGUISHABLE FROM A HANG by output alone. A
`/usr/bin/time -p` wrapper at a 600 s timeout produced ZERO case lines and was
SIGTERM'd mid-`Enum.map`; that is not a failure, it is the shape.

```bash
# do NOT judge liveness from stdout; count the live children instead:
ps -eo etime,command | grep '[c]ase-'
```

PRICE CONSEQUENCE: D633's 210 s figure is LEAF USER CPU and is corroborated
(9 repo cases x 22.71 s user = 204 s). It is NOT a wall-clock budget. Wall on
this host exceeded 600 s and had not finished. A gate budget must be quoted in
the unit the gate enforces — wall — and that number is not yet in evidence.
