defmodule BarkparkCloud.Web.RouterSiteUrlSuspendedTest do
  @moduledoc """
  cch-w58-bl — the control plane does not WRITE a SUSPENDED box's configuration.

  Two credentialed writes are covered, both of which decrypt the stored
  per-instance admin token and PUT/POST the box's webhook configuration:

    * `POST /v1/barkparks/:id/site-url`  (`Auth.require_user` — ANY team member)
    * `POST /v1/barkparks/:id/push-relay` (`Auth.require_team_admin`)

  WHY THIS FILE EXISTS AT ALL, and why "the existing suite still passes" was not
  an acceptable gate for the change it covers. Adding the two refusal clauses
  breaks ZERO existing tests — but that zero is VACUOUS: `grep -rn suspended`
  over `router_site_url_test.exs`, `push_relay_provision_test.exs`,
  `sites_deploy_test.exs` and `router_sites_test.exs` returns NOTHING. Not one
  fixture on either path sets `suspended`, so the zero measures ABSENCE OF
  COVERAGE, not safety. This file is the missing fixture.

  THE LOAD-BEARING ASSERTION is `StudioLinkFakeHttpClient.requests() == []`, not
  the status code. The refusal is a LEADING function clause in `Registry`, above
  `reveal_admin_token_or_error/1`, so the credential is never decrypted and no
  byte ever reaches a wire. An implementation that decrypted first and refused
  after would satisfy a status-code assertion and still have built the bearer.

  THE CONTROLS ARE PART OF THE PROOF. A guard that passes by breaking the happy
  path is not a guard, so the same shapes are driven UNSUSPENDED and pinned to
  the same 200, the same two upstream requests and the same decrypted bearer.

  NO REACHABILITY GATE (D684/D705). The refusal consults neither
  `verify_reachable` nor `last_verified_at`; the last test here pins that a
  NEVER-VERIFIED (`nil`/`nil`) but not-suspended row still wires. That exemption
  is enforceable as a test rather than trusted as a comment — `verify_reachable`
  is set by no fixture anywhere in this suite, so a reachability gate here would
  refuse very nearly the entire tested population.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @admin_token "instance-admin-token-plaintext"
  @instance_url "https://prod.barkpark.cloud"
  @workspace "acme"
  @dataset "production"
  @webhook_id "wh_bootstrap_123"
  @site "https://acme-blog.vercel.app"

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp user_with_team(role) do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, session} = Accounts.create_user_session_token(user)
    {team, session}
  end

  # A LIVE, bootstrapped instance — url + stored admin token + bootstrap triple,
  # i.e. everything both write paths need to actually reach the fake transport.
  # `attrs` is where a test flips `suspended`.
  defp bootstrapped_barkpark(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          url: @instance_url,
          host: "203.0.113.10",
          admin_token_encrypted: Vault.encrypt(@admin_token),
          template: "blog-starter",
          bootstrap_workspace: @workspace,
          bootstrap_project: "default",
          bootstrap_dataset: @dataset,
          bootstrap_read_token_encrypted: Vault.encrypt("bp_read_secret")
        },
        attrs
      )
    )
    |> Repo.update!()
  end

  # The billing verdict exactly as `Billing.cancel_subscription/1` writes it.
  # `last_verified_at`/`verify_reachable` stay nil on purpose: the refusal must
  # not depend on them.
  defp suspended_attrs do
    %{
      suspended: true,
      suspended_reason: "billing_lapsed",
      suspended_at: DateTime.utc_now(),
      last_verified_at: nil,
      verify_reachable: nil
    }
  end

  defp post_json(path, body, session) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{session}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # The instance list response carrying the bootstrap-owned endpoint (site-url).
  defp list_response do
    {:ok,
     %{
       status: 200,
       body:
         Jason.encode!(%{
           webhooks: [
             %{id: @webhook_id, name: "bootstrap-revalidation", active: false},
             %{id: "wh_other", name: "some-other-hook", active: true}
           ]
         })
     }}
  end

  defp program_site_url_wire do
    StudioLinkFakeHttpClient.program([
      list_response(),
      {:ok, %{status: 200, body: ~s({"webhook":{"id":"#{@webhook_id}","active":true}})}}
    ])
  end

  defp program_push_relay_provision do
    StudioLinkFakeHttpClient.program([
      {:ok, %{status: 200, body: ~s({"webhooks":[]})}},
      {:ok, %{status: 201, body: ~s({"webhook":{"id":"wh-1"}})}}
    ])
  end

  ## The refusals

  describe "POST /v1/barkparks/:id/site-url on a SUSPENDED box" do
    test "a plain MEMBER is refused 409 suspended and the instance is never called" do
      {team, session} = user_with_team("member")
      bp = bootstrapped_barkpark(team, suspended_attrs())

      # Programmed anyway: if the guard regressed, the wire would SUCCEED and
      # this test would fail on the request list rather than on a transport error
      # — the failure has to be about the credential, not about a missing stub.
      program_site_url_wire()

      conn = post_json("/v1/barkparks/#{bp.id}/site-url", %{url: @site}, session)

      assert conn.status == 409
      assert json_body(conn) == %{"error" => "suspended"}

      # THE LOAD-BEARING ASSERTION: nothing was built, so nothing was sent. The
      # admin token was never decrypted.
      assert StudioLinkFakeHttpClient.requests() == []

      # And nothing in the response could carry the credential.
      refute conn.resp_body =~ @admin_token
    end

    test "the refusal is at the REGISTRY, above the decrypt (not only at the route)" do
      {team, _session} = user_with_team("owner")
      bp = bootstrapped_barkpark(team, suspended_attrs())

      # No transport is programmed. WITHOUT the leading clause this call reaches
      # the instance and comes back {:error, :instance_error}; WITH it, the
      # refusal happens before `reveal_admin_token_or_error/1` runs.
      assert Registry.wire_site_url(bp, @site) == {:error, :suspended}
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "CONTROL: the same call on a NOT-suspended box still wires — 200, 2 requests, same bearer" do
      {team, session} = user_with_team("member")
      bp = bootstrapped_barkpark(team)
      program_site_url_wire()

      conn = post_json("/v1/barkparks/#{bp.id}/site-url", %{url: @site}, session)

      assert conn.status == 200
      assert json_body(conn)["webhook_url"] == @site <> "/api/barkpark/webhook"

      assert [list_req, put_req] = StudioLinkFakeHttpClient.requests()
      assert list_req.method == :get

      assert list_req.url ==
               @instance_url <> "/w/#{@workspace}/p/default/v1/webhooks/#{@dataset}"

      assert put_req.method == :put

      assert put_req.url ==
               @instance_url <>
                 "/w/#{@workspace}/p/default/v1/webhooks/#{@dataset}/#{@webhook_id}"

      # The DECRYPTED admin bearer rode both requests — unchanged by this slice.
      for req <- [list_req, put_req] do
        assert {"Authorization", "Bearer " <> @admin_token} =
                 List.keyfind(req.headers, "Authorization", 0)
      end
    end

    test "NO REACHABILITY GATE: a never-verified (nil/nil) unsuspended row STILL WIRES" do
      {team, session} = user_with_team("member")

      bp =
        bootstrapped_barkpark(team, %{last_verified_at: nil, verify_reachable: nil})

      assert is_nil(bp.last_verified_at) and is_nil(bp.verify_reachable)
      program_site_url_wire()

      conn = post_json("/v1/barkparks/#{bp.id}/site-url", %{url: @site}, session)

      assert conn.status == 200
      assert length(StudioLinkFakeHttpClient.requests()) == 2
    end
  end

  describe "POST /v1/barkparks/:id/push-relay on a SUSPENDED box" do
    test "a team ADMIN is refused 409 suspended and the instance is never called" do
      {team, session} = user_with_team("admin")
      bp = bootstrapped_barkpark(team, suspended_attrs())
      program_push_relay_provision()

      conn = post_json("/v1/barkparks/#{bp.id}/push-relay", %{}, session)

      # 409, NOT the 500 `provision_failed` the route's `{:error, _other}`
      # catch-all would have produced without an explicit clause: a deliberate
      # refusal must never read to an operator as an internal error.
      assert conn.status == 409
      assert json_body(conn) == %{"error" => "suspended"}
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "CONTROL: the same call on a NOT-suspended box still provisions — 200, 2 requests" do
      {team, session} = user_with_team("admin")
      bp = bootstrapped_barkpark(team)
      program_push_relay_provision()

      conn = post_json("/v1/barkparks/#{bp.id}/push-relay", %{}, session)

      assert conn.status == 200
      assert [list_req, create_req] = StudioLinkFakeHttpClient.requests()
      assert list_req.method == :get
      assert create_req.method == :post

      for req <- [list_req, create_req] do
        assert {"Authorization", "Bearer " <> @admin_token} =
                 List.keyfind(req.headers, "Authorization", 0)
      end
    end
  end
end
