defmodule BarkparkCloud.Web.SiteCfDeployTest do
  @moduledoc """
  The cf-in-front deploy path (D57): `POST /v1/sites/:id/deploy` with
  `via=cloudflare` + a `domain`, proved end-to-end against the in-memory
  Cloudflare Fake (no live CF, €0). Asserts:

    * a connected `cloudflare` provider → the A record is upserted at the box
      origin, the record is flipped PROXIED, and the deploy still lands (201);
    * NO connected provider → a fail-closed 409 that binds NOTHING (no DNS
      write, no proxy flip);
    * NO `via` → the standalone deploy is byte-identical to today (no CF call);
    * `via=cloudflare` without a `domain` → 422.

  The Cloudflare Fake records its writes in the CALLING process's dictionary, and
  Plug.Test runs the router synchronously in THIS process, so `Fake.records/0`
  and `Fake.proxied/0` read exactly the writes the deploy made.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Cloudflare.Fake, as: CfFake
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @origin "203.0.113.10"

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp user_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  # A LIVE box: url + host + admin token, i.e. what a provision-succeed writes.
  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: "https://acme.barkpark.cloud",
      host: @origin,
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> BarkparkCloud.Repo.update!()
  end

  defp static_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: "bpt_public_read"
      })

    site
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /v1/sites/:id/deploy via=cloudflare" do
    test "with a connected provider → upserts the A record at the box origin, flips proxied, and deploys (201)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      # Connect Cloudflare with a zone_id so the writer has a zone to point at.
      {:ok, _} =
        Registry.connect_provider(
          team,
          "cloudflare",
          Jason.encode!(%{"api_token" => "cf_live_token", "zone_id" => "zone_acme"})
        )

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/deploy",
          %{via: "cloudflare", domain: "blog.example.com"},
          token
        )

      assert conn.status == 201,
             "expected the deploy to land, got #{conn.status}: #{conn.resp_body}"

      # The A record was written at the BOX ORIGIN, threaded through the resolved
      # per-team token (not global config), and flipped PROXIED (orange cloud).
      assert [%{name: "blog.example.com", type: "A", proxied: true} | _] = CfFake.records()
      assert [%{proxied: true} | _] = CfFake.proxied()
    end

    test "with NO connected provider → fail-closed 409 that binds NOTHING" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/deploy",
          %{via: "cloudflare", domain: "blog.example.com"},
          token
        )

      assert conn.status == 409
      assert json_body(conn)["error"] == "no_cloudflare_provider"
      # Nothing was written on the CF side — never a half-bind.
      assert CfFake.records() == []
      assert CfFake.proxied() == []
      # And no deployment row was minted (the deploy never proceeded).
      assert Registry.list_deployments(site, 10) == []
    end

    test "via=cloudflare without a domain → 422" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      {:ok, _} = Registry.connect_provider(team, "cloudflare", "cf_live_token")

      conn = call(:post, "/v1/sites/#{site.id}/deploy", %{via: "cloudflare"}, token)

      assert conn.status == 422
      assert json_body(conn)["error"] == "cloudflare_domain_required"
      assert CfFake.records() == []
    end

    test "deprovisioned mid-write: the record just written is deleted again, and the deploy fails closed (409)" do
      # The class this proves is cch #14039's sibling on the cloud/ side: an
      # attach-domain job re-checked a Hetzner box before AND after writing DNS
      # because a box-keyed backstop (SweepOrphans) could reach a record left
      # by a pre-check-only guard IF it still named a box — but not one left
      # after the box was already gone. Cloudflare zones are per-team BYOA:
      # there is no box-keyed (or ANY) backstop that could ever reach a record
      # here, so a pre-check alone is worse here than on the Go side, not
      # better. The ORDERING this test drives: deploy claimed the box's origin
      # → deprovision succeeds mid-write (DELETES the barkpark row, cascading
      # the site row too — `Registry.succeed_deprovision_job/2`'s real shape)
      # → the Cloudflare write lands anyway, because the CF API call has no
      # idea our DB changed underneath it.
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      {:ok, _} =
        Registry.connect_provider(
          team,
          "cloudflare",
          Jason.encode!(%{"api_token" => "cf_live_token", "zone_id" => "zone_acme"})
        )

      # The deprovision lands in the gap the upsert's network round trip stands
      # for: `on_upsert` fires right after the Fake records the write, which is
      # exactly between the pre-check (still sees the live box) and the
      # post-write re-check (must see it gone).
      CfFake.on_upsert(fn -> BarkparkCloud.Repo.delete!(bp) end)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/deploy",
          %{via: "cloudflare", domain: "blog.example.com"},
          token
        )

      # The defect FIRST, so a red run on unfixed code prints the leaked
      # record itself: no box-keyed (or any) backstop in this app can ever
      # reach an A record whose box is gone, because Cloudflare zones are
      # per-team accounts with no fleet-wide sweep.
      refute Enum.any?(CfFake.records(), &(&1.name == "blog.example.com")),
             "ORPHAN: zone still holds an A record for blog.example.com at #{@origin} — " <>
               "the box is gone and nothing else can ever reach it"

      assert conn.status == 409,
             "expected the deploy to fail closed, got #{conn.status}: #{conn.resp_body}"

      assert json_body(conn)["error"] == "instance_not_live"
      # The record was written, THEN deleted again — pin the order so a future
      # refactor cannot satisfy this test by never writing at all.
      assert [%{zone_id: "zone_acme"}] = CfFake.deletes()
    end

    test "when the cleanup delete itself fails, the response NAMES the orphaned record (502)" do
      # The honesty edge: nothing else in the fleet will ever name this record
      # again, so the error the caller gets back is the ONLY artefact that
      # will — it must carry the domain and the address, not a generic 502.
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      {:ok, _} =
        Registry.connect_provider(
          team,
          "cloudflare",
          Jason.encode!(%{"api_token" => "cf_live_token", "zone_id" => "zone_acme"})
        )

      CfFake.on_upsert(fn ->
        BarkparkCloud.Repo.delete!(bp)
        CfFake.fail_deletes(true)
      end)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/deploy",
          %{via: "cloudflare", domain: "blog.example.com"},
          token
        )

      assert conn.status == 502
      body = json_body(conn)
      assert body["error"] == "cloudflare_orphan_cleanup_failed"
      assert body["detail"] =~ "blog.example.com"
      assert body["detail"] =~ @origin
    end

    test "NO via → standalone deploy is untouched (no CF call, 201)" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      # A cloudflare provider is even CONNECTED, but without `via` it is never
      # consulted — the box serves directly, exactly as today.
      {:ok, _} = Registry.connect_provider(team, "cloudflare", "cf_live_token")

      conn = call(:post, "/v1/sites/#{site.id}/deploy", %{}, token)

      assert conn.status == 201
      assert CfFake.records() == []
      assert CfFake.proxied() == []
    end
  end
end
