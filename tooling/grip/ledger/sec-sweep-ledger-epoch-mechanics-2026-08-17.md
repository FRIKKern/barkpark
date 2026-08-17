# Re-derivation recipes — security sweep ledger/epoch mechanics (2026-08-17)

Verifier lane `ledger-epoch-mechanics`, wave `api-read-path-security-sweep-wave-2026-08-17`.
Every row is a literal command that re-derives the fact from scratch. No repo state is assumed.

## R1 — the five tasks: lifecycle, claim, criteria count

```
for t in stw10-backlog-drafts-id-seam task-d223068f55efbf47 task-758ef042eb60c65e pdf-bl-anon-read-exposure ssw8-bl-public-read-reaches-export-analytics-listen; do echo "== $t"; bp task get $t -o json 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin)["doc"];print(d["lifecycle_status"],"claim=",json.dumps(d.get("claim")),"criteria=",len((d.get("content") or {}).get("acceptance_criteria") or []))'; done
```

Expected 2026-08-17: all five `open`; `claim=null` on four; task-758 carries a RELEASED
claim record (`worker: null`, `expired_at` set, `epoch: 2`) and `criteria=0`.

## R2 — a fresh claim gets epoch 3 on task-758 (the epoch-2 record is not reusable)

```
git show origin/main:api/lib/barkpark/tasks/claim.ex | sed -n '285,290p'
git show origin/main:api/lib/barkpark/tasks/internal.ex | sed -n '20,21p'
```

`next_epoch = current_epoch(doc) + 1`, and `current_epoch` reads `content.claim.epoch`
(0 when absent). A released record keeps its epoch in the doc, so the next claim is 3.

## R3 — the work-digest fence: editing criteria under a claim breaks close

```
git show origin/main:api/lib/barkpark/tasks/close.ex | sed -n '500,535p'
```

`check_work_digest/2` re-digests title + brief + description + acceptance_criteria in the
close txn and compares to the claim-time stamp → `{:error, {:doc_changed_since_claim, rev,
changed_fields}}`. Escape hatch: an explicit `observed_rev` bypasses the check.
Consequence: author/requalify criteria BEFORE claiming.

## R4 — a zero-criteria task closes `done` with no proof

```
git show origin/main:api/lib/barkpark/tasks/close.ex | sed -n '449,460p'
```

`check_criteria_proven` passes on an empty unmet list. task-758 (0 criteria) would close
green while proving nothing.

## R5 — the revoke route exists on main, and what it accepts

```
git show origin/main:api/lib/barkpark_web/router.ex | grep -n 'app-tokens'
git show origin/main:api/lib/barkpark_web/controllers/app_token_controller.ex | grep -n 'def delete' -A 20
git show origin/main:api/lib/barkpark/auth.ex | sed -n '253,260p'
```

`DELETE /v1/auth/app-tokens` (admin bearer, body `{"token": raw}`) and
`DELETE /v1/auth/app-tokens/current` (self-revoke, possession is authorization) both exist.
Lookup is `token_hash == hash and kind == "api"` — NOT limited to `bpapp_` tokens, so a
`bp token create` public-read token is revocable this way. Admin-carrying tokens are 422 on
both paths.

## R6 — there is no `bp` CLI verb for token revoke

```
bp capabilities -o json | python3 -c 'import json,sys
for r in json.load(sys.stdin)["commands"]:
  if "revoke" in (r[1] or "") or "token" in (r[0] or ""): print(r[0], r[1], "| auth:", r[3])'
```

Yields `token create` (auth: scoped_admin), `media revoke-share`, `access revoke`,
`ticket-key revoke` — no app-token revoke. ssw8's teardown must be raw curl.

## R7 — public-read is route-clamped, so d223 criterion 1 is unreproducible as written

```
git show origin/main:api/lib/barkpark_web/router.ex | grep -n 'pipeline :require_token' -A 12
git show origin/main:api/lib/barkpark_web/plugs/public_read.ex | sed -n '148,164p'
```

`/v1/graph/*` rides `[:api, :require_token]`, which mounts `PublicRead`; `allowed_route?/1`
admits the EXACT two-segment `["v1","graph"]` only, and `allowed_perspective?/1` admits
`nil | "" | "published"`. A public-read token on `/v1/graph/:id?perspective=drafts` is a
403 at the route, twice over.
