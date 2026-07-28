# Re-derivation: branch protection on main (cloud-console-hardening wave 7 verify)

Measured 2026-07-28 against live GitHub and `origin/main` @ f38c01920.

## Is main protected? NO.

```sh
gh api repos/FRIKKern/barkpark/branches/main/protection || echo NO_PROTECTION
# -> {"message":"Branch not protected", ... "status":"404"}  then NO_PROTECTION
gh api repos/FRIKKern/barkpark/rulesets
# -> []
gh api repos/FRIKKern/barkpark/branches/main/protection/required_status_checks || true
# -> {"message":"Branch not protected", ... "status":"404"}
```

## Is the CSSOM check registered by name? NO — and it was never even sampled.

```sh
git show origin/main:.github/required-checks.json | \
  python3 -c "import json,sys;d=json.load(sys.stdin);print(d['enforced']);print([c['context'] for c in d['protection']['required_status_checks']['checks']]);print([e['context'] for e in d['exclusions']])"
# enforced: False
# required: ['Elixir gate', 'PR references an active task']
# exclusions: CSSOM parity is NOT among them
git show origin/main:.github/workflows/console-harness.yml | grep -n "name:\|paths:"
# :91  name: CSSOM parity (authored CSS vs browser)  — inside a WORKFLOW-LEVEL paths-filtered workflow
git show --name-only --format= f30512cb0 | grep -c '^cloud/priv/static'   # 0 — a sampled sha that renders no console-harness run
```

## Is the fleet token capable of flipping it? YES (so it is not a human gate).

```sh
gh api repos/FRIKKern/barkpark --jq '{admin:.permissions.admin,push:.permissions.push}'
# {"admin":true,"push":true}
```

## Live ledger state

```sh
bp task get hgw2-s7-enable-branch-protection -o json   # lifecycle open, 0/12 criteria met
bp task get hgw2-s6-required-check-spec -o json        # done — spec committed, enforced:false, "no protection change applied to main"
bp task get stw10-backlog-branch-protection -o json    # cancelled 2026-07-28: "NOT A HUMAN GATE — this fleet's token already carries repo admin"
bp task get cch-hg-register-cssom-required-check -o json  # lifecycle open, priority 2, 0/3
```
