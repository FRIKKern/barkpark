# FunctionClauseError population LOCATED — wrong slot, right number (wave 32)

Date: 2026-08-09. Verifier: v2-functionclause-population-located.

## Finding

The lead's "33 of 299 trailing-24h 500s are one FunctionClauseError" is EXACT.
The earlier surveyor scanned `barkpark-slot@green`, which is NOT the live slot
on guerrilla. `systemctl list-units` shows only `barkpark-slot@blue.service`
active, and `/opt/barkpark/.instance-deploy-last` = `b03f3d8f…` = `origin/main`
tip. Green: 0 hits in 48h. Blue: 33 FunctionClauseError, 66 traverse_errors
lines, 24h 500 total = 299.

The trigger is NOT the stale `if_rev` precondition fence. Every one of the 33 is
the same tuple:

    Ecto.Changeset.traverse_errors({:invalid_epic_paper_quality, %{"failures" => [...],
      "tag" => "epic-cycle-wave-paper"}}, #Function<… changeset_field_errors/1>)

## Mechanism (origin/main)

`api/lib/barkpark/content/authoring_wall.ex:152` returns
`{:error, {:invalid_epic_paper_quality, details}}`.
`api/lib/barkpark_web/controllers/bulldocs_ingest_controller.ex` routes
`:label_spine` (197), `:invalid_paper_structure` (200), `:unknown_tag` (203),
`:duplicate_of` (206) to `render_error/2` — but has NO clause for
`:invalid_epic_paper_quality`, so it falls into the `{:error, changeset}`
catch-all at 209/278/337 → `invalid_paper_error/2` (906) →
`changeset_field_errors/1` (911) → `traverse_errors/2` on a bare tuple → crash.
The envelope ALREADY exists at `api/lib/barkpark/content/errors.ex:481`
(code `invalid_epic_paper_quality`, status 422). Fix = 3 routing clauses.

## Re-derivation

```sh
# population, by slot
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  "journalctl -u barkpark-slot@blue --since '24 hours ago' --no-pager | grep -c 'Sent 500'; \
   journalctl -u barkpark-slot@blue --since '24 hours ago' --no-pager | grep -c FunctionClauseError; \
   journalctl -u barkpark-slot@green --since '48 hours ago' --no-pager | grep -c FunctionClauseError"

# live repro (predicted 500, observed 500)
curl -s -w 'HTTP %{http_code}\n' -X POST https://guerrilla.barkpark.cloud/v1/plugins/bulldocs/papers \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $BP_TOKEN" \
  -d '{"slug":"wave32-fce-probe-e","title":"Wave 32 FunctionClauseError probe",
       "description":"<40+ chars>",
       "tags":[{"tag":"epic-cycle-wave-paper","strength":90,"rationale":"…"},
               {"tag":"deploy-reliability","strength":40,"rationale":"…"}],
       "blocks":[{"type":"paragraph","content":[{"type":"text","text":"body with no h1/ingress/orientation"}]}]}'
# → HTTP 500 {"error":{"code":"internal_error","message":"unknown error (FunctionClauseError)",…}}
```

Order matters in the repro: hollow-body halt (409) and label_spine (422) fire
BEFORE the epic-quality floor. A payload without a description or weighted tags
never reaches the crash — that is why naive probes return 409/422, not 500.

## Route mix (blue, 48h, POST lines within 30 lines above each crash)

70 `POST /v1/plugins/bulldocs/papers`, 22 `POST /v1/fleet/beat`,
2 `POST /v1/admin/site-deploy`, 1 `POST /v1/data/mutate/production`
(interleaved traffic; the crashing controller is bulldocs ingest in all 33).

## Cross-check

`api.barkpark.cloud` (cloud control plane, `barkpark-provisioner.service`):
0 FunctionClauseError, 0 traverse_errors in 48h across all units. The population
is guerrilla-only.

## Why it matters for the wave

This defect 500s the epic cycle's OWN wave-Paper publish whenever the paper
fails the epic quality floor — the operator sees "unknown error", not the
five named failures the wall already computed.
