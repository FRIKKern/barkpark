# S6 home + registration — re-derivation recipes (self-host-blessing W1 verify)

Every row re-derives from `origin/main` or the live GitHub/bp API. Run from the repo root.

## (a) PR #10155 state

```bash
gh pr view 10155 --json state,mergeable,mergeStateStatus,reviewDecision,updatedAt,files
gh pr checks 10155 | grep -i 'path-escape|Cloud gate'
gh run view --job 92792643098 --log | grep -i 'FAIL|passed,'
# is the PR branch behind the harness fix that unblocks it?
git fetch -q origin pull/10155/head:pr10155tmp
git merge-base --is-ancestor bc934ad0b0d7eb6813eeb0754f9880030d114da0 pr10155tmp; echo $?
git branch -D pr10155tmp
git log origin/main -1 --format='%H %ci %s' -S'post_verdict_shape' -- scripts/cloud-path-escape-check.test.sh
```

## (b) generator CLI

```bash
git show origin/main:scripts/required-checks-generate.sh > /tmp/gen.sh
bash /tmp/gen.sh --help | head -12     # prints the PROSE header, not a flag list
bash /tmp/gen.sh --help | wc -l        # 99 lines
bash /tmp/gen.sh --compose >/dev/null 2>/tmp/e; echo $?; cat /tmp/e
git show origin/main:scripts/required-checks-generate.sh | sed -n '473,545p'   # usage() + real arg parser
```

## (c) breakglass human gate + drift workflow token

```bash
bp search query "hg-breakglass-token-fine-grained"          # the id in the header is NOT the task id
bp task get hgw5-bl-breakglass-fine-grained-pat -o json
git show origin/main:.github/workflows/required-checks-drift.yml | grep -n BREAKGLASS
```

## (d) generator hand-maintained arrays

```bash
git show origin/main:scripts/required-checks-generate.sh | sed -n '124,150p'
git show origin/main:.github/required-checks.json | jq -r '.protection.required_status_checks.checks[].context'
```

## (e) cloud.yml dispatcher outputs + the ratchet pins

```bash
git show origin/main:.github/workflows/cloud.yml | sed -n '43,162p'
git show origin/main:scripts/cloud-path-escape-check.test.sh | sed -n '294,362p;392,455p'
git show origin/main:scripts/cloud-path-escape-check.sh | sed -n '155,220p'
# does a root-compose PR dispatch cloud=true?
git show origin/main:scripts/cloud-path-escape-check.sh > /tmp/cpe.sh
printf 'docker-compose.yml\n.env.example\napi/Dockerfile\napi/config/runtime.exs\n' \
  | CLOUD_PATH_ESCAPE_ROOT="$PWD" bash /tmp/cpe.sh --match cloud     # -> false
printf 'cloud/docker-compose.yml\n' | CLOUD_PATH_ESCAPE_ROOT="$PWD" bash /tmp/cpe.sh --match cloud  # -> true
```
