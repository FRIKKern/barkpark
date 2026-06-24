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

4. **Read token** — mint a read-only token that is a *member of this workspace*
   (see gotcha #3). Today this runs server-side:
   ```sh
   ssh <prod> 'cd /opt/barkpark/api && set -a && source ../.env && set +a && \
     MIX_ENV=prod mix run --no-start -e "
       Application.ensure_all_started(:postgrex)
       Barkpark.Repo.start_link()
       raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
       Barkpark.Auth.create_token(raw, \"public-read-$SITE\", \"production\",
                                  [\"public-read\"], \"<workspace-uuid>\")
       IO.puts(raw)"'
   ```

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

## Folding into the CLI — `bp vercel quick-setup`

The script is the spec for a first-class subcommand. `bp` already has
client-side built-ins (`setup`, `servers`, `migrate`, `paper`) dispatched from a
noun switch in `internal/cli/cli.go`; `vercel` slots in beside them:

```
internal/cli/vercel_cmd.go     func runVercel(out *writer, g globals, tail []string) int
internal/cli/cli.go            case "vercel": return runVercel(out, g, tail[1:])
```

```
bp vercel quick-setup --site <slug> --app-dir <path> \
                      [--schema f --seed f --publish-type t] \
                      [--vercel-team t] [--no-deploy]
```

What moving it into Go buys us:

- **Workspace + schema + seed + publish** become native `bp` calls (it already
  speaks the scoped API and holds the admin token) — no `curl`, no envelope
  juggling.
- **The read token should become an API endpoint**, not an ssh eval. Add an
  admin-gated `POST /w/:ws/p/:project/v1/tokens` that wraps
  `Barkpark.Auth.create_token(.., ["public-read"], ws_id)` and returns the
  plaintext once. Then `bp vercel quick-setup` mints over HTTPS like everything
  else and the server box stays out of the loop. **This is the single biggest
  unlock for "insanely fast"** — it removes the only step that needs shell access
  to prod.
- **Vercel** stays a shell-out to the `vercel` CLI (link → env → deploy), guarded
  by a `vercel` presence check, exactly as the script does.

Target: `bp vercel quick-setup --site x --app-dir apps/x` → live URL in well
under a minute, zero hand-editing.
