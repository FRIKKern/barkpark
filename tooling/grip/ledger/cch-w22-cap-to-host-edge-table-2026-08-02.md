# cch-w22 — the (cap, DOM host) EDGE table: re-derivation recipes

Every row below is re-derivable from `origin/main` with the quoted command. No dev server, no browser.
The point: a FAMILY key under-reaches. `.fleet-name` hosts three caps from three schemas; `.set-row-name`
hosts three from three. The ledger must be keyed on the EDGE (cap-site → render-site), not the host.

## A. The cap census, and why `grep validate_length` is not it

    git grep -n 'validate_length' origin/main -- 'cloud/lib/'          # 32 hits
    git show origin/main:cloud/lib/barkpark_cloud/registry/site.ex | sed -n '430,440p'

`site.domains` has NO `validate_length`. Its cap is **253**, enforced by `validate_change` at
`site.ex:432-436` (`String.length(d) <= 253 and Regex.match?(@domain_format, d)`), with the character
class pinned by `@domain_format` at `site.ex:28`. A `validate_length` census misses it entirely.

## B. Effective cap = min(validate_length, column width, downstream derivations)

    git grep -n ':comment\|pinned_release' origin/main -- 'cloud/priv/repo/migrations/'

`add :comment, :string` (`20260701120400_create_env_vars.exs:29`) = varchar(255) against
`validate_length(:comment, max: 1000)`. Effective cap 255, not 1000.
`add :pinned_release, :string` (`20260707110000_add_autoupdate_to_barkparks.exs:20`) = varchar(255)
against max 255 → effective 255, ADMISSIBLE.

## C. The six unlocated caps — resolution recipes

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '8371,8430p'   # barkpark_json
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '10089,10125p' # site_json
    for f in template fleet_token_id vercel_project_id github_branch doc_type pending_email pinned_release; do
      echo "== $f"; git show origin/main:cloud/priv/static/app.js | grep -n "$f"; done
    git grep -n 'fleet_token_id\|vercel_project_id\|pending_email\|vercel_deploy_url' origin/main -- 'cloud/priv/static/'

- barkpark.template 255 — NOT in `barkpark_json`; serialized ONLY on the worker claim payload
  (`router.ex:9900 template: barkpark.template`), worker-token channel. NEVER RENDERED.
- fleet_token_id 255 — IS in `barkpark_json` (`router.ex` base map) and IS in fixtures
  (`scenarios.mjs:96,1269,1293,1306`) but ZERO hits in `app.js`. SERIALIZED, FIXTURED, NEVER RENDERED.
- vercel_project_id 255 — zero hits anywhere under `cloud/priv/static/`, absent from `barkpark_json`.
  Reaches the SPA only as the BOOLEAN `deployed: present?(bp.vercel_project_id)` (`vercel.ex:106`).
  NEVER RENDERED AS TEXT.
- vercel_deploy_url 255 — absent from `barkpark_json`; reaches the SPA as `deployment_url`
  (`vercel.ex:107`), rendered at `app.js:15491-15492` into `.new-fineprint .mono` as href AND text.
  RENDERED — under a DIFFERENT KEY. A key-name census misses this edge.
- github_branch 255 — rendered `app.js:7617` and `9784`, concatenated with `github_repo` (255) inside
  `<span class="mono">` in `.site-meta`. TWO cap-sites, ONE host, 510 chars max.
- doc_type 100 — rendered `app.js:9858` via `railRow("Content type", …)` → `.rail-row .v`.
- pending_email 160 — zero hits under `cloud/priv/static/`; server-side it exists only as a staged
  column + the `:no_pending_email` error atom (`router.ex:1521,1539-1540`). NEVER SERIALIZED.
- pinned_release 255 — RENDERED. `app.js:4650` `fleetAutoupdateText` → `fleetMetaHtml` (`:4655-4664`)
  → `.fleet-meta`; also `:6090`, `:6601`. `vRel` (`:7264-7268`) does NOT truncate. Written from a bare
  free-text `#pin-input` (`:6802`, no maxlength). ZERO fixture coverage (`grep -c pinned_release` on
  `scenarios.mjs` → 0).

## D. Host protection, read from app.css on origin/main

    git show origin/main:cloud/priv/static/app.css | grep -nE '\.(fleet-name|fleet-meta|fleet-url|site-name|site-host|site-meta|set-row-name|set-row-note|a2f-secret-value)\b'
    git show origin/main:cloud/priv/static/app.css | grep -nE '^\.rail-row'

Protected: `.fleet-name` `.fleet-url` (`:985,:986` overflow-wrap:break-word, wave 21),
`.set-row-name` (`:2177` overflow-wrap:anywhere), `.instance-card-name` (`:3290`),
`.rail-row .v` (`:1471` word-break:break-word + min-width:0).
UNPROTECTED: `.site-name` (`:1534` — font-size/weight only), `.site-host` (`:1544`),
`.site-meta` (`:1535`), `.fleet-meta` (`:989`), `.set-row-note` (`:2180`).

## E. Fixture coverage counts

    git show origin/main:cloud/priv/static/__preview__/scenarios.mjs > /tmp/scen.mjs
    for f in pinned_release account_login domains github_branch doc_type region server_type suspended_reason custom_host fleet_token_id template vercel_deploy_url; do printf '%-20s %s\n' "$f" "$(grep -c "$f" /tmp/scen.mjs)"; done

pinned_release 0 · account_login 0 · vercel_deploy_url 0 · domains 22 · github_branch 5 · doc_type 4 ·
region 13 · server_type 11 · suspended_reason 4 · custom_host 7 · fleet_token_id 4 · template 16
