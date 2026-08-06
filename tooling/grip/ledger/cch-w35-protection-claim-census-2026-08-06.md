# cch-w35 — repo-protection-claim census, re-derivation recipes (2026-08-06)

Measured at `origin/main == c73bbc07c`. Every line is a recipe, not a conclusion.
The local checkout is BEHIND origin/main — run every grep against `origin/main`,
never the worktree (that is the trap that made a wave-35 surveyor declare
`advisory_prose_check` nonexistent).

## 1. Ground truth: main IS protected, and it is NOT a ruleset

    gh api repos/:owner/:repo/branches/main/protection --jq '.required_status_checks.checks[].context'
    # -> Elixir gate / PR references an active task / Cloud gate / Console gate
    gh api repos/:owner/:repo/branches/main/protection --jq '.enforce_admins.enabled'   # -> true
    gh api repos/:owner/:repo/rulesets                                                  # -> []
    gh api repos/:owner/:repo/rules/branches/main                                       # -> []

CONSEQUENCE FOR ANY CLAUSE: **`no rulesets` is a TRUE reading and must NOT be in
the regex.** `docs/ops/merge-gates.md:241` states the trap in the repo's own words.

## 2. The broad regex over-counts by 2.2x — it is not the clause

    git grep -nIE 'no branch protection|no rulesets|not protected|unprotected|Branch not protected|no CI check in this repo' \
      origin/main -- '*.md' '*.yml' '*.sh' | wc -l
    # -> 77

`unprotected` in this corpus means: an unprotected export path (`bp-pds-charter.md:312`),
unprotected DB columns (`scripts/pds-pull-proof.sh:2314`), an unprotected 55-byte
honour-system line (`scripts/pds-crown-ledger-2026-07-20.md:33`), an unprotected PR
base (`bp-pds-charter.md:14868`), and a deliberately-unprotected test fixture
(`scripts/required-checks.test.sh:881-912`). `Branch not protected` is the GitHub
API's own 404 message, quoted as EXPECTED OUTPUT in `scripts/breakglass.sh:153`,
`scripts/breakglass.test.sh:81,255`, `scripts/breakglass-watch.sh:111,139`,
`scripts/required-checks-verify.sh:109` and ~10 recipe ledgers.

## 3. The narrow claim-shape regex, and the four-class census

    RE='(no|NO|zero|No) branch protection|no branch protection/ruleset|main is NOT PROTECTED|NO branch protection at all|no CI check in this repo can block a merge'
    git grep -nIE "$RE" origin/main -- .claude/workflows .github docs scripts tooling/grip/ledger CLAUDE.md | wc -l
    # -> 35

| class | n | meaning | clause must |
|---|---|---|---|
| A — LIVE CLAIM | 21 | asserts main-of-this-repo is unprotected, no retraction | RED (fix or pin) |
| B — RETRACTION | 9 | dated inline retraction / quoted-then-refuted | never red |
| C — DATED RECIPE / GREP LITERAL | 4 | a ledger true at its date, or the phrase used as a `grep` pattern | never red |
| D — OTHER REPO | 1 | `jarl-gates-live-status-2026-07-31.md:45` — about `FRIKKern/jarl-website` | never red |

Class C includes `bp-cloud-console-hardening-charter.md:375` (D106), where the
matched text is `` grep -c "no branch protection" `` — a **search pattern, not a
claim**. Literal matching cannot tell those apart; that is why members are PINNED
and re-reviewed on edit rather than auto-classified.

Class D is TRUE about its subject:

    gh api repos/FRIKKern/jarl-website/branches/main/protection
    # -> {"message":"Branch not protected","status":"404"}

## 4. This epic's own charter is an offender (2 live, not 5)

    git grep -nIE "$RE" origin/main -- .claude/workflows/bp-cloud-console-hardening-charter.md
    # -> :326 (B, inline RETIRED)  :332 (B, inline RETIRED)  :375 (C, grep literal)
    #    :1412 (A LIVE)            :4282 (A LIVE)

## 5. The mirror a directory-scoped fix misses

    git show origin/main:.github/workflows/bp-graph-drift.yml   | sed -n '15,19p'
    git show origin/main:scripts/check-bp-graph-drift.sh        | sed -n '27,31p'
    git show origin/main:.claude/workflows/bp-search-template-charter.md | sed -n '103p'

Three copies of ONE argument (workflow comment, script comment, and the D72 charter
row that justifies both). Fixing fewer than three leaves the rationale intact.

