<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-23 | budget: 2100tok -->
# Restart Verify 23 — capability, schema, OpenAPI, and CLI agreement

Assignment `restart-verify-23` compared the deployed capability manifest, Paper schema, OpenAPI/router, CLI manifest/help, live envelopes, and pagination behavior. Verdict: **refuted**. Route/auth parity is strong, but machine schema, discovery, negotiation, pagination, error, and checked-in fixture drift decisively break whole-contract agreement.

| Measure | Observed |
|---|---:|
| Flat capability route+method in OpenAPI | 150/150 |
| Scoped route+method in OpenAPI | 46/46 |
| Capability auth tier equals OpenAPI scope | 150/150 |
| Exact operation ID identity | 125/150 |
| Paper schema block coverage | 0/815 |
| Paper schema variant coverage | 0/5 |
| Runtime source routes | 4/4 |
| Source routes in capabilities/OpenAPI | 0/0 |
| Clean source Accept cells | at most 4/16 |
| Declared pagination behaving across offsets | 6/7 |
| Missing-source canonical envelope | 0/1 |
| Checked-in/live manifest commands | 142/150 |

The deployed guerrilla release was 0.2.25, version 0.2.25.2450, commit `b73723b7e`, built 2026-08-06T03:18:22Z. The admin manifest exposed 150 commands and 25 nouns. The 25 operation-ID differences are canonical-route aliases such as `doc.ls`/`doc.query`, and repository parity tests intentionally compare distinct method+path; they are not counted as defects.

The live Paper schema has seven metadata fields but no `blocks`, `body`, PortableDoc, or reader dialect. The four frozen sources contain 815 blocks across five variants, 388 marks, 46 tables, and 30 callouts. Live OpenAPI has Document and Error components but no PortableDoc/block/table/callout/mark components. It also omits the working `/papers/:slug/source` route and its own discovery endpoints.

Source negotiation returned JSON for wildcard 4/4 and mislabeled JSON for `text/html` 4/4; `application/json` and vendor JSON each returned 406 `internal_error` 4/4. Missing source returned plain `not found`, not the canonical Error envelope. `ticket.inbox` advertises limit/offset/all, yet limit-one offsets zero and one returned byte-identical content and the same ticket ID; its controller ignores offset. Six other observed paginated commands changed correctly.

The checked-in full-manifest fixture is missing eight live commands and differs on fourteen `writes` flags. No valid help-completeness denominator was established, so no help claim is made. Selected parser/manifest tests passed 11/11 and CLI tests passed 9/9 with `CGO_ENABLED=0`; the host-cgo attempt failed before testing. Elixir tests were unavailable because `api/deps` and `api/_build` were absent.

Evidence includes `/private/tmp/restart-verify23-caps-admin-build.json` SHA-256 `88739357c6877e9416a2481403b65616d2a228786e554f17c9d1bac09629b1de`, OpenAPI SHA-256 `098ab83389a927d9bd6144d98449290ace0ee0741ac34001897558151f4804ad`, checked-in full-manifest SHA-256 `fe346188bc2cbb7db3e7b122ea53415e3d8999d4b3aaedb1da8784b7d2d5d20c`, and combined source-body SHA-256 `8dd41654af74368099a267facbcf0674280757f8b7522dc635a375cfd420ae0c`. Mutations were zero; credentials were not printed; repository status remained clean at `f34d6d9e0f3a3ba16f2e0338da1520a84c02b29c`.

## Cycle payload

```json
{"assignment_id":"restart-verify-23","assignment_uuid":"0b7dd93e-7fcd-4f42-8e49-b7d1e828bdb8","verdict":"refuted","route_method":{"flat":"150/150","scoped":"46/46"},"auth_scope":"150/150","paper_schema":{"blocks":"0/815","variants":"0/5","tables":"0/46","marks":"0/388","callouts":"0/30"},"source_discovery":{"capabilities":0,"openapi":0,"runtime":"4/4"},"accept":{"clean_at_most":"4/16","application_json":"0/4"},"pagination":{"semantic":"6/7","ticket_inbox":"0/1"},"source_error_envelope":"0/1","fixture":{"live":150,"fixture":142,"missing":8,"writes_drift":14},"tests":{"manifest":"11/11","cli":"9/9"},"mutations":0}
```
