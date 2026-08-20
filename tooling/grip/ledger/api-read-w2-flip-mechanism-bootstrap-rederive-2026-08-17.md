# Re-derivation recipe — is `schema.visibility` re-asserted every boot, and does a `pull_provenance` stamp make a code-default change skip a host? (2026-08-17, api-read-path-security-sweep wave 2)

Answer, in one line: **YES to both, with one carve-out nobody had reached — the re-assertion covers the `production` dataset ONLY.**

## Declared-visibility sites (origin/main)

    git show origin/main:api/lib/barkpark/tasks/schema.ex | sed -n '46,53p'        # task  → visibility: "public"
    git show origin/main:api/priv/plugins/bulldocs/schemas/paper.json | head -6    # paper → "visibility": "public"
    git show origin/main:api/lib/barkpark/plugins/bulldocs.ex | sed -n '160,170p'  # JSON → SchemaDefinition, dataset HARDCODED "production"

## Boot path (unconditional in prod)

    git show origin/main:api/lib/barkpark/application.ex | sed -n '219,225p'       # SchemaBootstrap runs SYNCHRONOUSLY, before Oban
    git show origin/main:api/lib/barkpark/schema_bootstrap.ex | sed -n '64,74p'    # register_all_schemas/0 — NOT env-gated
    git show origin/main:api/lib/barkpark/plugins/bootstrap.ex | sed -n '155,215p' # register_schemas([]) → dataset defaults "production"; Tenancy.pulled_schema_row? guard

## Live mechanic proof — safe, transaction-rolled-back, real plugins, real DB

Both probes wrap everything in `Repo.transaction` + `Repo.rollback/1`, so the DB is
unchanged afterwards (each prints an AFTER ROLLBACK row set to prove it).

    # probe A — data-only flip is NON-DURABLE for the production dataset
    cd api && MIX_ENV=dev mix run <<'EOF' 2>&1 | grep -E 'BEFORE|AFTER|register_all'
    ...  # see the wave Paper for the script body; shape:
    #   flip task+paper visibility → "private" via update_all
    #   Barkpark.Plugins.Bootstrap.register_all_schemas()
    #   re-read → production rows are BACK to "public"; paperflow/codebase rows STAY "private"
    EOF

    # probe B — a pull_provenance stamp makes the sweep skip the content update
    #   Tenancy.set_pull_provenance(default_ws, "production", %{...})
    #   flip to private, run register_all_schemas() → rows STAY private,
    #   one WARNING per production-dataset plugin schema ("sits in a PULLED workspace/dataset")

Pinned equivalents already in-tree (14 tests, 0 failures on 2026-08-17):

    cd api && mix test test/barkpark/plugins/bootstrap_default_slot_probe_test.exs \
                      test/barkpark/plugins/bootstrap_guard_test.exs --trace

## What this forces on the migration design

| Host state | Data-only UPDATE | Code-default change |
|---|---|---|
| unstamped, `production` dataset | reverted next boot | lands |
| unstamped, non-`production` dataset | DURABLE | never reaches it |
| `pull_provenance` stamped | DURABLE | never reaches it |

## Determining stamp state per host

No HTTP/CLI surface exposes it: `render_workspace/1`
(`api/lib/barkpark_web/controllers/workspace_controller.ex:913`) emits `id/slug/name` only,
and anon `/api/schemas` emits `fields/icon/name/title` — no `visibility` either.

    curl -s https://guerrilla.barkpark.cloud/api/schemas | python3 -c 'import sys,json;print(sorted([x for x in json.load(sys.stdin) if x["name"]=="task"][0]))'

So per-host stamp state (and per-host visibility) is a remote-console / psql step:

    Barkpark.Tenancy.get_default_workspace().settings["pull_provenance"]

The stamp is written ONLY by the bundle-import path
(`workspace_controller.ex:542`, `POST /v1/workspaces/:workspace_slug/import`).