## 6. `advisory_prose_check` EXISTS and structurally cannot catch this

    git grep -n 'advisory_prose_check' origin/main -- scripts .github
    # -> scripts/required-checks-verify.sh:39,374,459,472,505

It scans `find "$WORKFLOWS_DIR" -maxdepth 1 -name '*.yml'` only, and fires only when
a SPEC'D CONTEXT NAME appears within 200 chars of a disclaimer. A blanket
"this repo has no branch protection" names no context and lives in `.claude/workflows/*.md`,
`docs/`, `scripts/`, `tooling/` — outside both the scan set and the match shape.
The new clause is a SIBLING, not a widening of `PROSE_DISCLAIMERS`.

## 7. The proving gate for a scripts-only diff EXISTS (and is not a required context)

    git show origin/main:.github/workflows/required-checks-drift.yml | sed -n '93,113p'
    # job `spec-gate` / name "Required-check spec gate", no `on:.paths` key on either
    # trigger, step: bash scripts/required-checks.test.sh --hermetic

So a clause shipped inside `required-checks-verify.sh` + asserted in
`required-checks.test.sh` DOES execute on every PR including a scripts-only one.
It is not one of the four required contexts, so it reds the page without blocking.

## 8. Mutation proof — the clause can lose in BOTH directions

Guard: `git grep -nIE "$RE"` over the scan set; key = `sha256(matched line)[0:16] + path`;
pins in `.github/protection-claim-pins.txt`; red on ADD or on a pin whose member vanished.

    # baseline, 35 pins        -> OK: 35 pinned protection claims, none added, none removed.  exit=0
    # ADD a claim to a tracked file (docs/ops/merge-gates.md)
    #                          -> FAIL: new repo-protection claim(s) ... + 75953ca852c0fbb9 docs/ops/merge-gates.md   exit=1
    # FIX a pinned member (bp-graph-drift.yml:15) WITHOUT dropping its pin
    #                          -> FAIL: pinned claim(s) no longer present ... - 1e51019ec9a55546   exit=1
    # same fix, pin dropped in the SAME commit
    #                          -> OK: 34 pinned protection claims ...   exit=0

## 9. TWO MEASURED LIMITS, stated so nobody claims more than it does

**(a) `git grep` is TRACKED-ONLY.** An untracked new file carrying the claim scores ZERO:

    git grep     -lIE 'no branch protection' -- <new-untracked>.md   # -> 0 hits
    git grep --untracked -lIE 'no branch protection' -- <new-untracked>.md   # -> 1 hit

In CI the file is committed so this cannot false-green a PR, but any LOCAL
mutation proof must `git add -N` first or it proves nothing. Use `--untracked`.

**(b) A FRESH PARAPHRASE ESCAPES.** Appending
`"Nothing in CI mechanically blocks a merge here; the gates are discipline."`
to a tracked file leaves the guard GREEN (exit 0). Measured, not assumed.
This is acceptable ONLY because every paraphrase-only hit in today's corpus lives
in a file the literal clause already catches:

    git grep -nIE 'nothing mechanically blocks|advisory theatre|no required-check list to register|does not (yet )?mechanically block' \
      origin/main -- '*.md' '*.yml' '*.sh'
    # -> 7 hits, all in files already in the 35-member census

`bp-search-template-charter.md:96` is the reason `no CI check in this repo can block a merge`
is enumerated EXPLICITLY: its only other match on that line is the class-C API
literal `404 "Branch not protected"`, which the clause deliberately exempts.
Drop that alternation branch and :96 escapes silently.

## 10. Untracked-ledger blast radius is 2, not ~60

    git status --porcelain -- tooling/grip/ledger/ | grep '^??' | sed 's/^?? //' \
      | while read -r f; do grep -lIE '(no|NO|zero) branch protection|no CI check in this repo can block' "$f"; done
    # -> tooling/grip/ledger/felix-w24-wave23-criteria-closes-2026-07-29.md   (class B — quotes then refutes)
    #    tooling/grip/ledger/stale-protection-claims-census-2026-07-30.md

## 11. `bp-graph-drift.yml` is NOT in the wave-11 fence dispensation

    git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '234,243p'

The dispensation names `cloud.yml`, `security.yml`, `required-checks-drift.yml`,
`required-checks.json`, `required-checks-{generate,apply,floor,verify}.sh`,
`required-checks.test.sh`, `registration-*.sh`, `{cloud,console}-path-escape-check.sh`,
`cloud/Dockerfile`, `cloud/.gitignore`. `bp-graph-drift.yml` and
`check-bp-graph-drift.sh` are absent — a numbered carve-out is required at Decide,
or those two members ship as pins instead of fixes.
