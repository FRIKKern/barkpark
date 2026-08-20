# v10 — auto-proof's root cause is a 20-minute defect window, and the repair verb cannot repair 6 of the 8

Wave 12 verify. Every row re-derives from scratch with the literal command beside it.
Boxes: `178.105.92.191` = control plane (Postgres `cloud-db-1` / `barkpark_cloud_prod`);
`157.180.90.121` = Guerrilla (Postgres `barkpark_prod`, `sudo -u postgres psql`).
L2 = `git show origin/main:` / `git grep origin/main`.

## 1. auto-proof: secret present, zero deployments, row NEVER touched in 24 days

    cat > /tmp/v10a.sql <<'SQL'
    SELECT s.name, s.kind, s.bootstrap_dataset AS ds, s.doc_type,
           (s.content_webhook_secret_encrypted IS NOT NULL) AS has_secret,
           s.inserted_at, s.updated_at, b.url AS box_url,
           (SELECT count(*) FROM deployments d WHERE d.site_id = s.id) AS deploys
    FROM sites s LEFT JOIN barkparks b ON b.id = s.barkpark_id
    ORDER BY deploys DESC, s.inserted_at;
    SQL
    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod' < /tmp/v10a.sql

13 sites. 6 carry a secret; `auto-proof` is the only one of those with `deploys = 0`,
and its `updated_at` equals its `inserted_at` to the microsecond
(`2026-07-14 16:21:00.078248`) — the row has never been written since create.
`sites` has NO `status` column (the schema listing at
`git show origin/main:cloud/lib/barkpark_cloud/registry/site.ex | grep -n 'field'`
is the authority — note also NO field records webhook-registration state).

## 2. The box has FIVE site-autodeploy rows and auto-proof's is not among them

    ssh -i ~/.ssh/barkpark_indx root@178.105.92.191 'docker exec -i cloud-db-1 psql -U barkpark_cloud -d barkpark_cloud_prod -c "SELECT id, name, inserted_at FROM sites WHERE name IN ('"'"'auto-proof'"'"','"'"'live-auto'"'"')"'
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 'sudo -u postgres psql -d barkpark_prod -c "SELECT name, dataset, active, types, consecutive_failures, inserted_at, updated_at FROM webhooks ORDER BY inserted_at"'

auto-proof = `8fa53cb3-46ce-4067-9f32-ba57184db301`. No `site-autodeploy-8fa53cb3…` row exists.
live-auto = `0cf76788-…`; its webhook row's `inserted_at` is `2026-07-14 16:40:52.710834`,
**25 ms** after the site row (`16:40:52.685897`) — the inline create-path registration took.

## 3. THE ROOT CAUSE: auto-proof was created 13m26s inside a 20-minute defect window

    git log origin/main --format='%h %cI %s' -S'content_webhook_name' -- cloud/lib/barkpark_cloud/registry.ex | tail -5
    git show 40a5063b1:cloud/lib/barkpark_cloud/registry.ex | sed -n "$(git show 40a5063b1:cloud/lib/barkpark_cloud/registry.ex | grep -n 'defp maybe_register_content_webhook' | head -1 | cut -d: -f1),+27p"
    git grep -n 'validate_required' origin/main -- api/lib/barkpark/webhooks/webhook.ex

* `40a5063b1` (**16:14:34Z**) shipped the feature; its POST body is
  `%{events: …, url: url, secret: secret}` — **no `name` key**.
* `api/lib/barkpark/webhooks/webhook.ex:90` has `validate_required([:name, :url])`
  since `559c3926d` (2026-04-16) → a nameless POST 422s.
* **auto-proof created 16:21:00Z** — inside the window. 422 → `Logger.warning` →
  `:error` → discarded by `_ =` at `registry.ex:4549`. No row, no trace, forever.
* `e2809f7e9` (**16:34:26Z**) — *"fix(sites): content-webhook registration must send a
  name (was 422ing) (#3275)"*.
* **live-auto created 16:40:52Z** — after the fix. Registered in 25 ms.

The window is `16:14:34Z → 16:34:26Z`, **19m52s**. auto-proof is its sole survivor.

## 4. `ensure_content_webhook/2` has ZERO production callers — CONFIRMS charter D139

    git grep -n 'ensure_content_webhook' origin/main -- cloud internal cmd api web js scripts
    git grep -ln 'ensure_content_webhook' origin/main

Hits: `registry.ex` (definition + the private `:create` sibling), two test files, three
charters. No mix task, no `bp` verb, no route, no worker. Charter **D139** already records
this — v10 re-derives it, it is not new.

## 5. …and it CANNOT repair 6 of the 8 uncovered sites (REVEALS, never MINTS)

    git grep -n 'reveal_site_content_secret' origin/main -- cloud/lib/barkpark_cloud/registry.ex

`reveal_site_content_secret(%Site{content_webhook_secret_encrypted: nil}) -> {:ok, nil}`
and `ensure_content_webhook/2` matches only `{:ok, secret} when is_binary(secret)`;
everything else falls to `_ -> :noop`. Of the 8 sites with no box row:
**1** (auto-proof) has a secret and IS repairable by the verb; **6** are content-bound with
`production` dataset and NO secret (`perfect-proof`, `next-proof`, `next-capstone`,
`perfect-demo`, `perfect-demo-2`, `nodeproof-20260718-73191`) → `:noop`; **1**
(`jarl-website`) is `kind = container`, correctly excluded. Matches site-spawner D84.

## 6. The receiver 404s a nil secret — deliberately indistinguishable from "no such site"

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '7119,7185p'

`is_nil(site) -> 404 not_found`; `{:ok, nil} -> 404 not_found` with the comment
*"same shape as 'not found' so a probe cannot distinguish unconfigured from nonexistent."*
Deliberate, and it is also why an unregistered site cannot be detected from outside.

## 7. NOTHING detects "secret present, box row absent"

    git grep -in 'content_webhook_secret_encrypted' origin/main -- cloud/lib internal scripts cloud/priv | grep -v 'registry.ex\|site.ex'

Only the migration `20260714150000_…` in comments. No sweep script, no console field, no
API field, no column on `sites`. Prior art `dr-w1-s4-followup-auto-proof-zombie-webhook`
(OPEN, p2, 0/2 criteria, filed 2026-08-05) knows the SYMPTOM and frames it as an operator
decision; it does not carry the root cause above.

    bp task get dr-w1-s4-followup-auto-proof-zombie-webhook
