# S7 exclusion expiry — the dead trigger lives in the GENERATOR, not the spec (2026-08-18)

Verified against `origin/main` (c9b25c8ea1 era). Re-derivation recipe, no mutations to the checkout.

## 1. PR #8222 is CLOSED, never merged

    gh pr view 8222 --json number,state,mergedAt,title

→ `{"mergedAt":null,"number":8222,"state":"CLOSED", ...}` (closedAt 2026-07-31T02:45:36Z).

## 2. The COMMITTED spec already knows this (brief premise refuted)

    git show origin/main:.github/required-checks.json | jq -r '.exclusions[] | select(.context=="Required-check spec gate") | .reason'

The committed row was hand-corrected 2026-08-06 (wave 36) and says verbatim:
"'Re-evaluate once #8222 lands or is rebased' was a trigger that can NEVER FIRE — #8222 is CLOSED with
mergedAt null … the exclusion sealed itself shut". It carries a live replacement trigger
(spec gate green on main HEAD + a clean `scripts/registration-deadlock-sweep.sh`).

## 3. The GENERATOR still hardcodes the dead trigger

    git show origin/main:scripts/required-checks-generate.sh | sed -n '156,162p'

`EXCLUDED_BY_DECISION_REASONS[0]` ends: "Re-evaluate once #8222 lands or is rebased."
Introduced dcd8c9ceff (#8394); never updated (`git log -S'Re-evaluate once #8222 lands or is rebased'`
returns that one commit only).

## 4. Regeneration CLOBBERS the correction — derived reason wins

Generator emit, line ~1034: `group_by(.context) | map(.[-1])`, base first, derived appended
("the LAST row in each group wins — i.e. the DERIVED reason beats the committed one").
`scripts/required-checks.test.sh:1550-1558` asserts exactly this behaviour.

Minimal reproduction:

    jq -n --argjson b '{"exclusions":[{"context":"X","reason":"HAND-CORRECTED"}]}' \
          --argjson exclusions '[{"context":"X","reason":"STALE GENERATOR"}]' \
          --argjson promoted_drop '[]' \
      '((($b.exclusions // [] | map(select(.context as $c | $promoted_drop | index($c) | not))) + $exclusions)
        | group_by(.context) | map(.[-1]) | sort_by(.context))'
    # → reason == "STALE GENERATOR"

## 5. The hermetic drift tripwire — reds TODAY on BOTH S7 rows

Compare the generator's `EXCLUDED_BY_DECISION_{NAMES,REASONS}` arrays against the reasons committed in
`.github/required-checks.json` for the same contexts. Pure file reads: no network, no `gh`, no auth.

    D=$(mktemp -d)
    git show origin/main:scripts/required-checks-generate.sh > "$D/gen.sh"
    git show origin/main:.github/required-checks.json > "$D/spec.json"
    python3 - "$D" <<'PY'
    import re,json,sys
    D=sys.argv[1]
    g=open(D+"/gen.sh").read()
    names=re.findall(r'"([^"]+)"', re.search(r'EXCLUDED_BY_DECISION_NAMES=\((.*?)\)\n',g,re.S).group(1))
    reasons=re.findall(r'^  "(.*)"$', re.search(r'EXCLUDED_BY_DECISION_REASONS=\((.*?)\n\)\n',g,re.S).group(1), re.M)
    comm={e["context"]:e["reason"] for e in json.load(open(D+"/spec.json"))["exclusions"]}
    rc=0
    for n,r in zip(names,reasons):
        r=r.replace('\\`','`').replace('\\"','"')
        if comm.get(n,"<ABSENT>")!=r: rc=1; print("DRIFT:",n)
    sys.exit(rc)
    PY

Observed 2026-08-18: DRIFT on `Required-check spec gate` AND `Security gate`; exit 1.

## 6. PR-liveness tripwire (second tier, NOT hermetic)

Extract `#<n>` from every S7 reason and refuse when the cited PR is CLOSED-unmerged or MERGED:

    git show origin/main:.github/required-checks.json \
      | jq -r '.exclusions[].reason' | grep -o '#[0-9]\+' | sort -u
    # → #8222, #8253
    gh pr view 8222 --json state,mergedAt     # 0.57s wall, needs network + gh auth

Cheap (sub-second, ≤2 PRs today) but network-bound: it belongs behind the hermetic §5 check,
not inside `required-checks.test.sh --hermetic`.

## 7. Second-order: the committed row's tracking task is superseded

`cch-w36-bl-register-spec-gate-after-census-green` — `bp search query "cch-w36-bl-register-spec-gate"`
returns cch-w38-s3 declaring it a superseded duplicate of `cch-w37-bl-register-spec-gate-human-gate`.
