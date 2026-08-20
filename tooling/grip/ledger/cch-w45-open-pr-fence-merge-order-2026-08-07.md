# cch-w45 — the open-PR fence: exact conflicts and a merge ORDER

Measured against `origin/main = b00d793c0e2065e98a03fed6c4356245d897ee3a` on 2026-08-07.
Every row below is re-derivable by the command in its `rerun` column. No repo state was changed.

## 1. Which of the four actually conflict with main

    cd /Volumes/SATECHI/github/barkpark
    for b in loop-epic/the-elevated-write-binding-census-gains--1 \
             loop-epic/the-role-ladder-census-derives-its-own-d-1 \
             loop-epic/one-condition-one-answer-the-two-primary-1-r \
             epic-charter/cloud-console-hardening-w44-20260807T090344Z; do
      git fetch origin $b -q; echo "== $b"
      git merge-tree --write-tree --name-only --messages origin/main FETCH_HEAD | grep -i conflict || echo "   clean"
    done

Result: ONLY #10085 conflicts. #10154, #9956, #10238 are all `MERGEABLE`, zero conflicting paths.

## 2. #10085's two conflicts, by hunk (not filename)

Reproduce the conflicted blobs:

    T=$(git merge-tree --write-tree origin/main origin/loop-epic/the-elevated-write-binding-census-gains--1 | head -1)
    git cat-file -p $(git ls-tree $T .github/workflows/console-harness.yml | awk '{print $3}') # (use `git merge-tree` output tree)
    # simpler: the conflicted content lives in the merged tree
    git cat-file -p $T:.github/workflows/console-harness.yml   | grep -n '^<<<<<<<\|^=======\|^>>>>>>>'
    git cat-file -p $T:cloud/priv/static/__binding_census.mjs  | grep -n '^<<<<<<<\|^=======\|^>>>>>>>'

Exactly ONE hunk per file.

### (a) `cloud/priv/static/__binding_census.mjs`, merged lines 157–196 — SEMANTIC, not context

Both sides rewrote the SAME argv-binding paragraph, and they disagree about what the
positional arguments MEAN.

