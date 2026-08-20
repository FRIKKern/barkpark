# cch-w69 — claim-host normaliser reachability: re-derivation recipes (2026-08-17)

Baseline: `origin/main` = `27e4061682`. Every row below re-derives from scratch.

## 1. The two twins exist on origin/main (SQL fragment + Elixir)

    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | grep -n "regexp_replace(regexp_replace"
    git show origin/main:cloud/lib/barkpark_cloud/registry.ex | grep -n 'defp normalize_claim_host' -A 8

Expect fragment at :5619, `defp normalize_claim_host/1` at :5659-5666 (downcase → **trim** →
scheme-strip → tail-strip → trailing-dot).

## 2. The twins DIVERGE today — leading whitespace before the scheme

    psql -h localhost -U postgres -tAc "select '['||regexp_replace(regexp_replace(regexp_replace(lower(' https://gyldendal.barkpark.cloud'), '^[a-z][a-z0-9+.-]*://', ''), '[^a-z0-9.-].*\$', ''), '\.+\$', '')||']'"
    # → []          (SQL: ^ anchor misses, tail-strip eats everything)

    elixir -e 'IO.inspect(" https://gyldendal.barkpark.cloud" |> String.downcase() |> String.trim() |> String.replace(~r{^[a-z][a-z0-9+.-]*://}, "") |> String.replace(~r/[^a-z0-9.-].*$/, "") |> String.trim_trailing("."))'
    # → "gyldendal.barkpark.cloud"

Divergence class = leading whitespace/newline/NBSP **before** the scheme (SQL "" vs twin the real
host). Whitespace AFTER the scheme agrees (both ""). upper / trailing-dot / port+path / no-scheme
all agree.

## 3. Can a hostile spelling be STORED? Yes — worker-token route, no format validation

    git show origin/main:cloud/lib/barkpark_cloud/registry/barkpark.ex | grep -n 'validate_format'
    # → only :slug (522) and :host (591). NO validate_format on :url, though :url IS cast (502).

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'url: conn.body_params\["url"\]'
    # → 6453  (POST /v1/internal/barkparks → Registry.adopt_barkpark, Auth.require_worker)

    sed -n '20,25p' cloud/priv/repo/migrations/20260627130000_add_barkparks_url_unique_index.exs
    # unique_index(:barkparks, [:url]) — RAW column, so " https://x" and "https://x" are distinct.

Machine-minted path (`insert_with_url_reservation`, registry.ex:372-397) is safe: url is built by
`Barkpark.clean_url/1` / `provisioning_url/1` from a `@slug_format`-validated slug.
CLI adopt (`internal/cli/hetzner_instance_cmd.go:1251`) sends `slug` from the SAME fqdn, so a
hostile `--fqdn` reds on the slug format — the HTTP route accepts slug and url INDEPENDENTLY.

## 4. Third + fourth copies of the rule (the two-twin framing misses them)

    grep -rn 'replace_prefix("https://"' cloud/lib/
    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | grep -n 'Barkpark.subdomain_from_url'

`Barkpark.subdomain_from_url/1` (registry/barkpark.ex:439) — no trim, no downcase; feeds
`dns_label` (:9664, :11406) and the provision-claim `slug` (:11221) the Go worker turns into the
DNS record + Hetzner box name. `DomainStatus.platform_host/1` (domain_status.ex:227) — a fourth
spelling (trim + prefix + split "/" + split ":").

## 5. cloud/test/** DOES dispatch the Cloud suite

    bash scripts/cloud-path-escape-check.sh --print-set cloud        # first entry: cloud/**
    printf 'cloud/test/barkpark_cloud/registry_test.exs\n' | bash scripts/cloud-path-escape-check.sh --match cloud
    # → true

## 6. No defp→def promotion needed — the AST helper already reads defp

    git show origin/main:cloud/test/barkpark_cloud/registry_name_claim_census_test.exs | grep -n 'kind in \[:def, :defp\]'
    # → 94   (fun_ast/3, already applied to provisioning_fqdn_claim/2 at :72)

Charter position on AST: D45 ("Do NOT build an AST walker" — scoped to the router route census)
and D341 ("No AST (D45)"). This file is the standing counter-precedent for registry.ex.

    grep -inE 'promote (a|the) `?defp|make (it|the function) public|@doc false' .claude/workflows/bp-cloud-console-hardening-charter.md
    # → no matches: no D-row constrains defp→def promotion either way.
