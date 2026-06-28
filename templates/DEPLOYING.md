<!-- doc-tier: human | canonical-for: deploy-new-site | budget: 2400tok -->
# Deploying a new site with Barkpark

From nothing to a live, Vercel-hosted site backed by its own isolated Barkpark
dataset — in one command. This is the repeatable "spin up a new site" path; the
`place-directory` template in this folder is the worked example (it powers
`hundesteder.no`).

## TL;DR — one command

```sh
scripts/bp-vercel-quick-setup.sh \
  --site hundesteder \
  --app-dir apps/hundesteder \
  --schema templates/place-directory/schemas/place.json \
  --seed  templates/place-directory/seed-places.json \
  --publish-type place \
  --token-ssh root@89.167.28.206 \
  --vercel-team guerrilla
```

→ creates the workspace, applies the schema, seeds + publishes content, mints a
read-only token, wires Vercel env, and deploys. The script prints the live URL.
Run `scripts/bp-vercel-quick-setup.sh --help` for every flag.

## Static sites (no Barkpark backend)

Not every site needs a content backend. For a plain static marketing page,
pass `--static <path>` and the whole Barkpark half is skipped — no workspace,
schema, seed, publish, or token mint, and **no `BARKPARK_*` env vars**. Only the
Vercel half runs: link → disable deployment protection → deploy.

```sh
# a directory, deployed as-is
scripts/bp-vercel-quick-setup.sh --static ./marketing-site --vercel-team guerrilla
# or a single .html file — staged into a temp build dir as index.html; an
# adjacent assets/ or public/ dir is copied alongside automatically
scripts/bp-vercel-quick-setup.sh --static ./landing.html --vercel-project promo
```

`--static` ignores `--site` / `--schema` / `--seed` / `--publish-type` /
`--read-token`. The Vercel project name defaults to the directory (or `.html`
file) basename; override with `--vercel-project`, scope with `--vercel-team`.
The `bp vercel quick-setup --static <path>` CLI subcommand behaves identically.

## What "a site" actually is

```
Barkpark workspace (tenant boundary)
  └─ project "default"
       └─ dataset "production"
            ├─ schema        (the content type, e.g. `place`)
            └─ documents      (published content)
  └─ public-read token  ──────────┐  (read-only, member of THIS workspace)
                                   ▼
Next.js app (apps/<site>)  ──fetch (server-side)──▶  Vercel deploy ──▶ <site>.vercel.app
```

Six moving parts. The script does all six; the sections below are the manual
golden path plus the **gotchas that will bite you** if you wire it by hand.

## The golden path (manual)

Assume `bp` is configured and pointed at your server (`bp use <server>`); the
saved token must be `admin`. `BASE` below is your API URL.

```sh
SITE=hundesteder; DS=production
SCOPED="$BASE/w/$SITE/p/default"      # ← the scoped prefix; use it for everything
TOKEN=<admin token>
```

1. **Workspace** (gives you project `default` + dataset `production`):
   ```sh
   bp -s <server> workspace create "$SITE"   # → {"workspace":{"id":"<uuid>", ...}}
   ```
   Keep the workspace **uuid** — you need it to mint the token in step 4.

2. **Schema** — POST the flat schema object to the *scoped* URL:
   ```sh
   curl -X POST "$SCOPED/v1/schemas/$DS" -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' --data-binary @schema.json
   ```

3. **Seed + publish**:
   ```sh
   curl -X POST "$SCOPED/v1/data/mutate/$DS" -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' --data-binary @seed.json
   # seed lands as DRAFTS — publish each id (publish needs id AND type):
   curl -X POST "$SCOPED/v1/data/mutate/$DS" -H "Authorization: Bearer $TOKEN" \
        -H 'Content-Type: application/json' \
        --data '{"mutations":[{"publish":{"id":"place-mocca-oslo","type":"place"}}]}'
   ```

