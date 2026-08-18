<!-- doc-tier: cold | canonical-for: connectors-sweep-a-rerun-recipe | budget: 800tok -->

# Connectors done-set SWEEP A (merge-ancestry) — re-derivation recipe

Wave: bp-connectors-wave-2026-08-18 · assignment sweep-a-rerun · read-only audit.
origin/main pinned = `e21bf409893d9de66542a31b06716e3c33d8f102`.

## Denominator (109 done, NOT child_count 157)

    bp task get task-e640bb01fca6ea38 -o json \
      | python3 -c "import json,sys,collections;d=json.load(sys.stdin);print(collections.Counter(c['lifecycle_status'] for c in d['children']))"
    # => done 109 / cancelled 15 / open 17 / considering 16 ; 109 unique doc_ids

The 109th row `connectors-wave-37-log` is a `while read` trailing-newline artifact when
looping a newline-joined id list (last line has no \n) — fetch it explicitly.

## Extraction (method distinct from survey regex)

Fetch all 109 done docs (`bp task get <id> -o json`), then walk the full JSON leaf tree
of content+claim+title+status and collect `#NNNN`/`pull/NNNN` PR refs and 7-40 hex tokens.

- 68 distinct PR-number tokens.
- 6 are mirrored task ISSUES, not PRs: 3157 3197 3200 3239 3558 3946
  (`gh pr view` GraphQL "Could not resolve to a PullRequest"; `gh issue view` resolves).
  Every one of the 12 rows citing an issue ALSO cites a real ancestor PR → zero rows rest on an issue.
- 62 real PRs. Partition: 104 rows cite >=1 real PR + 5 rows cite only commit SHAs = 109 (the "104-vs-103" is method rounding; 104 is exact).

## Ancestry test

    for n in <62 real PR numbers>; do gh pr view $n --repo FRIKKern/barkpark --json state,mergeCommit; done
    # all 62 state=MERGED, all have mergeCommit.oid
    for oid in <62 merge commits>; do git merge-base --is-ancestor $oid origin/main && echo ANC; done
    # => 62/62 ANCESTOR, 0 not-ancestor, 0 PR-HEAD miss, 0 missing object

## The trap (measure both directions)

5 SHA-only rows cite abbreviated commit SHAs that are NON-ancestor of main:
6f3439528, a95ad8d78, d21e3d85a, df45d000a (16033556b unknown to local db).
A naive ancestry sweep would manufacture 4 false reopens. Their CONTENT landed via
squash/charter-splice — confirmed on origin/main:

    git show origin/main:connectors/package.json | grep vitest      # "^4.1.10"
    git ls-tree origin/main connectors/ | grep -E 'package.json|tsconfig|vitest.config'  # one each
    git show origin/main:.claude/workflows/bp-connectors-charter.md | grep -c "Wave 17"  # >0
    git ls-tree -r origin/main --name-only | grep credential-cipher # present

These rows STAY done (two-lane / SHA-provenance, not ancestry).

## Verdict

SWEEP A false-done count = 0. Backbone claim (code LANDED) holds at 100%.
