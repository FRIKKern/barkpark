# Re-derivation recipe — Cloud Console Hardening wave 12, duplicate-collapse ruling (2026-07-31)

Verify lane `duplicate-collapse-ruling`. Run from repo root in the SHARED checkout.
Every command reads `origin/main` or the live server — never a worktree.
Server: `https://guerrilla.barkpark.cloud`. Token from `~/.config/barkpark/config.json` key `token`.

```sh
TOKEN=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/barkpark/config.json')))['token'])")
```

## 1. The 13 family rows — criteria verbatim + lifecycle + status

```sh
for t in gr-bl-doneset-merge-sha-reaudit cch-bl-thirtyone-done-rows-cite-branch-shas \
         cch-w11-bl-doneset-branch-sha-delta-reconcile \
         gr-backlog-css-brace-detector drafts.gr-backlog-css-brace-detector \
         cch-w11-s1-flip-behind-a-generator-that-cannot-lose \
         drafts.cch-w11-s1-flip-behind-a-generator-that-cannot-lose \
         cch-bl-webhook-delete-oracle-needs-real-card cch-bl-webhook-delete-oracle \
         gr-blk-cssom-parity-harden gr-backlog-cssom-parity-count-skew \
         cch-bl-cssom-count-skew-is-advisory-only \
         drafts.cch-bl-floor-blind-to-readme-and-uncalled \
         cch-bl-orphan-draft-floor-blind-row \
         cch-w11-residue-floor-is-not-a-ci-gate-on-the-spec-diff \
         cch-bl-security-gate-shim-and-register \
         cch-w11-residue-security-gate-registration-policy; do
  bp task get "$t" -o json
done
```

Read from each: `.doc.doc_id`, `.doc.status`, `.doc.lifecycle_status`, `.doc.criteria_progress`,
`.doc.content.acceptance_criteria[].criterion`, `.doc.content.acceptance_criteria[].met`.
`published_at` is NOT a field on this response; **`status` is the publication oracle**
(`published` vs `draft`), and a draft carries no `published_at` at all.

## 2. The orphan draft has NO published twin — proven two ways

```sh
bp task get cch-bl-floor-blind-to-readme-and-uncalled -o json | python3 -c \
  "import json,sys;d=json.load(sys.stdin)['doc'];print(d['doc_id'],d['status'],'published_at' in d)"
# -> drafts.cch-bl-floor-blind-to-readme-and-uncalled draft False
#    (the BARE id resolves to the DRAFT: bp task get is published-first, so a published
#     twin would have won. It did not exist to win.)

curl -sG https://guerrilla.barkpark.cloud/v1/data/query/production/task \
  --data-urlencode 'filter[_id]=cch-bl-floor-blind-to-readme-and-uncalled' \
  -H "Authorization: Bearer $TOKEN" | python3 -c \
  "import json,sys;print(len(json.load(sys.stdin)['result']['documents']))"
# -> 0
```

Publish-wall inputs (D86 proved an untagged row 422s `label_spine` on republish):

```sh
bp task get drafts.cch-bl-floor-blind-to-readme-and-uncalled -o json | python3 -c \
  "import json,sys;c=json.load(sys.stdin)['doc']['content'];print(c['main_tag'],[t['tag'] for t in c['tags']],bool(c.get('description')))"
# -> honest-gates ['honest-gates', 'testing', 'infra'] True     (spine present: publishable)

bp doc publish task drafts.cch-bl-floor-blind-to-readme-and-uncalled --dry-run
# -> {"mutations":[{"publish":{"id":"drafts.cch-bl-floor-blind-to-readme-and-uncalled","type":"task"}}]}
```

## 3. Drafts are invisible to the seal predicate — publishing COSTS +1 live row

`seal-predicate.mjs` reads the roster with `fetchRoster` (`:346`), which is the same query below.
Run it and compare against `bp task get cloud-console-hardening-epic`.

