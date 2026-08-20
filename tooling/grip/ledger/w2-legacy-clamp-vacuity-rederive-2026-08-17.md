# legacy-clamp-vacuity — re-derivation recipes (wave 2, 2026-08-17)

Claim set: the missing drafts-id clamp in LegacyController.show is behaviourally
INERT for every anon-pinned caller (anon → 401, public-read token → 403 upstream),
so an HTTP-level regression test of the clamp is vacuous; and no test pins
public-read=403 on /api/documents.

| # | claim | rerun |
|---|-------|-------|
| 1 | Anon /api/documents/paper is 401 on primary, guerrilla, muscle-1 | `for h in http://89.167.28.206 https://guerrilla.barkpark.cloud https://muscle-1.barkpark.cloud; do echo -n "$h "; curl -s -o /dev/null -w '%{http_code}\n' -m 20 $h/api/documents/paper; done` |
| 2 | /api/documents GET reads ride [:api, :require_token, LegacyDeprecation] — one mount only | `git show origin/main:api/lib/barkpark_web/router.ex \| grep -n -A5 'get("/documents/:type"'` |
| 3 | :require_token = RequireToken THEN PublicRead (two plugs before controller) | `git show origin/main:api/lib/barkpark_web/router.ex \| sed -n '479,489p'` |
| 4 | PublicRead allowlist = /v1/data/query, /v1/data/doc, /v1/graph exactly; /api/documents falls to the 403 catch-all (data_path strips only the ["w",ws,"p",proj] prefix, never "api") | `git show origin/main:api/lib/barkpark_web/plugs/public_read.ex \| sed -n '145,195p'` |
| 5 | LegacyController.show passes the raw id to Content.get_document — no anon_pinned?/drafts. check | `git show origin/main:api/lib/barkpark_web/controllers/legacy_controller.ex \| sed -n '51,56p'` |
| 6 | The v1 clamp being ported: anon_pinned? AND drafts.-prefix → :not_found, in QueryController.show | `git show origin/main:api/lib/barkpark_web/controllers/query_controller.ex \| sed -n '363,382p'` |
| 7 | anon_pinned? covers tokenless + public-read tokens (membership), NOT plain read tokens | `git show origin/main:api/lib/barkpark_web/anon_perspective.ex \| sed -n '53,60p'` |
| 8 | NO test pins public-read=403 on /api/documents (enforcement test's @leak_routes are /v1/data only) | `git show origin/main:api/test/barkpark_web/integration/public_read_enforcement_test.exs \| grep -n 'api/documents' \|\| echo 'NO /api/documents case pinned'` |
| 9 | Drafts-by-id DOES resolve through the legacy route for a non-pinned token (admin 200 on drafts.lc-show-1) — the clamp port must not break this | `grep -n 'drafts.lc-show-1' api/test/barkpark_web/integration/legacy_crud_test.exs` |
| 10 | Token mint is :scoped_admin-gated (POST /w/:ws/p/:proj/v1/tokens) — an action-level test mints in-suite, like public_read_enforcement_test's mint! | `git show origin/main:api/lib/barkpark_web/router.ex \| sed -n '2388,2391p'` |

Verdict recipe: a test that can red on clamp removal must inject the public-read
token BELOW PublicRead — action-level (LegacyController.show with
assigns[:api_token] = minted public-read token) or bypass_through — because the
router path 403s at the plug regardless of the controller body. The missing 403
tripwire (public-read on /api/documents) is a separate, HTTP-provable test worth
adding to public_read_enforcement_test.
