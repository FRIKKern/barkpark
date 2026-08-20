# D382's 10_000 is SHIPPED, and no prune glob can eat `serving-memory.json` (w23, 2026-08-08)

**VERDICT ON D382: NEITHER fabricated NOR unlanded. `@default_max_terminal_records 10_000` is on
`origin/main` at `api/lib/barkpark/sites/deploy_runner.ex:247`, landed by `9edfd15a6`
(2026-08-06 13:31:45 +0200 = #9727), and is present on all three unpushed dr-w21 branches too.
The survey's "does not exist anywhere in the tree" is a STALE-CHECKOUT artifact: the primary
checkout is 664 commits behind `origin/main` and its charter copy is 4,788 lines vs origin's 6,448
(zero `D382` hits locally).**

**VERDICT ON THE PRUNE HAZARD: `serving-memory.json` is UNREACHABLE by every sweep glob — but only
because it matches none of them, which also means it is UNBOUNDED. There is no third siting that is
both swept and safe.**

## Re-derivation

Constant, on origin and on all three unpushed branches (git grep dedups identical blobs across revs,
so check the two silent branches individually or you will read absence into a dedup):

```
git grep -n '@default_max_terminal_records' origin/main -- api/lib/barkpark/sites/deploy_runner.ex
git grep -n '@default_max_terminal_records' loop-epic/the-deploy-self-tests-stop-skipping-in-s-3 -- api/lib/barkpark/sites/deploy_runner.ex
git grep -n '@default_max_terminal_records' loop-epic/the-delivery-gauge-stops-being-dark-the--4 -- api/lib/barkpark/sites/deploy_runner.ex
git log -1 --format='%h %ci' -S'@default_max_terminal_records' origin/main -- api/lib/barkpark/sites/deploy_runner.ex
```

Staleness of the primary checkout (why the survey saw nothing):

```
git rev-list --count HEAD..origin/main            # 664
grep -c D382 .claude/workflows/bp-deploy-reliability-charter.md   # 0
git show origin/main:.claude/workflows/bp-deploy-reliability-charter.md | grep -c D382   # 3
```

## The prune proof (RUN, against origin/main's real source)

The local `_build` is 664 commits stale and has no terminal-record machinery at all, so the module
was compiled **from the origin blob** in-process rather than from the worktree:

```
mkdir -p /tmp/w23 && git show origin/main:api/lib/barkpark/sites/deploy_request.ex > /tmp/w23/deploy_request.ex
git show origin/main:api/lib/barkpark/sites/deploy_runner.ex > /tmp/w23/deploy_runner_originmain.ex   # blob ff5ade3da9
cd api && CC=clang MIX_ENV=test mix run --no-start /tmp/w23/load_and_prove.exs
```

`load_and_prove.exs` sets `Code.put_compiler_option(:ignore_module_conflict, true)`, compiles both
origin blobs, then seeds a temp dir with `serving-memory.json` + 40 manifests + 40 `.log` + 40
`.terminal.json` + two same-stem decoys, forces every cap to 0, starts `Barkpark.TaskSupervisor`
(`is_active/1` needs it), and calls the PUBLIC `DeployRunner.retention_sweep/0`.

```
CAPS IN FORCE: %{max_bytes: 0, max_logs: 0, max_age_ms: 0, max_terminal_records: 0}
FILES BEFORE=123 AFTER=41
logs remaining        = 0
terminal remaining    = 0
serving-memory.json          survived? true
serving-memory.terminal.json survived? false
serving-memory.log           survived? false
```

82 of 123 files were destroyed, so the pass is not vacuous, and the two decoys prove the globs are
live suffix matches rather than no-ops.

## Glob-by-glob

| Sweep | Selector (origin/main) | Reaches `serving-memory.json`? |
|---|---|---|
| `list_manifests/1` (`prune_run_state_dir/1`) | `String.ends_with?(name, ".manifest.json")`, then `read_manifest` → `nil` rejected | no |
| `build_log_entries/1` (`prune_build_logs/1`) | `String.ends_with?(name, ".log")` | no |
| `prune_terminal_records/2` | `String.ends_with?(name, ".terminal.json")`, count-only, no age term | no |
| `prune_run_state_dir/1` body removals | `manifest_path(dir, m.slug)`, `m.status_file`, `evict_build_log(m.log_file)`, `File.rm_rf(m.prebuilt_dir)`, `unlink_env(m)` — all five paths come from a manifest THIS module wrote | no, unless a manifest field names it |

Two residual hazards, both siting choices, not bugs:
1. `prebuilt_dir/1` = `Path.join(run_state_dir(), "#{slug}.prebuilt")` and eviction does
   `File.rm_rf` on it. A per-slug serving memory placed inside that tree dies with the slug.
2. Naming the crown's record `<x>.terminal.json` buys the 10_000 count cap; naming it anything else
   (including `serving-memory.json`) means **nothing ever deletes it**.

## Runway — the two caps are different populations

`@max_tracked_runs 32` bounds MANIFESTS, one per SLUG, and origin/main:2071 says so verbatim:
*"The manifest cap above counts SLUGS and has never fired on this box. The caps that actually bound a
1,000-builds/day dir count DEPLOYMENTS."* It therefore has **no time runway at all** — it is a
distinct-site bound. Converting it to hours is a category error, and the only honest conversions are
the counterfactuals:

| Cap | Population | Rate | Runway |
|---|---|---|---|
| `@default_max_terminal_records` 10_000 | terminal records (deployments) | 23.6 rec/h (D382 ledger) | 424 h = **17.7 days** — reproduces exactly |
| `@max_tracked_runs` 32 | manifests, per SLUG | n/a | unbounded in time; fires at 33 distinct slugs |
| `@max_tracked_runs` 32 *if* misused per-delivery | — | 3.88 commits/h on origin/main last 24 h | **8.2 h** |
| `@max_tracked_runs` 32 *if* misused per-deployment | — | 23.6/h | **1.4 h** |

Merge rate re-derivation (origin/main squash-merges, so merge COMMITS are 0 — count commits):

```
git log origin/main --since='1 days ago' --oneline | wc -l     # 93  → 3.88/h
git log origin/main --since='7 days ago' --oneline | wc -l     # 399 → 2.38/h
git log origin/main --merges --since='7 days ago' --oneline | wc -l   # 0 — do NOT use --merges here
```

## The assignment's own MUST-RUN was unrunnable

`api/test/barkpark/sites/deploy_runner_door_census_test.exs` **does not exist** — not in the
worktree, not on origin/main. `git ls-tree -r origin/main --name-only api/test/barkpark/sites/`
returns four files and that is not one of them; the only door-census test on main is
`api/test/barkpark/pds_door_census_test.exs`, a different epic's.
