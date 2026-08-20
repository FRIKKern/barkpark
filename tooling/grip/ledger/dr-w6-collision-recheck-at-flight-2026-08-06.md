# dr-w6 — collision map + base-branch choices, re-derived AT FLIGHT TIME (2026-08-06)

Re-derivation recipes only. Every row is a literal command; nothing here is quoted from a prior wave.

## Ground refs at derivation time

```bash
cd /Volumes/SATECHI/github/barkpark && git fetch -q origin && git rev-parse origin/main
# ef77af2748ceda54fdd6e078f71a6e6044b55439
for a in 9887 9888 9889 9890; do git fetch -q origin refs/pull/$a/head:refs/pr/$a; done
for a in 9887 9888 9889 9890; do echo "$a $(git rev-parse refs/pr/$a)"; done
# 9887 aa19dcca3a5a8f2f6edd014e9369c3a5f5c263c2
# 9888 e92cb6fe9116929c05e630801316c40411e62331
# 9889 479ebb86fdf885f33b4325be30f8b52dd76810b4
# 9890 f8c94fb38148a25417c9e6291c51e861338a5c17
```

## R1 — four vs main, six pairwise (all CLEAN)

```bash
for a in 9887 9888 9889 9890; do git merge-tree --write-tree origin/main refs/pr/$a >/dev/null 2>&1 \
  && echo "$a vs main CLEAN" || echo "$a vs main CONFLICT"; done
for a in 9887 9888 9889; do for b in 9888 9889 9890; do [ "$a" -lt "$b" ] && \
  { git merge-tree --write-tree refs/pr/$a refs/pr/$b >/dev/null 2>&1; echo "$a x $b rc=$?"; }; done; done
```

## R2 — the pairwise-base caveat is MOOT (main is 1 commit past the shared base, zero overlap)

```bash
git rev-list --count bf97452bb..ef77af274                 # 1
git diff --name-only bf97452bb ef77af274                  # 5 files, all under api/sites — no PR-set overlap
```

## R3 — sequential four-deep stack simulation (the order the wave will actually merge)

```bash
T=$(git merge-tree --write-tree origin/main refs/pr/9887)
C1=$(git commit-tree $T -p origin/main -p refs/pr/9887 -m sim1)
T2=$(git merge-tree --write-tree $C1 refs/pr/9889); C2=$(git commit-tree $T2 -p $C1 -p refs/pr/9889 -m sim2)
T3=$(git merge-tree --write-tree $C2 refs/pr/9888); C3=$(git commit-tree $T3 -p $C2 -p refs/pr/9888 -m sim3)
git merge-tree --write-tree $C3 refs/pr/9890 && echo "4-deep stack CLEAN"
```

## R4 — router.ex is the only two-PR file; measure the real hunk separation

```bash
git diff -U0 origin/main...refs/pr/9888 -- cloud/lib/barkpark_cloud/web/router.ex | grep '^@@'  # @@ 481, @@ 8764
git diff -U0 origin/main...refs/pr/9889 -- cloud/lib/barkpark_cloud/web/router.ex | grep '^@@'  # @@ 58, @@ 1319, @@ 7776
# nearest neighbours: 481 vs 58 = 423 lines. NOT ~7,400.
```

## R5 — stack-base proofs (why slice 3 rides #9887 and slice 2's consumer rides #9889)

```bash
git grep -c "Err5xxPerS\|Load15\|CPUCores" origin/main -- internal/cloudclient/client.go   # exit 1, 0 hits
git grep -n "Err5xxPerS\|Load15\|CPUCores" refs/pr/9887 -- internal/cloudclient/client.go # 187,190,196
git grep -n "func attentionStatus" origin/main refs/pr/9887 -- internal/cli/cloud_status_cmd.go  # :50 -> :92
git diff --stat origin/main...refs/pr/9887 -- internal/cli/cloud_status_cmd.go            # 277 changed
git grep -c "normalize_space" origin/main -- cloud/                                        # exit 1, 0 hits
git grep -n "def normalize_space" refs/pr/9889 -- cloud/                                   # telemetry.ex:165,171,192
```

## R6 — foreign-PR poll (cch w37 and any router/registry/telemetry/metrics/CLI toucher)

```bash
gh pr list --state open --limit 200 --json number,headRefName,mergeStateStatus \
  -q '.[]|[.number,.mergeStateStatus,.headRefName]|@tsv'
for n in $(gh pr list --state open --limit 200 --json number -q '.[].number'); do
  gh pr view $n --json files -q '[.files[].path]|join(" ")' | tr ' ' '\n' \
    | grep -E 'barkpark_cloud/(web/router|registry|telemetry|metrics)|^internal/cli/|^internal/cloudclient/|^cmd/barkpark-agent/' \
    | sed "s/^/$n: /"; done
# only 6028 (DIRTY, no merge base with main, last touched 2026-07-31) hits the fence.
gh pr list --state merged --limit 60 --json number,headRefName,mergedAt \
  -q '.[]|select(.mergedAt>"2026-08-06T00:00:00Z")|[.number,.mergedAt,.headRefName]|@tsv'
# cch w36 slices 9847-9851 all merged 14:35-14:41Z and are already inside bf97452bb:
git merge-base --is-ancestor $(gh pr view 9848 --json mergeCommit -q .mergeCommit.oid) bf97452bb && echo "in base"
```

## R7 — w37 has not dispatched, and its declared reach excludes cloudclient

```bash
git fetch -q origin refs/pull/9857/head:refs/pr/9857
git diff origin/main...refs/pr/9857 -- .claude/workflows/bp-cloud-console-hardening-charter.md \
  | grep '^+' | grep -io "SLICE [0-9][^|]\{0,180\}"
# D418: "the CLI blindness is a THIRD change, filed to the backlog" — w37 does NOT edit internal/cloudclient.
# w37 slices DO edit cloud/lib/barkpark_cloud/web/router.ex (18 route-scope sites) — the live collision axis.

git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '755,760p'
# cession is Wave-36-scoped ("this round") and names "deploy-reliability wave 4" — wave 6 must RE-ASSERT it.
```
