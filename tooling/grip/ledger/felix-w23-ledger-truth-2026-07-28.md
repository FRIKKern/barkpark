# Re-derivation recipe — Felix W23 ledger truth + the live Sobelow finding set

Ran at `origin/main` = `ad3b6d56c02341f6fdd00f2345960dadcb411ab8` (2026-07-28).
Everything below re-derives from scratch; nothing is quoted from a prior wave.

## 1. Squash-merge is why four rows read as "unmerged"

```sh
gh pr view 5975 --json state,mergedAt,mergeCommit   # MERGED 2026-07-23T10:42:55Z 0302e2e1b
gh pr view 5976 --json state,mergedAt,mergeCommit   # MERGED 2026-07-23T10:42:24Z 454af95ad
gh pr view 5949 --json state,mergedAt,mergeCommit   # MERGED 2026-07-23T10:48:33Z be5eaa649
gh pr view 5950 --json state,mergedAt,mergeCommit   # MERGED 2026-07-23T10:42:58Z 4172127d8

for c in 0302e2e1b 454af95ad be5eaa649 4172127d8; do
  git merge-base --is-ancestor $c origin/main && echo "$c ON_MAIN"
done
```

All four merge commits are ancestors of main. The `loop-epic/*` **branch tips** are
NOT — that is squash-merge mechanics, not unmerged work.

## 2. Finding the stale-open rows the assignment did not name

The assignment named 2. A body-search over merged PRs found 2 more, both P1:

```sh
for t in task-felix-w21-codex-buffer-cap task-felix-w21-deployrunner-cmd-deadlines; do
  gh pr list --search "$t in:body" --state merged --json number,mergedAt --limit 5
done
# 5949 @ 2026-07-23T10:48:33Z ; 5950 @ 2026-07-23T10:42:58Z
```

Full sweep of every open Felix child:

```sh
bp task ls --all -o json > /tmp/all.json
python3 -c "import json;rows=json.load(open('/tmp/all.json'))['tasks'];\
k=[r for r in rows if r.get('parent_id')=='task-96a908af98698118'];\
print(len(k));\
[print(r['lifecycle_status'],r['doc_id']) for r in k if r['lifecycle_status']=='open']"
```

## 3. The close mechanism — `holder_override` is a silent no-op

`bp task stamp` on a reaped claim is REFUSED:

```sh
bp task stamp task-felix-w21-bl-claudechat-buffer-parity \
  epic-builder-claude-chat-transport-buffer-cap-data-ha 7 --criterion 2 ... --yes
# bp: not_in_progress:open
```

So the only path is a close with `--set criteria_override=`. Verified post-write:

```sh
bp task get <id> -o json | python3 -c "import json,sys;\
d=json.load(sys.stdin)['doc'];print(d['content']['close_override']['criteria'].keys())"
# dict_keys(['actor','reason','ts','unmet'])   <- criteria_override PERSISTS

bp task get <id> -o json | grep -c holder_override
# 0   <- holder_override is ACCEPTED WITHOUT ERROR AND DISCARDED
```

Put the holder rationale in the positional `reason` (→ `content.close_reason`) instead.

## 4. Stale anchors on the still-open rows

```sh
git show origin/main:api/lib/barkpark/studio_chat/recorder.ex | grep -n runtime_text
# 1113: %{state | runtime_text: state.runtime_text <> runtime_delta(event)}   (row says 1046)
# 1345: defp persist_runtime_text(...)                                        (row says 1274)
git show origin/main:api/lib/barkpark/studio_chat/recorder.ex | sed -n '826p'
#   def handle_info(:reported_fence_check, state) do   <- unrelated code (row says 826-838)
git show origin/main:api/lib/barkpark/studio_chat/recorder.ex | grep -n persist_assistant_blocks
# 853 / 910   <- the real anchor

git ls-tree -r --name-only origin/main | grep readiness
# api/lib/barkpark/studio_chat/runtime/codex/readiness.ex   <- the row's path is CORRECT
git show origin/main:api/.sobelow-skips | grep -n readiness
# 57:CI.System: ...readiness.ex:42,6CC3DE8   <- row says line 71; the FILE line is 57
git show origin/main:api/lib/barkpark/studio_chat/runtime/codex/readiness.ex | grep -n System.cmd
# 42:   <- still correct
```

