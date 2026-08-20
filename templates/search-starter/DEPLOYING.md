<!-- doc-tier: human | canonical-for: search-starter-deploy | budget: 1400tok -->
# Deploying search-starter

From nothing to a live search engine at `/sites/<slug>/`, through Barkpark
Cloud's own six-stage deploy engine. This is the template-specific runbook; the
folder-wide golden path (workspace / schema / token mechanics) lives in
[../DEPLOYING.md](../DEPLOYING.md).

## TL;DR — the one command

```sh
bp cloud site create --name my-search --dataset default/default/production \
  --instance <your-box> --kind node --framework nextjs --template search-starter
bp cloud site deploy <slug>          # streams PLAN→BUILD→STAGE→HEALTH→SWITCH→RETIRE, prints the URL
```

`--kind node` is required: the finder is `force-dynamic` Next and runs as a
long-lived Node SSR process (not static HTML). `deploy` health-gates the build
before flipping the Caddy upstream. If `HEALTH` fails, nothing switches and
visitors keep seeing the previous build.

> `--template` is live today — it is in `bp cloud site create`'s own usage, and
> the dashboard picker offers **Search Starter** too. `--name`, `--dataset` and
> `--instance` are all required. There is no `--barkpark` flag; that spelling was
> printed here until it was checked against the CLI.

## Prerequisites (all live today)

The install path is honest — no stale 404:

```sh
curl -fsSL https://raw.githubusercontent.com/FRIKKern/barkpark/main/scripts/install-cli.sh | sh
bp login --device      # device flow; --device-start / --device-poll for headless agents
```

`install-cli.sh` installs `bp` 1.15.0 (fix #2797). You need a Barkpark instance
id (`bp cloud status` lists your fleet) and admin on it to seed the corpus.
This line used to print a "barkpark ls" subcommand that `runCloud` has never
dispatched.

## Seed the corpus (why the graph is a constellation)

The force graph is only gorgeous because the seed content is **densely
interlinked**. The corpus is a **single content type** that references its
siblings through:

- a scalar `reference` field, and
- an array-of-`reference` field,

with values that are bare sibling `doc_id`s present in the same seed file. Both
are edge-extracted by `/v1/graph`. A dangling reference renders a phantom node,
so keep ids consistent.

The corpus **must live in the site's Default workspace** — the flat `/v1/graph`
route resolves the default scope and ignores a token's bound workspace, so a
corpus seeded elsewhere renders an empty graph (while search still works).
The graph reads `:published` docs only — publish every seeded id (publish needs
`id` **and** `type`):

```sh
SCOPED="$BASE/w/default/p/default"
# mutate: seed the interlinked docs (drafts)
curl -X POST "$SCOPED/v1/data/mutate/$DS" -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' --data-binary @seed.json
# publish each id
curl -X POST "$SCOPED/v1/data/mutate/$DS" -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' \
     --data '{"mutations":[{"publish":{"id":"doc-alpha","type":"note"}}]}'
```

## Mint the read tokens

Live search and the graph both need a **read-only** token scoped to the site's
public workspace. One public-read token satisfies the search channel
(`UserSocket` connect + `SearchChannel` join) and the flat `/v1/graph` route:

```sh
curl -X POST "$SCOPED/v1/tokens" -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' \
     --data '{"label":"public-read","permissions":"public-read"}'
```

Pass that token as **`BARKPARK_TOKEN`**. The engine does *not* — and structurally
*cannot* — set `NEXT_PUBLIC_BARKPARK_WS_TOKEN`: its env allowlist is closed over
`BARKPARK_*` names at all three layers. Instead `next.config.mjs` **derives** the
three browser values at build time and Next inlines them into the client bundle:

| Derived | From |
|---|---|
| `NEXT_PUBLIC_BARKPARK_WS_URL` | `origin(BARKPARK_API_URL)` + `/socket` (the scoped `/w/:ws/p/:proj` suffix is stripped) |
| `NEXT_PUBLIC_BARKPARK_WS_TOKEN` | `BARKPARK_TOKEN` |
| `NEXT_PUBLIC_BARKPARK_DATASET` (+ `_WORKSPACE`, `_PROJECT`) | `BARKPARK_DATASET` / `_WORKSPACE` / `_PROJECT` |

All three matter. The channel topic is `search:<ws>:<proj>:<dataset>`, so a build
that inlines the URL and token but not the dataset joins
`search:default:default:docs` — the join **succeeds**, the LIVE badge lights, and
every keystroke returns zero hits with no error surfaced anywhere.

With `BARKPARK_TOKEN` unset, live search degrades to the server-side HTTP path
(no crash — it fails soft, and the socket isn't even built into the bundle).

## The six stages, and rollback

```
PLAN    resolve the target slot + env
BUILD   npm ci && next build → .next/standalone/  (basePath baked from BARKPARK_SITE_BASE)
STAGE   boot the node process on a private port
HEALTH  curl the running process for bp-* content-truth <meta> markers
SWITCH  flip the Caddy upstream to the healthy slot
RETIRE  drain the previous slot
```

`bp cloud site status <slug>` shows where a running deploy is;
`bp cloud site rollback <slug>` re-points the upstream at the last-good slot in
**sub-seconds** — no rebuild.

## Serving under a sub-path

`BARKPARK_SITE_BASE=/sites/<slug>/` is a **build-time** value: Next bakes it as
`basePath`, auto-prefixing every route, `<Link>`, `router.push`, `usePathname`
and image. That is why a multi-route finder can live under `/sites/<slug>/`
without escaping to the domain root. The engine sets it for you.
