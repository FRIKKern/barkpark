# dr-w2 verify — security-review arrangement + the leak's true shape (2026-08-06)

Re-derivation recipes. Every command reads `origin/main` or the live bp ledger; none needs a worktree.

## A. The reviewer clause: 3 open, 3 discharged — and the discharged form is NOT a GitHub review

```sh
# The three PERMANENTLY-OPEN rows (the unsatisfiable wording)
bp task get ssw10-public-read-clamp -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status']);[print(i,c['met'],c['criterion'][:120]) for i,c in enumerate(d['content']['acceptance_criteria'])]"
bp task get dr-w1-s1-graph-visibility-bound-readmit -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status'],d['content']['acceptance_criteria'][6]['criterion'])"
bp task get dr-bl-scoped-search-private-leak -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['content']['acceptance_criteria'][3]['criterion'])"

# The three DISCHARGED rows (the satisfiable wording) — read the EVIDENCE, not the criterion
bp task get pds-w43-caps-readonly-share-write-bypass -o json | python3 -c "import json,sys;c=json.load(sys.stdin)['doc']['content']['acceptance_criteria'][-1];print(c['criterion']);print(c['evidence'][:900])"
bp task get pds-w41-scim-crosstenant-pin -o json | python3 -c "import json,sys;c=json.load(sys.stdin)['doc']['content']['acceptance_criteria'][-1];print(c['criterion']);print(c['evidence'][:900])"
bp task get cch-w14-bl-independent-review-owed -o json | python3 -c "import json,sys;d=json.load(sys.stdin)['doc'];print(d['lifecycle_status']);[print(c['criterion'][:160],'||',c['evidence'][:400]) for c in d['content']['acceptance_criteria']]"

# The artifact the ONE fully-independent discharge produced
git ls-tree origin/main tooling/grip/ledger/ --name-only | grep independent-review
```

Verdict: `merged BY a reviewer who is not the author` (ssw10 c8) is unsatisfiable on this
fleet — `gh pr view 7870 --json reviews,reviewDecision` returns `[]`/`""` on a MERGED PR.
The satisfiable form, discharged 3/3, is: *a named non-author agent RE-DERIVES the judgment
from merged/origin bytes on a case the builder never drove, and RECORDS the derivation
(ledger file + task evidence); the LEAD closes the criterion.*

## B. The trap: mounting PublicRead on `:scoped_api` takes the live flagship dark

```sh
# 1. Where PublicRead is (and is NOT) mounted
git show origin/main:api/lib/barkpark_web/router.ex | grep -n 'PublicRead\|^  pipeline :'
# -> :api_grant_read (83), :shared_docs_api (187), :require_token (470). :scoped_api (141): NONE.

# 2. The scoped search routes ride bare :scoped_api
git show origin/main:api/lib/barkpark_web/router.ex | sed -n '2185,2196p'

# 3. The site BUILD credential is public-read AND its API URL is pre-scoped
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '710,720p'
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | grep -n 'defp scoped_api_url' -A 4
git show origin/main:js/packages/core/src/search.ts | sed -n '61p'   # scopePrefix(config) + /v1/data/search

# 4. Two committed sources already RULE the trap
grep -n 'D49 — LAND root cause' .claude/workflows/bp-search-template-charter.md
git show origin/main:api/test/barkpark_web/integration/public_read_search_matrix_test.exs | sed -n '12,16p'

# 5. Blast radius if mounted anyway: 21 routes sit on BARE :scoped_api (two scope blocks,
#    heads at router.ex:2185 and :2412) and only GET query/doc/graph are allow-listed.
git show origin/main:api/lib/barkpark_web/router.ex > /tmp/r.ex && python3 - <<'PY'
import re
src=open('/tmp/r.ex').read().split('\n'); i=0; tot=0
while i<len(src):
    if src[i].startswith('  scope '):
        j=next((k for k in range(i+1,min(i+6,len(src))) if 'pipe_through' in src[k]), None)
        if j and src[j].strip()=='pipe_through(:scoped_api)':
            k=j; n=0
            while k<len(src) and src[k]!='  end':
                if re.match(r'\s*(get|post|put|patch|delete)\("',src[k]): n+=1
                k+=1
            print(i+1, n); tot+=n
    i+=1
print('TOTAL', tot)
PY
```

## C. The leak is keyed on AUTH, and the permission is already in hand

```sh
git show origin/main:api/lib/barkpark/search/documents_retriever.ex | sed -n '320,335p'
git show origin/main:api/lib/barkpark/content/caller_context.ex | sed -n '49,58p'   # roles: perms
git show origin/main:api/lib/barkpark_web/controllers/search_controller.ex | grep -n 'CallerContext.from_conn'
git show origin/main:api/lib/barkpark_web/anon_perspective.ex | sed -n '66,71p'     # the copy, not an invention
```

`CallerContext.from_token/1` already stores the token's permission list as `roles`, and
`SearchController` already threads it. Clamping public-read inside
`restrict_anonymous_to_public_types/3` needs NO new plumbing and NO route change.

## D. The tier ladder has TWO rungs, not three — and the mint route is NOT public

```sh
git show origin/main:api/lib/barkpark_web/router.ex | sed -n '2349,2354p'   # pipe_through([:scoped_api, :scoped_admin])
git show origin/main:api/lib/barkpark_web/controllers/token_controller.ex | sed -n '1,30p'
```

`restrict_anonymous_to_public_types/3` matches `principal_type in [:api_token, :user]` with no
permission test, so the bypass begins at the FIRST rung above anonymous: a plain `{read}`
token behaves identically to `{admin}` there. That is by design (`query_controller.ex:640
authed?` admits any token), so the defect is exactly and only the public-read tier.
Minting a `{read}` token to "find the boundary" measures a constant.
Separately: `public_read.ex`, `anon_perspective.ex` and site-spawner D106 all describe the
`~w(public-read read)` mint as riding a **PUBLIC** route. On origin/main it rides
`[:scoped_api, :scoped_admin]` = RequireToken + RequireWorkspaceRole. The membership-not-equality
fix stays right; its stated threat model does not.