- main side (post-#10161, check (2e)) added a FIFTH positional:
  `const AUTHZ = process.argv[5] || .../accounts/authz.ex;` plus
  `const CONTEXT_SOURCES = { Accounts: ACCOUNTS, Authz: AUTHZ };` and `MODULE_QUALIFIED`.
- branch side (#10085) redefined positional semantics: `--add-check`/`--remove-check` is
  argv[2], so in fixture mode argv[3]/argv[4] are the FLAG's operands and are force-defaulted
  (`(FIXTURE_MODE ? null : process.argv[3]) || …`). It knows nothing about argv[5].

So it is a real contract clash. It is BENIGN in effect, and that was measured rather than
assumed: the fixture block `process.exit()`s at branch lines 721/727, long before (2e) reads
`AUTHZ` at line ~653. A naive union that leaves `AUTHZ = process.argv[5]` unqualified behaves
identically on all five cells.

RESOLUTION (3 lines): keep the branch's whole block, then append main's three lines with
argv[5] given the same fixture null-binding for consistency:

    const AUTHZ = (FIXTURE_MODE ? null : process.argv[5]) || path.join(here, "../../lib/barkpark_cloud/accounts/authz.ex");
    const CONTEXT_SOURCES = { Accounts: ACCOUNTS, Authz: AUTHZ };
    const MODULE_QUALIFIED = /^([A-Z][A-Za-z0-9_]*)\.(.+)$/;

`const LABEL` auto-merges to the branch's form (`APP === path.join(here,"app.js") ? … : APP`)
because only the branch touched it — and that is the CORRECT side: main's
`process.argv[2] || "…"` would print `--add-check` as the subject label in fixture mode.

PROVEN, resolution built in a scratchpad and run on origin/main's own bytes:

    LIVE                      rc=0  (expect 0)
    --add-check add.fixture   rc=1  (expect 1)
    --remove-check rem.fixture rc=1 (expect 1)
    --remove-check add.fixture rc=0 (cross cell, expect 0)
    --add-check rem.fixture    rc=0 (cross cell, expect 0)

### (b) `.github/workflows/console-harness.yml`, merged lines 418–559 — PURE ADDITIVE

Both sides append new `- name:` steps to the SAME job, `console-unit`, immediately after
`Elevated-write binding census (ADD + REMOVE)`:

- main added: `Refusal reason-arm census …` and `/v1/me envelope census …`
- branch added: the three `Binding census fixture control — …` steps

Resolution = concatenate both sides, main's two first. Verified: stripping both markers and
keeping BOTH sides yields valid YAML with `console-unit` carrying all 16 steps in order.
No `.github/required-checks.json` edit is owed — `Console client unit harness` is an
S3-SUBSUMED leaf of the required `Console gate`, so the new steps reach the required context
without a new registered name.

## 3. #9956 does NOT move the bytes `FORBIDDEN_ROLE_COPY.admin` is asserted against

    git diff $(git merge-base origin/main origin/loop-epic/one-condition-one-answer-the-two-primary-1-r) \
      origin/loop-epic/one-condition-one-answer-the-two-primary-1-r -- cloud/lib/barkpark_cloud/web/auth.ex

The only CODE change in auth.ex is two lines, both in the `is_nil(conn.assigns[:current_team])`
clause of `require_primary_team_admin/1` (:421) and `require_primary_team_owner/1` (:454):

    -        json_halt(conn, 422, %{error: "no_team"})
    +        forbidden(conn, reason: "no_team", scope: "team")

The `required: "admin"` / `required: "owner"` arms are UNTOUCHED. `FORBIDDEN_ROLE_COPY.admin`
(app.js:243, "You need the admin role on this team — an admin on this team can grant it.")
is byte-unaffected. The new `reason: "no_team"` cause ALREADY has an arm —
`FORBIDDEN_REASON_COPY.no_team` at app.js:275 — so it cannot red the reason-arm census, and
that census's scope is router.ex only anyway (`__reason_arm_census.mjs` LIMIT 1, :56).

router.ex in #9956 is COMMENT-ONLY:

    git diff <mb> <head> -- cloud/lib/barkpark_cloud/web/router.ex | grep '^[+-]' | grep -v '^[+-][+-][+-]' | grep -v '^[+-]\s*#'
    # → empty

## 4. Does the 203-line FIXTURE_MODE insert shadow predicate handling?

Yes, in one way movement two MUST respect, and it is already written down as charter D460:
`--add-check`/`--remove-check` SHORT-CIRCUIT after `seenByKey` and before EVERY check
(2b)…(2f). Any new arm movement two adds after that point is FIXTURE-UNCONTROLLED — it ships
with no cell proving it can lose. To be controlled, movement two must also add its arm name to
`ARMS` / `IN_SCOPE` and give a fixture a `@must-flag`/`@must-clear` row for it.

Second interaction: #10085 hoists `verdictContrastLost` to module scope so the live (2d-ii)
and the fixture run ONE implementation, and RETIRES (2d)'s two DIRECTIONAL sub-clauses which
today demand `submitProviderCred` stay `predicate: null` forever. That freeze binds only
submitProviderCred — NOT D428's rail seven — so movement one on the rail does not trip it. Any
slice that predicates the launch-wizard provider button DOES trip it on today's main and must
land after #10085.

## 5. Pairwise (do they collide with each other?)

    for pair in "A B" "A C" "B C" "A D" "B D" "C D"; do … git merge-tree --write-tree --name-only --messages $x $y | grep -i conflict; done

    10085 x 10154   CONFLICT console-harness.yml        (inherited main-side content, same hunk as §2b)
    10085 x  9956   clean
    10154 x  9956   clean
    10085 x 10238   CONFLICT console-harness.yml + __binding_census.mjs  (inherited; #10238 is docs+ledger ONLY)
    10154 x 10238   clean
     9956 x 10238   clean

#10238 touches 6 files, all `.claude/workflows/…charter.md` + `tooling/grip/ledger/*.md`. Its
apparent collision with #10085 is entirely main-side content reached through an older
merge-base (`46b5373ed`), not its own edits.

## 6. THE ORDER

    1. #10238  (charter + ledger, docs-only, zero code collision — makes D492–D498 law
                so wave 45 can cite them instead of re-deriving them)
    2. #9956   (auth.ex + router.ex; comment-only router, 2-line auth; touches nothing
                any other PR in this fence touches; unblocks the refusal-byte premise)
    3. #10154  (adds Authz.admin_roles/0 + TeamMembership.ranked_roles/0 — the DERIVED
                accessors movement two must CONSUME rather than re-type)
    4. #10085  (LAST of the four, FIRST of the census work: it is the only conflicting PR,
                and every later census edit rebases onto it rather than the reverse)
    5. movement two — builds on #10085's resolved census AND #10154's accessors
    6. movement one — the rail-seven predicates

Justification for putting #10085 last-of-four but before both movements: it is the only PR
whose conflict has to be resolved by hand, and resolving it ONCE against a main that already
carries #9956/#10154/#10238 is strictly cheaper than resolving it first and then rebasing
three PRs across a 296-line census rewrite. #10154 must precede movement two or movement two
re-types the role ladder it exists to derive. #10085 must precede movement two or the fixture
short-circuit is discovered after the arm is written.

Already-filed dependency confirming this shape: `cch-w41-s5-the-binding-census-ratchets-instead-of-counting`
opens with "AFTER PR #10085 merges".