## 5. The live Sobelow finding set — 51 findings, 11 files, 100% annotatable

```sh
gh run list --workflow=security.yml --branch=main --limit 3 \
  --json databaseId,conclusion   # workflow says "success"
gh run view 30342320311 --json jobs | python3 -c "import json,sys;\
[print(j['conclusion'],j['name']) for j in json.load(sys.stdin)['jobs']]"
# failure | Sobelow static analysis (regression gate, baseline .sobelow-skips)
# success | Sobelow baseline does not swallow its own inline waivers (blocking)

gh run view 30342320311 --log-failed > /tmp/sob.log
```

Parse (strip gh timestamps + ANSI, pair `File:`/`Line:`):

```
N=51
 34  Traversal.FileModule    10 SQL.Query    3 SQL.Stream
  2  CI.System                1 Config.Headers   1 DOS.StringToAtom

 12  lib/barkpark/sites/deploy_runner.ex
 10  lib/barkpark/tenancy/workspace_bundle.ex
  8  lib/barkpark/media/blobstore/s3.ex
  7  lib/barkpark/media/blobstore/local.ex
  6  lib/barkpark/tenancy/workspace_bundle/janitor.ex
  3  lib/barkpark/tenancy.ex
  1  each: router.ex, renditions.ex, bulldocs.ex, titles.ex, tasks/validation.ex

Config.CSRF in reddening set? False
XSS.Raw     in reddening set? False
.heex file  in reddening set? False
```

The "unannotatable residue" (Config.CSRF / heex XSS.Raw) is a property of the
**baseline file**, not of what is redding the gate. Every one of the 51 is in `.ex`
code and therefore carries an inline `# sobelow_skip`.

## 6. Drift arithmetic — tenancy.ex is provably line-shift, not new code

```sh
git show origin/main:api/.sobelow-skips | grep 'tenancy.ex:'
# 1154, 1167, 1178
# reddening: 1367, 1380, 1391   →  +213, +213, +213 UNIFORM
```

`workspace_bundle.ex` does NOT drift uniformly: baseline holds **7** entries
(299/328/340/345/348/354/358), the rescan reports **10**. That 3-site excess is the
only place a never-reviewed SQL site can be hiding — it needs per-site AST work, not
arithmetic.

`janitor.ex` has **6** reddening findings and **ZERO** baseline entries:

```sh
git show origin/main:api/.sobelow-skips | grep -c janitor    # 0
```

The file was born inside the blind window and was never baselined at all.

## 7. Prior art that already landed — check before re-filing

```sh
bp search query "sobelow inline annotation fingerprint migration baseline" -o json
# hgw2-s2-sobelow-honest-baseline            (open)
# hg-bl-sobelow-fingerprint-to-inline-migration (open)
# hg-bl-sobelow-inline-annotation-reversion  (open)

git log -S"mix sobelow --skip --mark-skip-all" --oneline origin/main \
  -- api/scripts/sobelow-baseline-reconcile.sh
# c69cc0b1e fix(security): sobelow baseline stops swallowing its own inline waivers (#6412)
gh pr view 6412 --json mergedAt   # 2026-07-27T22:48:51Z
```

`#6412` merged the `--skip --mark-skip-all` fix — so `hg-bl-sobelow-inline-annotation-reversion`'s
named mechanism is already gone, and `hgw2-s2-sobelow-honest-baseline` drove the PR.
Both rows are still `open`. The reconciler is fixed; **the gate is still red**.

## 8. The ratified per-site precedent already on main

```sh
git show origin/main:api/lib/barkpark/sites/deploy_runner.ex | sed -n '1372,1380p'
#   # sobelow_skip ["CI.System"]
#   defp bounded_cmd(path, args, opts) do
#     task = Task.Supervisor.async_nolink(Barkpark.TaskSupervisor, fn -> System.cmd(...) end)
#     case Task.yield(task, ctl_cmd_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
git show origin/main:api/.sobelow-skips | grep 'deploy_runner' | grep -c CI.System   # 0
```

Three call sites consolidated into ONE helper with ONE annotation, and the three
`.sobelow-skips` CI.System fingerprints deleted. The annotation sits on a `defp`, so
privacy is no barrier. This is both the shape `task-felix-w21-bl-readiness-sobelow-inline`
is told to copy and live evidence for `task-felix-w21-bl-boundedcmd-extraction-eval`.
