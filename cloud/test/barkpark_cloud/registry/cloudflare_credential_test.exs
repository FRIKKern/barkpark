defmodule BarkparkCloud.Registry.CloudflareCredentialTest do
  @moduledoc """
  The D52 per-team Cloudflare credential seam + the D57 binding writer, both DB-
  backed:

    * `resolve_cloudflare_credential/1` — decrypt the newest connected
      `cloudflare` Provider's stored blob into `%{token, account_id, zone_id}`,
      or `{:error, :no_cloudflare_provider}` when the team connected none. Both
      credential shapes Cloudflare accepts (a bare API token, or a JSON blob
      `{api_token, account_id?, zone_id?}`) decode here; a present-but-unreadable
      ciphertext fails closed. The whole point is that the token is RESOLVED and
      THREADED as an argument — never smuggled through `Application.put_env`.
    * `set_cf_binding/2` — schema-tolerant persist of the CF-in-front binding
      that never crashes on a column the edge-binding-schema slice hasn't merged
      yet.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Site

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  describe "resolve_cloudflare_credential/1" do
    test "no connected cloudflare provider → {:error, :no_cloudflare_provider}" do
      team = team_fixture()
      assert {:error, :no_cloudflare_provider} = Registry.resolve_cloudflare_credential(team)
    end

    test "an azure provider does NOT satisfy the cloudflare lookup (kind-scoped)" do
      team = team_fixture()

      {:ok, _} =
        Registry.connect_provider(
          team,
          "azure",
          Jason.encode!(%{
            "tenant_id" => "t",
            "client_id" => "c",
            "client_secret" => "s",
            "subscription_id" => "sub"
          })
        )

      assert {:error, :no_cloudflare_provider} = Registry.resolve_cloudflare_credential(team)
    end

    test "a bare API-token credential decodes to token with nil account/zone" do
      team = team_fixture()
      {:ok, _} = Registry.connect_provider(team, "cloudflare", "cf_bare_token_123")

      assert {:ok, %{token: "cf_bare_token_123", account_id: nil, zone_id: nil}} =
               Registry.resolve_cloudflare_credential(team)
    end

    test "a JSON blob decodes token + account_id + zone_id" do
      team = team_fixture()

      blob =
        Jason.encode!(%{
          "api_token" => "cf_blob_token",
          "account_id" => "acct_9",
          "zone_id" => "zone_abc"
        })

      {:ok, _} = Registry.connect_provider(team, "cloudflare", blob)

      assert {:ok, %{token: "cf_blob_token", account_id: "acct_9", zone_id: "zone_abc"}} =
               Registry.resolve_cloudflare_credential(team)
    end

    test "the NEWEST connected cloudflare provider wins (a rotated credential)" do
      team = team_fixture()
      {:ok, _old} = Registry.connect_provider(team, "cloudflare", "cf_old")
      {:ok, _new} = Registry.connect_provider(team, "cloudflare", "cf_new")

      assert {:ok, %{token: "cf_new"}} = Registry.resolve_cloudflare_credential(team)
    end

    test "resolves by a bare team_id binary too (the deploy path passes site.team_id)" do
      team = team_fixture()
      {:ok, _} = Registry.connect_provider(team, "cloudflare", "cf_by_id")

      assert {:ok, %{token: "cf_by_id"}} = Registry.resolve_cloudflare_credential(team.id)
    end
  end

  describe "set_cf_binding/2 (schema-tolerant, D57)" do
    setup do
      team = team_fixture()
      bp = barkpark_fixture(team)

      {:ok, site} =
        Registry.create_site(bp, %{
          name: "Blog #{System.unique_integer([:positive])}",
          slug: "blog-#{System.unique_integer([:positive])}",
          kind: "static",
          framework: "astro",
          bootstrap_workspace: "acme",
          bootstrap_project: "blog",
          bootstrap_dataset: "production",
          read_token: "bpt_public_read"
        })

      %{site: site}
    end

    test "never crashes on cf_* attrs and returns {:ok, %Site{}}", %{site: site} do
      # The columns are owned by the edge-binding-schema slice; until it merges,
      # this degrades to a no-op update rather than an unknown-field crash.
      assert {:ok, %Site{id: id}} =
               Registry.set_cf_binding(site, %{
                 serving_mode: "cf_proxied",
                 tls_mode: "cf_internal",
                 cf_domain: "blog.example.com",
                 cf_zone_id: "zone_abc",
                 cf_record_id: "rec_1"
               })

      assert id == site.id
    end

    test "persists the binding once the cf_* columns exist", %{site: site} do
      # Strengthens automatically when cf-edge-binding-schema merges: if the
      # schema carries serving_mode, assert the write landed; otherwise this is a
      # documented no-op (the columns aren't there yet).
      {:ok, _} =
        Registry.set_cf_binding(site, %{
          serving_mode: "cf_proxied",
          tls_mode: "cf_internal",
          cf_domain: "blog.example.com",
          cf_zone_id: "zone_abc",
          cf_record_id: "rec_1"
        })

      reloaded = Registry.get_site(site.id)

      if :serving_mode in Site.__schema__(:fields) do
        assert Map.get(reloaded, :serving_mode) == "cf_proxied"
        assert Map.get(reloaded, :cf_domain) == "blog.example.com"
        assert Map.get(reloaded, :cf_zone_id) == "zone_abc"
        assert Map.get(reloaded, :cf_record_id) == "rec_1"
      else
        # No cf_* columns yet — the call is a safe no-op (proven above).
        assert %Site{} = reloaded
      end
    end
  end
end
