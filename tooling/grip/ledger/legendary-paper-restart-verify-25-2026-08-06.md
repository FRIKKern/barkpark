<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-25 | budget: 2100tok -->
# Restart Verify 25 — Paper reader content negotiation

Assignment `restart-verify-25` ran the frozen 144-cell source/public/email Accept matrix over four Papers with present, missing, and unsupported controls. Verdict: **refuted**. Only 44/144 cells meet endpoint-native representation plus explicit missing/unsupported rules; 100/144 fail.

| Measure | Observed |
|---|---:|
| Complete cells | 144/144 |
| Contract-pass cells | 44/144 |
| Present-resource pass | 20/72 |
| Missing-resource 404 | 24/72 |
| HTTP 200 / 404 / 406 | 24 / 24 / 96 |
| Transport status 000 | 0 |
| Nonempty unique request IDs | 144/144 |
| Frozen revision/block checks | 4/4 |

The source route accepts wildcard and returns its native JSON 4/4, but explicit `application/json` and vendor JSON each fail 4/4 with HTTP 406 `internal_error`. Explicit `text/html` returns HTTP 200 `application/json` 4/4. All 24 present-and-missing unsupported cells return 406, but every body is coded `internal_error`; across the entire matrix all 96 responses with status 406 carry that incorrect code.

Negotiation also precedes resource resolution: only 24/72 missing controls remain 404, while 48/72 become 406. Therefore missing-resource identity is not representation-independent, and unsupported media is not reported with a negotiation-specific error taxonomy.

All four positive source controls retained the frozen document revisions and exact block counts: CCH28 237, CCH29 252, PDS44 99, and PDS45 227. The route seam is shared: all three flat readers are `public_root` routes under the browser pipeline, whose accepted format is HTML, while the source controller always emits JSON. Existing source/email tests use default or absent Accept headers and contain no six-value Paper negotiation matrix.

The denominator is the second complete run. An initial attempt stopped at 85/144 on a curl transport nonzero and is retained but excluded; the final harness records transport failures as status 000 without hidden retries. Scope is the required live remote flat routes, not HTTP/1.1 or scoped/dataset variants. The JSON/vendor source expectation is supported by the JSON controller and repository vendor-API convention, but the explicit unsupported and missing clauses independently refute the claim.

Evidence root is `/private/tmp/bp-restart-verify25.e0IlNp`. Matrix SHA-256 is `1b2367e4f9dfbc8896f858c25f839be8120439b42652f62ec6ceb60509b233b2`; breakdown SHA-256 is `6d76e263d99b271b4fa05c3eb341fa0f5dd413db2bae1a284c1048e0e3cba619`; result SHA-256 is `b4747e7216436f8d6df89d99b54701d47e1fe7f4f90556ab7d4217e08977e71b`; checksum-manifest SHA-256 is `f7ad7ad23110d1d9d58cfe774be32c8780a87e63f530f7683304864ed2dbf805`. Only GETs ran, Paper identity manifests were byte-equal before/after, and the repository remained clean at `903b0ebc012dbdc17820042637412a84c2db8dbe`.

## Cycle payload

```json
{"assignment_id":"restart-verify-25","assignment_uuid":"ff00f4ce-ef46-4353-b32d-fbd5319820bf","verdict":"refuted","cells":{"planned":144,"completed":144,"passed":44,"failed":100,"present_pass":"20/72","missing_404":"24/72"},"statuses":{"200":24,"404":24,"406":96,"000":0},"request_ids":{"nonempty":144,"unique":144},"source":{"json_200":"0/4","vendor_200":"0/4","html_as_json":"4/4","wildcard_json":"4/4"},"unsupported":{"status_406":"24/24","internal_error":"24/24"},"all_406_internal_error":"96/96","frozen_identity":"4/4","mutations":0,"matrix_sha256":"1b2367e4f9dfbc8896f858c25f839be8120439b42652f62ec6ceb60509b233b2"}
```
