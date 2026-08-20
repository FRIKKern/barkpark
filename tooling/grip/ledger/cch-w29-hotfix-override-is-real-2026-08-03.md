# cch-w29 · V-lane `hotfix-override-is-real` — re-derivation recipes

Verifier lane for Cloud Console Hardening wave 29. Every row re-derives from
scratch. All code facts measured at `origin/main` `92f91f043`; the primary
checkout is `[ahead 48, behind 402]` and its `scripts/pr-task-gate.test.sh` has
NO hotfix coverage at all — reading it there yields the opposite conclusion.

## R1 — `BARKPARK_TASK_TOKEN` is NOT provisioned; there are ZERO repo variables

```bash
gh api repos/FRIKKern/barkpark/actions/secrets --jq '.secrets[].name'
gh api repos/FRIKKern/barkpark/actions/variables --jq '.variables[].name'
gh api repos/FRIKKern/barkpark --jq '.owner.type'        # User -> no org secrets possible
```

Secrets: `BREAKGLASS_TOKEN CP_HOST DEPLOY_SSH_KEY GUERRILLA_HOST HETZNER_DNS_TOKEN NPM_TOKEN`.
Variables: empty. So `vars.BARKPARK_LEDGER_BASE` is unset and the
`|| 'https://guerrilla.barkpark.cloud'` default is what pr-task-gate actually
uses — the guerrilla attribution is CORRECT, not wrong.

## R2 — the `hotfix!` lane is a guaranteed RED on this repo today

```bash
git show origin/main:.github/workflows/pr-task-gate.yml | sed -n '176,215p'
```

`:177` `if: … hotfix == '1'`; `:186-188` `[ -z "${TASK_TOKEN:-}" ] … exit 1`;
`:211` a non-200 ledger POST also `exit 1`. Every other step (`:216`, `:238`,
`:253`) carries `if: … hotfix != '1'`. So once the label engages, `hotfix_record`
is the only step left, and with no token it exits 1.

Direct run of that step body verbatim, token empty (the repo's real state):

```bash
W=$(mktemp -d); git worktree add --detach "$W" origin/main; cd "$W"
python3 - <<'EOF' > /tmp/body.hotfix_record
import re
lines=open('.github/workflows/pr-task-gate.yml').read().split('\n')
i=0
while not re.match(r"^\s*id:\s*hotfix_record\s*$", lines[i]): i+=1
while not re.match(r"^\s*run:\s*\|", lines[i]): i+=1
i+=1
ind=len(lines[i])-len(lines[i].lstrip())
out=[]
while i<len(lines) and (lines[i].strip()=='' or len(lines[i])-len(lines[i].lstrip())>=ind):
    out.append(lines[i][ind:]); i+=1
print('\n'.join(out))
EOF
GITHUB_STEP_SUMMARY=/tmp/hr.sum PR_NUMBER=9999 PR_TITLE=t PR_URL=u \
  LEDGER_BASE=https://guerrilla.barkpark.cloud TASK_TOKEN="" \
  bash --noprofile --norc -e -o pipefail /tmp/body.hotfix_record; echo "rc=$?"
```

→ `rc=1`, `::error title=Hotfix override not recorded::… BARKPARK_TASK_TOKEN is
not set … it is refused.`

## R3 — the lane's own harness PINS the red (green by construction it is not)

```bash
cd "$W" && bash scripts/pr-task-gate.test.sh
```

→ `ok hotfix record: no token REDS (exit 1)` / `ok hotfix record: dead ledger
REDS (exit 1)` / `ok hotfix record: filed passes (exit 0)`; `passed: 84 failed: 0`.

## R4 — the ledger-outage path exits 2 and the workflow converts it to 1

```bash
TASK_ID=task-does-not-exist LEDGER_BASE=http://127.0.0.1:1 \
  PR_TASK_GATE_RETRIES=2 PR_TASK_GATE_RETRY_DELAY=0 \
  bash scripts/pr-task-gate.sh; echo "rc=$?"
```

→ `rc=2`, `pr-task-gate: UNCHECKED: could not reach the ledger …`.
`pr-task-gate.yml:276-283` converts it to `exit 1` under
`::error title=Ledger unreachable — task backing UNVERIFIED::`, whose remediation
sentence ends **"the hotfix! lane is the documented override"** — false on this
repo, and false for outage even with a token, because `hotfix_record` POSTs to
the SAME dead host.

## R5 — `hotfix!` label does not exist; one collaborator, admin

```bash
gh api repos/FRIKKern/barkpark/labels --jq '.[].name' | grep -i hotfix   # rc=1, no output
gh api repos/FRIKKern/barkpark/collaborators --jq '.[].login'            # FRIKKern
```

## R6 — the REAL, armed, tested override is break-glass, and merge-gates.md never names it

```bash
grep -n -i 'break.glass\|breakglass' docs/ops/merge-gates.md   # rc=1, no output
git show origin/main:docs/ops/break-glass-log.md | sed -n '1,40p'
grep -rn BREAKGLASS_TOKEN .github/ scripts/ docs/
```

`BREAKGLASS_TOKEN` IS provisioned (R1), `breakglass-watch.yml` runs every 30
minutes, `scripts/breakglass.test.sh` exists, the log is append-only.

## R7 — merge-gates.md is stale on both the lane and the context list

```bash
git show origin/main:docs/ops/merge-gates.md | sed -n '55,57p;128p;395,399p'
gh api repos/FRIKKern/barkpark/branches/main/protection \
  --jq '{contexts:.required_status_checks.contexts,enforce_admins:.enforce_admins.enabled}'
```

Doc `:55-57` and `:397-398`: "without it the lane still passes but logs that the
record was not filed" — the committed code exits 1. Doc `:128` prints a
two-context protection body; live is four.
