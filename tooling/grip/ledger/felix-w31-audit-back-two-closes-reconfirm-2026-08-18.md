# Felix W31 — audit-back re-derivation: the two rows W30 already closed STAND

**Verdict:** Both `felix-w27-s6-12041-golden-contingency` and `felix-w29-bl-asset-schema-nil-redaction`
closes are SOUND from source. Do NOT reopen. The `D204` citation in the felix-w29 close is a
PROVENANCE gap (absent from origin/main; lives only on open PR #12147), not hollow evidence.

## Re-derive in one block

```sh
cd /Volumes/SATECHI/github/barkpark

# (1) #12041 merge commit + ancestry (golden-contingency close, charter D198)
git show -s --format='%H %ci %s' 71f06d6
git merge-base --is-ancestor 71f06d6 origin/main && echo ANCESTOR

# (2) Charter D198 covers the close; D202-D207 (incl. cited D204) ABSENT from main
git show origin/main:.claude/workflows/bp-felix-pristine-charter.md | sed -n '2666,2674p'
git show origin/main:.claude/workflows/bp-felix-pristine-charter.md | grep -cE 'D20[2-7]'   # => 0

# (3) Redaction correctness — the CORRECT reddening exemplar is the :internal sentinel,
#     NOT caller_context=nil (nil ALSO fails closed via %CallerContext{})
git show origin/main:api/lib/barkpark/content/envelope.ex | sed -n '145,162p'
git show origin/main:api/lib/barkpark/media/delivery/asset_response.ex | sed -n '108,126p'

# (4) both rows are lifecycle=done with full criteria
for id in felix-w27-s6-12041-golden-contingency felix-w29-bl-asset-schema-nil-redaction; do
  bp task get $id -o json | python3 -c "import json,sys;d=json.load(sys.stdin);doc=d.get('doc') or d;print('$id',doc.get('lifecycle_status'),doc.get('criteria_progress'))"
done
```

## Decisive outputs (2026-08-18)

- `71f06d62d5ccc5a1bd02efaec5e5e60ab5812581 2026-08-18 02:10:32 +0200 test(cycle_fleet,studio_chat): lock-wait mutation proofs for the two remaining authority-lock sites (#12041)` → `ANCESTOR`. (Charter says merged `2026-08-18T00:10:32Z` = same instant, UTC vs CEST.)
- Charter D198: "`felix-w27-s6-12041-golden-contingency` NOW CLOSES … #12041 merged … (mergeCommit 71f06d6), w19 closed 4s later." grep `D20[2-7]` => **0**.
- envelope.ex: `nil` caller → `redact_by_field_visibility(env, schema, %CallerContext{}, owner_id)` = **fails closed / redacts** (so nil is NOT a valid reddening mutation). `:internal` sentinel → `do: envelope` = **unredacted full content**, "Not reachable from any request path." => the reddening exemplar is asserting the request path never reaches `:internal`, exactly what the felix-w29 refutation used.
- asset_response.ex: `caller_context(conn)` = `CallerContext.from_conn` or `.anonymous` (`%__MODULE__{}`, most restrictive); `asset_schema` scoped to the doc's OWN tenant (`workspace_id`/`project_id` from the doc). Redaction boundary correct.
- `felix-w27-s6-12041-golden-contingency done {'met':3,'total':3}` · `felix-w29-bl-asset-schema-nil-redaction done {'met':2,'total':2}`.

## Provenance note (charter only, no reopen)

The felix-w29 close cites "wave-30 D204". origin/main charter tops at D201 (D202-D207 exist only on
open PR #12147). The refutation it rests on is independently source-confirmed (envelope.ex +
asset_response.ex above), so this is a citation-provenance gap, NOT grounds to reopen.
