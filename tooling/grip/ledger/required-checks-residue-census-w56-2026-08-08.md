# Re-derivation recipes — required-checks residue census (wave 56, v11)

All commands assume cwd = repo root and `git fetch origin main` has run.
Baseline sha: `origin/main` = `b97663730a7a98c39f05a607110bdad5981c81e4`.

## R0 — the local checkout is 705 commits behind; the briefed MUST-RUN is vacuous here

```sh
git rev-list --count HEAD..origin/main            # -> 705
grep -n '"enforced"' .github/required-checks.json # -> "enforced": false   (working tree)
git show origin/main:.github/required-checks.json | grep -n '"enforced"'  # -> "enforced": true
bash scripts/required-checks-verify.sh 2>&1 | tail -5
```
`required-checks-verify.sh` reads the WORKING TREE spec. In this checkout that spec
is the pre-flip 2-context `enforced:false` file, so the script prints
`OK: … protection is not applied yet.` — a green that measured a spec 705 commits
dead. Any wave-56 proof using this script MUST run it from a tree cut at origin/main.

## R1 — the residue census (job names with no merge authority anyone tracks)

Extract origin/main whole-tree, then run the census script:

```sh
D=$(mktemp -d); git archive origin/main | tar -x -C "$D"
python3 - "$D" <<'PY'
import json,os,re,sys,yaml
D=sys.argv[1]; wf=os.path.join(D,".github/workflows")
spec=json.load(open(os.path.join(D,".github/required-checks.json")))
req={c["context"] for c in spec["protection"]["required_status_checks"]["checks"]}
base=lambda n: re.sub(r'\s*\(\d+\.\d+,\s*\d+\.\d+\.\d+\)$','',n)
excb={base(e["context"]) for e in spec["exclusions"]}
rows=[];byfile={}
for f in sorted(os.listdir(wf)):
    if not f.endswith((".yml",".yaml")): continue
    d=yaml.safe_load(open(os.path.join(wf,f))); on=d.get("on",d.get(True))
    for jid,j in (d.get("jobs") or {}).items():
        if not isinstance(j,dict): continue
        r=dict(file=f,jid=jid,name=j.get("name",jid),needs=j.get("needs"),
               coe=j.get("continue-on-error"),on=on)
        rows.append(r); byfile.setdefault(f,{})[jid]=r
def cl(f,jid,seen):
    r=byfile[f].get(jid)
    if not r or jid in seen: return
    seen.add(jid); n=r["needs"]; n=[n] if isinstance(n,str) else (n or [])
    [cl(f,x,seen) for x in n]
cov=set()
for r in rows:
    if r["name"] in req:
        s=set(); cl(r["file"],r["jid"],s); cov|={(r["file"],j) for j in s}
res=[r for r in rows if r["name"] not in req and base(r["name"]) not in excb
     and (r["file"],r["jid"]) not in cov]
prc=lambda o: isinstance(o,dict) and "pull_request" in o
prres=[r for r in res if prc(r["on"])]
blk=[r for r in prres if not r["coe"]]
print(len(rows),len(res),len(prres),len(blk))
for r in blk: print(" ",r["file"],"|",r["name"])
PY
```
Expected on b97663730: `85 55 40 35` — 85 jobs, 55 residue, 40 PR-renderable,
35 of those carry no `continue-on-error` (i.e. read as blocking-shaped).

## R2 — `gofmt drift ceiling (blocking)` is in neither instrument

```sh
git show origin/main:.github/required-checks.json | grep -c gofmt   # -> 0 (exit 1)
git show origin/main:docs/ops/merge-gates.md      | grep -ci 'gofmt\|go[- ]format\|drift ceiling'  # -> 0 (exit 1)
git show origin/main:.github/workflows/go-format.yml | grep -n 'name:'  # -> :47 gofmt drift ceiling (blocking)
```
And the guard itself is live and non-vacuous:
```sh
(cd "$D" && bash scripts/go-format-drift-ceiling.sh)
# OK: 739 Go files scanned; 0 off-roster drift; roster holds 0 grandfathered file(s).
```

## R3 — pr-task-gate is the only required context with no nothing-dispatched notice

```sh
for f in cloud.yml console-harness.yml elixir.yml pr-task-gate.yml; do
  printf '%s: ' "$f"
  git show "origin/main:.github/workflows/$f" | grep -c 'nothing ran'
done   # -> cloud 1, console 1, elixir 1, pr-task-gate 0
```

## R4 — the grandfather branch's live residue is ZERO

```sh
for n in $(gh pr list --state open --limit 60 --json number -q '.[].number'); do
  sha=$(gh pr view "$n" --json baseRefOid -q .baseRefOid)
  git cat-file -e "$sha:.github/workflows/pr-task-gate.yml" 2>/dev/null \
    && echo "$n ENFORCED" || echo "$n GRANDFATHERED"
done
git log origin/main --diff-filter=A --format='%H %ad' --date=short -- \
  .github/workflows/pr-task-gate.yml | tail -1   # 9189854eb 2026-07-07
```
13/13 sampled open PRs (incl. #10945, whose base is a `loop-epic/` branch) resolve
ENFORCED. Day-one baseline roster for a "the gate must have evaluated something"
guard is therefore EMPTY — it can be written zero-tolerance, no grandfather list.
