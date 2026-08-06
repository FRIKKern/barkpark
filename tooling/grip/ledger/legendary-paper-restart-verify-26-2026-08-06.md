<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-26 | budget: 2100tok -->
# Restart Verify 26 — perspective and authorization separation

Assignment `restart-verify-26` ran 129 live observations across anonymous, invalid-token, admin-bearer, and browser actors; valid, invalid, and missing perspectives; production and invalid datasets; private history; and Studio redirects. Verdict: **refuted**. Invalid perspectives silently select published content instead of rejecting.

| Measure | Observed |
|---|---:|
| Matrix observations | 129 |
| HTTP 200 / 302 / 401 / 404 / 5xx | 101 / 8 / 8 / 12 / 0 |
| Invalid perspectives accepted / rejected | 24 / 0 |
| Admin invalid-perspective document rejected | 0/4 |
| Anonymous public clamp | 24/24 |
| Anonymous/invalid private history denied | 4/4 + 4/4 |
| Admin private history allowed | 4/4 |
| Invalid dataset avoided production substitution | 12/12 |
| Studio login redirects | 8/8 |

All 24 invalid-perspective document/source requests returned 200. The decisive admin document controls selected the exact published revision and blocks 4/4. This joins the implementation: `AnonPerspective.resolve/2` passes authenticated input to `parse/1`, while `parse/1` maps every unrecognized value to `:published`; an existing test explicitly expects `parse("garbage") == :published`.

Legitimate `published`, `drafts`, and `raw` requests on anonymous public document/source routes yielded one semantic hash per Paper/surface across all three values, proving clamp-to-published 24/24. Invalid credentials on these public reads also behaved anonymously 32/32, consistent with `OptionalToken`. Private history correctly denied anonymous and invalid-token actors and allowed admin. Invalid datasets returned 404 in all twelve document controls with no selected ID/revision.

Studio returned 302 to `/login` for anonymous, invalid bearer, valid admin bearer, and invalid browser cookie; all eight redirects preserved the requested dataset in `return_to`. A bare API bearer therefore does not establish the LiveView browser session. No positive valid-session cell ran because minting/login would create external session state; this remains a bounded gap rather than a substituted pass.

Content, Tasks, Papers, Cycle, and tracked repository files were not mutated. Literal zero server-row mutation is unprovable because authenticated `RequireToken` GETs call `Auth.touch_last_used/1`; this credential metadata side effect is explicitly carried. Credential values occurred in zero evidence files, response cookies were redacted, HEAD remained `903b0ebc012dbdc17820042637412a84c2db8dbe`, and tracked/staged diff stayed clean.

Evidence root is `/private/tmp/bp-restart-verify26.RigGnC`. Matrix SHA-256 is `3efc23a01a342eda0008126b22c85a7abfadaffd6fa7c1798ed4d1c4d7deff86`; canonical-table SHA-256 is `07b750bfe7e49641e47b4e5d4dab3087c67c497cc6041b84d28713726bc365e0`; document-semantics SHA-256 is `c01dc0335bf58175a26fd099c1276eced736ec081e96b1ee889d873253df7175`; source-semantics SHA-256 is `e38ce8af9106d30d3db675db661667eeca76235dfb8eceb0a00adac3c171696b`; Studio-redirect SHA-256 is `b62b052401a1a06e9b287a42466a3f9ebe11e55e4f940648944dc8fcfbdccfac`.

## Cycle payload

```json
{"assignment_id":"restart-verify-26","assignment_uuid":"911a72f0-2070-4e56-871d-c5ab10731150","verdict":"refuted","observations":129,"statuses":{"200":101,"302":8,"401":8,"404":12,"5xx":0},"invalid_perspective":{"accepted":24,"rejected":0,"admin_document_rejected":"0/4"},"anonymous_public_clamp":"24/24","private_history":{"anonymous_denied":"4/4","invalid_token_denied":"4/4","admin_allowed":"4/4"},"invalid_dataset_no_substitution":"12/12","studio_login_redirect":"8/8","content_task_paper_cycle_mutations":0,"tracked_repo_mutations":0,"literal_server_row_zero_mutation":"unprovable_due_token_last_used_touch","matrix_sha256":"3efc23a01a342eda0008126b22c85a7abfadaffd6fa7c1798ed4d1c4d7deff86"}
```
