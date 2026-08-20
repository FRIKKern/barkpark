# Prebuilt build_id silent no-op — re-derivation recipe (2026-07-29)

Site Spawner Wave 9 verify slice `build-id-no-op-trap`. Proves that two DISTINCT
prebuilt `dist/` uploads for the same site + same `content_rev` + same config mint
an IDENTICAL `build_id`, collide on the `(site_id, build_id)` partial unique index,
and come back as `{:duplicate, existing}` → HTTP 200 with the OLD deployment and no
build. Everything below runs against local Postgres in the test sandbox; nothing
touches a box, a network, or the real ledger.

## 0. Read the mechanism on origin/main (not the worktree)

```bash
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '120,205p'
# enqueue/5 -> build_id/4 = sha256(code_rev | content_rev | Jason.encode!(config))
# config = %{framework, kind, base, workspace, project, dataset} (+ force_nonce)
# NOTHING about the bytes is in the hash.

git show origin/main:cloud/priv/repo/migrations/20260713120000_add_content_binding_to_sites_and_deployments.exs | sed -n '44,52p'
# create unique_index(:deployments, [:site_id, :build_id], where: "build_id IS NOT NULL")

git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '10164,10195p'
# {:ok, d}        -> record_audit + Sites.Deploy.start(d) + json 201
# {:duplicate, d} -> json 200, NO audit, NO start
```

## 1. Baseline: the existing suite is green before the drill

```bash
cd cloud && CC=clang mix test test/barkpark_cloud/sites_deploy_test.exs 2>&1 | tail -5
# 41 tests, 0 failures
# NOTE: the path `test/barkpark_cloud/sites/deploy_test.exs` does NOT exist —
# the file is `test/barkpark_cloud/sites_deploy_test.exs` (flat, no sites/ dir).
```

## 2. The proof script

Write this to a scratch path (it is deliberately NOT committed under cloud/test —
it is a drill, not a suite member) and run it in the test env:

```elixir
# noop_proof.exs
import Ecto.Query
alias BarkparkCloud.{Accounts, Registry, Repo}
alias BarkparkCloud.Registry.Vault
alias BarkparkCloud.Sites.Deploy

Ecto.Adapters.SQL.Sandbox.checkout(Repo)

n = System.unique_integer([:positive])
{:ok, team} = Accounts.create_team(%{name: "T#{n}", slug: "t-#{n}"})
{:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

bp =
  bp
  |> Ecto.Changeset.change(
    url: "https://acme.barkpark.cloud",
    git_commit: "abc123",
    admin_token_encrypted: Vault.encrypt("instance-admin-token")
  )
  |> Repo.update!()

{:ok, site} =
  Registry.create_site(bp, %{
    name: "Blog #{n}", slug: "blog-#{n}", kind: "static", framework: "astro",
    bootstrap_workspace: "acme", bootstrap_project: "blog",
    bootstrap_dataset: "production", read_token: "bpt_public_read_xyz"
  })

content_rev = "rev-DEADBEEF"
digest_a = String.duplicate("a", 64)   # upload A's sha256
digest_b = String.duplicate("b", 64)   # upload B's sha256 — DIFFERENT BYTES

id_a = Deploy.build_id(site, bp, content_rev, false)
id_b = Deploy.build_id(site, bp, content_rev, false)
IO.puts("upload A digest=#{binary_part(digest_a, 0, 12)}…  build_id=#{id_a}")
IO.puts("upload B digest=#{binary_part(digest_b, 0, 12)}…  build_id=#{id_b}")
IO.puts("IDENTICAL_BUILD_ID=#{id_a == id_b}")

{r1, d1} = Deploy.enqueue(site, bp, false, "manual", content_rev)
{r2, d2} = Deploy.enqueue(site, bp, false, "manual", content_rev)
IO.puts("enqueue#1 -> #{inspect(r1)} id=#{d1.id} build_id=#{d1.build_id}")
IO.puts("enqueue#2 -> #{inspect(r2)} id=#{d2.id} build_id=#{d2.build_id}")
IO.puts("SAME_ROW_RETURNED=#{d1.id == d2.id}")
IO.puts("DEPLOYMENT_ROWS_FOR_SITE=#{Repo.aggregate(from(d in BarkparkCloud.Registry.Deployment, where: d.site_id == ^site.id), :count)}")

f1 = Deploy.build_id(site, bp, content_rev, true)
Process.sleep(2)
f2 = Deploy.build_id(site, bp, content_rev, true)
IO.puts("force build_id #1=#{f1} #2=#{f2} DISTINCT=#{f1 != f2}")
```

```bash
cd cloud && CC=clang MIX_ENV=test mix run /path/to/noop_proof.exs
```

Observed 2026-07-29:

```
upload A digest=aaaaaaaaaaaa…  build_id=081fec145f7398a1
upload B digest=bbbbbbbbbbbb…  build_id=081fec145f7398a1
IDENTICAL_BUILD_ID=true
enqueue#1 -> :ok id=f733a612-b534-40a4-8fc4-39b089a63330 build_id=081fec145f7398a1 status=queued
enqueue#2 -> :duplicate id=f733a612-b534-40a4-8fc4-39b089a63330 build_id=081fec145f7398a1 status=queued
SAME_ROW_RETURNED=true
DEPLOYMENT_ROWS_FOR_SITE=1
force build_id #1=69ec578619fb3884 #2=1f9664a2d6a693a2 DISTINCT=true PREDICTABLE=false
```

## 3. Why the digest CANNOT enter the hash (circularity, re-derived)

```bash
git show origin/main:deploy/site-deploy.sh | sed -n '1174,1180p'
#   export BARKPARK_BUILD_ID="$BUILD_ID"
#   export BARKPARK_SITE_BASE="/sites/$SITE_SLUG/"
#   [ -n "${CONTENT_REV:-}" ] && export BARKPARK_CONTENT_REV="$CONTENT_REV"
git show origin/main:deploy/site-deploy.sh | sed -n '282,296p'
#   HEALTH asserts the SERVED bp-build-id == BUILD_ID by value.
```

`build_id` is baked INTO the bytes at build time; the digest only exists after the
bytes do. Content-addressing is therefore unavailable, and prebuilt is necessarily
mint-then-upload.

## 4. Where the uploader learns `content_rev`

```bash
git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '9776,9814p'
#   deployment_json/1 already emits BOTH :build_id and :content_rev
git show origin/main:cloud/lib/barkpark_cloud/sites/deploy.ex | sed -n '286,312p'
#   content_rev_probe/2 relays to the BOX with the instance-admin token —
#   a laptop cannot compute it, so it must come back in the mint response.
```

No serializer change is needed for the uploader to learn both values.
