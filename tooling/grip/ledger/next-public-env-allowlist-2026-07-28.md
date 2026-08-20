# Re-derivation: can the MANAGED deploy path carry `NEXT_PUBLIC_*` to a search-starter build?

Verdict: **NO — at four independent layers**, so `templates/search-starter/lib/config.ts:70-76`
is TRUE in consequence. Its *mechanism* sentence ("all three layers of the engine allowlist are
closed over `BARKPARK_*`") is imprecise: the strongest stopper is not an allowlist at all, and the
Go layer it counts is not an allowlist.

Measured 2026-07-28 against `origin/main` @ `ab396959c77b01f87800e7399d5616ed8fd99a7b`
and the LIVE `search-ember` node slot on guerrilla (157.180.90.121).

## Layer 0 (strongest, undocumented by the comment): the control plane builds the env map literally

```sh
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '438,466p'
# deploy_payload/4 -> env: %{BARKPARK_API_URL:, BARKPARK_TOKEN:, BARKPARK_DATASET:,
#   BARKPARK_WORKSPACE:, BARKPARK_PROJECT:, BARKPARK_SITE_BASE:, BARKPARK_DOC_TYPE:}
#   |> maybe_put_target_port |> maybe_put_template |> maybe_put_theme(BARKPARK_THEME)
```
No caller-supplied map is merged. Nothing from `barkpark.template.json`, the site row, or a
request body reaches it.

## Layer 1: Elixir `DeployRequest` — closed allowlist, hard 400

```sh
git show origin/main:api/lib/barkpark/sites/deploy_request.ex | sed -n '69,80p;224,229p'
# @allowed_env_keys ~w(BARKPARK_API_URL BARKPARK_TOKEN BARKPARK_DATASET BARKPARK_WORKSPACE
#                      BARKPARK_PROJECT BARKPARK_SITE_BASE BARKPARK_DOC_TYPE BARKPARK_THEME)
# key not in @allowed_env_keys -> {:error, "invalid_env", "unknown env var ..."}
git show origin/main:api/test/barkpark/sites/deploy_runner_test.exs | sed -n '782,791p'
# test "rejects an unknown env var rather than silently dropping it"  (asserts on BARKPARK_KEK;
# NO test pins the NEXT_PUBLIC_ case specifically — the mechanism covers it, the pin does not)
```

## Layer 2: shell `BUILD_ALLOW` (build) and `RUNTIME_ALLOW` (slot env file)

```sh
git show origin/main:deploy/lib/site-deploy-common.sh | sed -n '128,131p'   # BUILD_ALLOW, 10 BARKPARK_*
git show origin/main:deploy/site-deploy-node.sh      | sed -n '139,141p'    # RUNTIME_ALLOW, 6 BARKPARK_*
```
`BUILD_ALLOW` is DOCUMENTARY only — the engine no longer loops over it (the build INHERITS the
caller-scrubbed env). `RUNTIME_ALLOW` IS looped over, in `write_slot_env` (:180-197).

## Layer 3 as the comment counts it is NOT an allowlist

```sh
git show origin/main:internal/cli/cloud_site_preflight.go | sed -n '374,386p'
# checkEnvContract only flags an ambient BARKPARK_TOKEN shadow. No key allowlist. No NEXT_PUBLIC check.
```

## Live post-condition read — the deployed slot's real boot env

```sh
bp cloud site status search-ember -o json         # kind=node, instance=guerrilla, theme=ember
ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 \
  'p=$(systemctl show -p MainPID --value barkpark-site@search-ember__b); tr "\0" "\n" < /proc/$p/environ | grep -c NEXT_PUBLIC'
# -> 0
```
Full environ (token redacted): `BARKPARK_{API_URL,BUILD_ID,CONTENT_REV,DATASET,DOC_TYPE,PROJECT,SITE_BASE,TOKEN,WORKSPACE}`
plus `PORT HOSTNAME NODE_ENV RELEASE_DIR` and systemd's own. **Zero `NEXT_PUBLIC_*`.**
Note `BARKPARK_THEME` is absent at runtime by design — it is build-time only, not in `RUNTIME_ALLOW`.

## Can anything ELSE inject `NEXT_PUBLIC_FINDER_LANDING`? No.

```sh
git grep -n 'FINDER_LANDING' origin/main
# only: cloud/templates.ex:84 (place-directory DISPLAY mirror for the Vercel clone prefill),
#       templates/place-directory/{README,install.sh,barkpark.template.json}, .env.example (commented),
#       app/(finder)/page.tsx (the reader). Nothing in the deploy path.
git show origin/main:internal/cli/cloud_site_cmd.go | sed -n '151,152p'
# flags: name dataset framework kind instance doc-type template theme — no --env
git grep -rn 'reveal_site_env' origin/main | grep -v _test | grep -v charter
# POST /v1/sites/:id/env stores a Vault blob that has ZERO route callers and is never merged
# into deploy_payload — write-only, reaches no build.
git show origin/main:cloud/lib/barkpark_cloud/registry.ex | sed -n '3244,3272p'
# reveal_bootstrap: "The owner-facing /bootstrap route is the only caller" — display-only.
git show origin/main:cloud/lib/barkpark_cloud/registry/env_var.ex | sed -n '1,20p'
# EnvVar scopes are team|barkpark -> the INSTANCE's runtime env, not a site build.
```

## Consequences the wave must act on

1. `NEXT_PUBLIC_FINDER_LANDING` is unreachable on the managed path ⇒ `app/(finder)/page.tsx:43`
   always takes the `GraphFinderLanding` branch ⇒ `MapLanding` / `ListingsMap` are **dead code on
   every provisioned site**. The map defect class is neither "coordinate-starved" nor
   "corpus-disjoint" — it is **unreachable**. (It is *also* corpus-disjoint: `fetchListings()`
   falls back to 13 bundled `SAMPLE_LISTINGS`.) README.md:13 bullet ⇒ **DELETE or move under an
   explicit "self-host only" heading**; `cloud/templates.ex:92` ⇒ drop "a listings map".
2. Typo tolerance is **partially real** — a `recovery: "typo_widen"` path exists and fires on the
   live flagship — so it is REWRITABLE, not cut. See the live probes below.

## Live typo probes (search-ember, `/api/find`)

```sh
B=https://guerrilla.barkpark.cloud/sites/search-ember
for q in barkprak portabledco saerch documnet reciept; do curl -sL "$B/api/find?q=$q"; done
# barkprak    -> total 3, engineUsed postgres, recovery "typo_widen", correctedTo null
# portabledco -> total 9, recovery "typo_widen"
# saerch      -> total 0, recovery null      <- transposition NOT tolerated
# documnet    -> total 0, recovery null
# reciept     -> total 0, recovery null
```
`indxUnavailable:false` while `engineUsed:"postgres"` — D66 confirmed live (indx never answers).
Also observed: `barkprak` returns `total:3` while its own `facets` say `status: published=1`,
`type: paper=1` — a count-vs-facet contradiction worth a separate row.