```sh
curl -sG https://guerrilla.barkpark.cloud/v1/data/query/production/task \
  --data-urlencode 'filter[parent_id]=cloud-console-hardening-epic' \
  --data-urlencode 'limit=500' -H "Authorization: Bearer $TOKEN" | python3 -c "
import json,sys,collections
docs=json.load(sys.stdin)['result']['documents']
print('n',len(docs),collections.Counter(d['lifecycle_status'] for d in docs))
print('drafts.* in predicate roster:',[d['_id'] for d in docs if d['_id'].startswith('drafts.')])"
# -> n 184 Counter({'open': 88, 'done': 81, 'cancelled': 14, 'considering': 1})
# -> drafts.* in predicate roster: []
```

`bp task get cloud-console-hardening-epic` reports 189 children / open 91 / cancelled 16.
189 − 184 = 5 = the five `drafts.*` children (3 open + 2 cancelled). So:

* discarding the two D86 shadow drafts buys **ZERO** live-row reduction against the predicate;
* publishing the orphan draft **RAISES** the predicate's live count 88 → 89.

## 4. Free-close evidence, by content, on origin/main

```sh
# gr-bl-doneset-merge-sha-reaudit AC3 — "a standing rule is written into the owning charter"
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '25,30p'
# -> "1. **Cite MERGE SHAs, never branch SHAs.** ..."   (law 1 already exists)

# cch-bl-thirtyone AC2 — the TWO extra sentences (content anchor / stale-citation) are NOT there.
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md \
  | sed -n '24,32p' | grep -c 'content anchor'      # -> 0

# cch-bl-thirtyone AC3 — no committed recipe reproduces the 242/192/50 census
git grep -l 'NOT-ANCESTOR' origin/main -- tooling/grip/ledger/ scripts/
# -> only cch-w6-movement0-second-sweep-2026-07-28.md (a FIVE-sha wave-6 check) and one grip json

# cch-bl-security-gate-shim-and-register AC1/AC2/AC3 — paid on main
git show origin/main:api/mix.lock | grep -n '"req"'                    # -> :58  req 0.6.3
git show origin/main:.github/workflows/security.yml | grep -n 'paths:' # -> no workflow-level on:*:paths
git show origin/main:.github/workflows/security.yml | sed -n '474,477p'
# -> name: Security gate / if: always() / needs: [changes, gate-shape, sobelow-inline-overlap, mix-audit]
git show origin/main:.github/workflows/security.yml | sed -n '215,221p'
# -> the `sobelow` job carries continue-on-error: true and is ABSENT from that needs list
```

## 5. The two D86 shadow drafts carry no unique content

```sh
# criterion text identical on every index; only github.synced_rev/fingerprint differ,
# and the w11 draft is STALE-POORER (0/13 met vs the published row's 9/13).
for p in gr-backlog-css-brace-detector cch-w11-s1-flip-behind-a-generator-that-cannot-lose; do
  for id in "$p" "drafts.$p"; do
    bp task get "$id" -o json | python3 -c "
import json,sys;d=json.load(sys.stdin)['doc']
print(d['doc_id'],d['status'],d['criteria_progress'],
      [a['met'] for a in d['content']['acceptance_criteria']])"
  done
done
```

Disposal verb is `bp doc discard-draft task <published-id>` (D105 precedent, executed once on
`drafts.gr-bl-delivery-keyset-tiebreak` with the published row verified unchanged).
NEVER `bp doc delete` — D86: it orphans the GitHub issue.

## 6. Verb surface (why the disposal shapes are what they are)

```sh
bp task --help          # there is NO `cancel` verb: "kills go through close (→ cancelled)"
bp task close --help    # usage: close <doc_id> <worker_id> <observed_epoch> [lifecycle_status] [reason]
                        # `cancelled` is the 4th positional; `reason` persists as content.close_reason
bp doc --help | grep -i draft   # discard-draft / publish / unpublish
```
