# Break-glass clause 4 — "cannot be left open silently" — re-derivation recipes

Wave: honest-gates wave 5 (the flip). Verifier lane `breakglass-clause4-reachable`.
Measured on `origin/main @ ab396959c`, 2026-07-28.

## 1. The live authority is dead in CI (403 → UNKNOWN → run SUCCESS)

```bash
gh run list -R FRIKKern/barkpark --workflow breakglass-watch.yml --limit 20 \
  --json databaseId,conclusion,event,createdAt
gh run view 30395930365 -R FRIKKern/barkpark --log | grep -E '403|UNKNOWN'
gh secret list -R FRIKKern/barkpark   # BREAKGLASS_TOKEN is NOT among the five
```

## 2. A BAD/absent token is indistinguishable from a transport blip (exit 2 → workflow exit 0)

```bash
TMP=$(mktemp -d); jq '.enforced=true' .github/required-checks.json > $TMP/spec.json
GH_TOKEN=gho_deadbeefdeadbeefdeadbeefdeadbeefdead BG_RETRY_SLEEP="0 0 0" \
  bash scripts/breakglass-watch.sh --spec $TMP/spec.json --log /dev/null --attempts 2
echo "RC=$?"   # 2 ; breakglass-watch.yml maps 2 -> exit 0
```

## 3. The fix is one command away — the LOCAL token already has the scope

```bash
gh api repos/FRIKKern/barkpark --jq '{owner_type:.owner.type,perm:.permissions}'
T=$(gh auth token); GH_TOKEN="$T" gh api repos/FRIKKern/barkpark/branches/main/protection
# -> {"message":"Branch not protected", ... "status":"404"} = an ANSWER, i.e. the read is permitted
# provisioning (NOT run by this verifier): gh secret set BREAKGLASS_TOKEN -R FRIKKern/barkpark -b "$T"
```

## 4. Post-flip, required-checks-drift goes permanently RED under GITHUB_TOKEN

```bash
grep -n 'GH_TOKEN' .github/workflows/required-checks-drift.yml      # github.token, no fallback
sed -n '92,99p' scripts/required-checks-verify.sh                    # fail "cannot read live protection"
gh run view 30397943587 -R FRIKKern/barkpark --log | grep 'unreadable protection API is a hard failure'
```

## 5. Obstacle "the record cannot be pushed while armed" is REFUTED by the charter's own D39

```bash
grep -n 'D39' .claude/workflows/bp-honest-gates-charter.md | head -2
# "...with enforce_admins:false the identical push SUCCEEDS and GitHub prints
#  `remote: Bypassed rule violations for refs/heads/<b>:` — so one DELETE …/enforce_admins
#  restores BOTH admin merge and direct push"
```

## 6. No audit log, no webhooks, no rulesets (obstacle 1 stands, and is already designed around)

```bash
gh api orgs/FRIKKern/audit-log; gh api users/FRIKKern/audit-log
gh api repos/FRIKKern/barkpark/hooks; gh api repos/FRIKKern/barkpark/rulesets
```