4. **Read token** — mint a read-only token bound to this workspace (see gotcha #3):
   ```sh
   curl -X POST "$SCOPED/v1/tokens" \
     -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' \
     --data '{"label":"public-read-'"$SITE"'","permissions":"public-read"}'
   ```
   The endpoint returns `{"token":"<raw>"}` — capture it for step 5.
   (`bp vercel quick-setup` does this step automatically; the SSH `mix run --no-start`
   path in earlier versions of this guide is no longer needed.)

5. **Deploy** — point a Next.js app at it and ship:
   ```sh
   cd apps/$SITE
   vercel link --yes --project "$SITE" --scope <team>
   for k in production preview; do
     echo "$SCOPED"   | vercel env add BARKPARK_API_BASE  $k --scope <team>
     echo "$DS"       | vercel env add BARKPARK_DATASET   $k --scope <team>
     echo "<token>"   | vercel env add BARKPARK_API_TOKEN $k --scope <team>  # server-only
   done
   vercel deploy --prod --yes --scope <team>
   ```

The app reads `BARKPARK_API_TOKEN` **server-side only** (no `NEXT_PUBLIC_`), so the
token never reaches the browser.

## Gotchas (learned the hard way)

1. **Use the scoped URL, not the flat alias.** `…/w/<ws>/p/<project>/v1/…` is
   workspace-isolated. The flat `…/v1/…` paths resolve to the **Default**
   workspace — write there and your content lands in the wrong tenant. The `bp`
   CLI's `-w/-p` flags do **not** rewrite the URL to the scoped form, so for new
   workspaces drive provisioning with `curl` against the scoped prefix.

2. **`createOrReplace` writes drafts; publishing needs `{id, type}`.** A seed
   mutate leaves documents as `drafts.<id>` (`_draft:true`) — the published query
   returns 0 until you publish. The publish mutation requires **both** `id` and
   `type`; `{"publish":{"id":…}}` alone is `400 malformed`.

3. **Non-Default workspaces 403 anonymous reads.** Barkpark's tenancy gate runs
   *before* a schema's `public` visibility applies, so even public content in a
   new workspace needs a token that holds a `workspace_membership` row for it.
   Mint a `public-read` token bound to the workspace (step 4) and use it
   server-side. (Anonymous reads only work on the Default workspace's flat alias.)

4. **Response envelope is `{ "result": { count, documents } }`.** Reads are
   wrapped in `result` — `.result.documents`, not top-level `.documents`.

5. **`geo` coordinates are strings.** `geo.latitude` / `geo.longitude` come back
   as strings; `parseFloat` them before handing to a map.

6. **Mint with `mix run --no-start`.** Prod runs `mix phx.server` on :4000; a
   plain `mix run` boots a second endpoint and clashes on the port. `--no-start`
   + manually starting `:postgrex` and `Repo` gives you the DB without the port.

7. **Turn off Vercel deployment protection — or your public site 302s to login.**
   Teams often default to "Vercel Authentication" (`ssoProtection`), which SSO-walls
   the `*.vercel.app` URLs: the site redirects to `vercel.com/sso-api`. There's no
   CLI flag — PATCH the project: `ssoProtection: null`.
   ```sh
   curl -X PATCH "https://api.vercel.com/v9/projects/$PRJ?teamId=$TEAM" \
     -H "Authorization: Bearer $VC_TOKEN" -H 'Content-Type: application/json' \
     --data '{"ssoProtection": null}'
   ```
   `$VC_TOKEN` is the CLI's own token (`~/Library/Application Support/com.vercel.cli/auth.json`
   on macOS). The quick-setup script does this automatically right after `vercel link`.

## `bp vercel quick-setup` — built-in CLI subcommand

`bp vercel quick-setup` is a built-in subcommand (`internal/cli/vercel_cmd.go`,
dispatched from `case "vercel"` in `cli.go`). It performs all six steps natively
— workspace, schema, seed, publish, token mint, Vercel deploy — with no shell
script or SSH required.

```
internal/cli/vercel_cmd.go     func runVercel(out *writer, g globals, args []string) int
internal/cli/cli.go            case "vercel": return runVercel(out, g, rest[1:])
```

```
bp vercel quick-setup --site <slug> --app-dir <path> \
                      [--schema f --seed f --publish-type t] \
                      [--vercel-team t] [--no-deploy]
# static site (no Barkpark backend — skips workspace/schema/seed/token):
bp vercel quick-setup --static <dir-or-.html> [--vercel-project p] [--vercel-team t]
```

What the Go implementation does:

- **Workspace + schema + seed + publish** via native `bp` API calls (scoped URL,
  admin token) — no `curl`, no envelope juggling.
- **Read token** minted via `POST /w/:ws/p/:project/v1/tokens` (admin-gated) over
  HTTPS — no SSH into prod.
- **Vercel** is a shell-out to the `vercel` CLI (link → env → deploy), guarded by
  a `vercel` presence check.

The bash script (`scripts/bp-vercel-quick-setup.sh`) remains as the legacy path
and still supports `--token-ssh` for environments without a Go binary.
