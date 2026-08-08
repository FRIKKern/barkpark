# dr-w22 — fence truth at build time (re-derivation recipe)

Verifier: `fence-truth-at-build-time`, 2026-08-08. Baseline `origin/main` = `b402c0083225816a5be1b5b65d012e87e3a93532`.

## Why the naive method lies

Three methods were tried; only the third is sound.

1. **`git branch --no-merged origin/main`** — returns 2502 of 2514 `loop-epic/*` refs. Useless: every
   branch is squash-merged, so ancestry never records the merge.
2. **Blob inequality** (`git rev-parse ref:path` vs `origin/main:path`) — overcounts in BOTH directions.
   It flags every branch merely *behind* main (all 400+ branches "differ" on `cloud/.../health.ex`
   because they carry the pre-`#10605` blob `e6691b9bc`), and it flags landed branches whose file main
   later changed again.
3. **`git diff --name-only origin/main...<ref>` (three-dot) + alias-aware PR liveness** — sound.

## The alias trap (the one that changed the answer by 6.6x)

A slice branch and its `-r` / `-rv` retry alias are the same slice; the PR is usually opened on the
alias. Checking only the base ref reports 106 refs "built and never pushed"; checking
`{base, base-r, base-rv, base-r2}` against merged+open head refs collapses that to **16 refs / 11
slices**. Same trap inverted: `git cherry` marks a squash-merged branch `+` when it had >1 commit.

## Recipe

```bash
cd /Volumes/SATECHI/github/barkpark && git fetch origin
S=$(mktemp -d)
git for-each-ref --format='%(committerdate:unix) %(refname:short)' refs/heads/loop-epic \
  | awk -v cut=$(date -v-3d +%s) '$1>=cut {print $2}' > $S/recent.txt
gh pr list --state merged --limit 900 --json headRefName -q '.[].headRefName' | sort -u > $S/merged.txt
gh pr list --state open   --limit 200 --json number,headRefName > $S/open.json
# live = has a commit whose patch-id is not upstream
while read -r r; do
  [ "$(git cherry origin/main "$r" | grep -c '^+')" -gt 0 ] && echo "$r"
done < $S/recent.txt > $S/live.txt
# unpushed = live AND no merged/open PR on ANY alias
python3 - "$S" <<'EOF'
import json,re,sys
S=sys.argv[1]
merged=set(open(S+"/merged.txt").read().split())
openh={p["headRefName"] for p in json.load(open(S+"/open.json"))}
def variants(r):
    b=re.sub(r"-(r|rv|r2)$","",r); return {b,b+"-r",b+"-rv",b+"-r2"}
out=[r for r in open(S+"/live.txt").read().split() if not (variants(r)&(merged|openh))]
open(S+"/unpushed.txt","w").write("\n".join(out)+"\n"); print(len(out))
EOF
# union lock = files of unpushed refs + files of every open PR
while read -r r; do git diff --name-only origin/main..."$r"; done < $S/unpushed.txt > $S/lock.txt
for n in $(python3 -c "import json;print(' '.join(str(p['number']) for p in json.load(open('$S/open.json'))))"); do
  gh pr view $n --json files -q '.files[].path' >> $S/lock.txt
done
sort -u $S/lock.txt > $S/UNION_LOCK.txt; wc -l < $S/UNION_LOCK.txt   # 138 on 2026-08-08
# assert a candidate path
grep -qx 'cloud/lib/barkpark_cloud/health.ex' $S/UNION_LOCK.txt && echo LOCKED || echo FREE
```

## Result recorded 2026-08-08 (origin/main b402c0083)

- 16 unpushed refs / 11 slices; 27 open PRs; **138-path union lock**.
- FREE: `cloud/lib/barkpark_cloud/health.ex`, `api/lib/barkpark/sites/deploy_runner.ex`,
  `api/lib/barkpark_web/controllers/instance_site_deploy_controller.ex`, `internal/cli/cloud_cmd.go`,
  and the prefixes `cloud/lib/barkpark_cloud/deploy_memory*`, `internal/cli/cloud_deploy_memory*`.
- LOCKED: `cloud/lib/barkpark_cloud/web/router.ex` (6 holders), `internal/cloudclient/client.go` (4),
  `cloud/lib/barkpark_cloud/deploy_ledger.ex` (5), `internal/cli/cloud_status_cmd.go` (3),
  `cloud/lib/barkpark_cloud/registry.ex` (2), `cloud/lib/barkpark_cloud/failure_copy.ex` (PR#10019).

## Worktree note

All 460 `git worktree list` entries are linked worktrees of the ONE repo at
`/Volumes/SATECHI/github/barkpark` (435 under `.claude/worktrees/`, 12 in the session scratchpad,
9 under `/Volumes/SATECHI/github/` incl. `barkpark-demo`, `barkpark-w19-fire`, `barkpark-w20-decide`
— each `.git` is a `gitdir:` FILE, verified). They share ONE `refs/heads` namespace, so enumerating
refs once from the primary checkout is complete; there is no second clone of this repo on the machine
(`barkpark-next-starter` is a different origin).
