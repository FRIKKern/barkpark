defmodule BarkparkCloud.Push.PushRelayProvisionTest do
  @moduledoc """
  The INSTANCE-side half of the push relay (mobile charter D15, wave-2 build):

      POST /v1/barkparks/:id/push-relay   team admin

  Cloud has held a relay secret and an inbound receiver since the spike, but
  nothing ever made an instance KNOCK. This route creates the box's
  `chat_blocked` webhook row over the admin relay and agrees a shared signing
  secret. Proved here:

    * the box call goes to the **workspace-SCOPED** route. This is the one
      genuinely load-bearing detail: `Webhooks.create_webhook/2` on the box
      stamps `workspace_id` from the SERVER-RESOLVED request scope and drops
      any client-supplied one, while `chat_blocked_webhooks_for/1` matches on
      `workspace_id`. A row created through the FLAT `/v1/webhooks/:dataset`
      route gets `workspace_id: nil`, looks perfect in Studio, and can never
      fire. A test that only asserted "a webhook was created" would pass on
      that bug;
    * `blocked_threshold_s` is sent — it is simultaneously the subscription
      flag and the debounce threshold. Without it the row is an ordinary
      CONTENT webhook at the right URL, firing on document publishes;
    * the receiver URL is per-BARKPARK (the route names the instance; the D59h
      payload cannot);
    * the secret is stored ENCRYPTED and never returned, and the admin token
      never appears in the response;
    * idempotence: re-provisioning converges (re-enable + rotate + adopt the
      box's new secret) instead of duplicating the row — and adoption means it
      converges even from "Cloud lost its copy";
    * RBAC + tenancy: a plain member is refused; another team's barkpark is the
      same 404 as a nonexistent one.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @admin_token "bpat_instance_admin_token"

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp team_with(role) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, session} = Accounts.create_user_session_token(user)
    {team, session}
  end

  # A LIVE instance: url + stored admin token, so the admin relay actually
  # reaches the fake transport.
  defp live_barkpark(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          host: "203.0.113.#{rem(n, 250) + 1}",
          url: "https://bp-#{n}.barkpark.cloud",
          admin_token_encrypted: Vault.encrypt(@admin_token),
          bootstrap_workspace: "acme",
          bootstrap_project: "site",
          bootstrap_dataset: "production"
        },
        attrs
      )
    )
    |> Repo.update!()
  end

  defp provision(session, bp_id, body \\ %{}) do
    conn(:post, "/v1/barkparks/#{bp_id}/push-relay", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{session}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp empty_list_response,
    do: {:ok, %{status: 200, body: ~s({"webhooks":[]})}}

  defp created_response(id \\ "wh-1"),
    do: {:ok, %{status: 201, body: Jason.encode!(%{webhook: %{id: id}})}}

  describe "creating the row" do
    setup do
      {team, session} = team_with("admin")
      bp = live_barkpark(team)
      StudioLinkFakeHttpClient.program([empty_list_response(), created_response()])
      {:ok, team: team, session: session, bp: bp}
    end

    test "posts to the WORKSPACE-SCOPED webhook route, not the flat one", %{
      session: session,
      bp: bp
    } do
      assert provision(session, bp.id).status == 200

      assert [list_request, create_request] = StudioLinkFakeHttpClient.requests()

      assert list_request.method == :get
      assert list_request.url =~ "/w/acme/p/site/v1/webhooks/production"

      assert create_request.method == :post
      assert create_request.url =~ "/w/acme/p/site/v1/webhooks/production"
      # The exact bug this pins: the FLAT path would stamp workspace_id: nil on
      # the box and the hook could never match chat_blocked_webhooks_for/1 —
      # a webhook that exists, reads correctly in Studio, and never fires.
      assert String.contains?(create_request.url, "/w/acme/p/site/")
    end

    test "the created row is a CHAT_BLOCKED subscription aimed at this barkpark's receiver", %{
      session: session,
      bp: bp
    } do
      assert provision(session, bp.id).status == 200

      [_list, create_request] = StudioLinkFakeHttpClient.requests()
      body = Jason.decode!(create_request.body)

      # blocked_threshold_s IS the subscription flag (instance charter D59h).
      assert body["blocked_threshold_s"] == 300
      # Content lifecycle events are the OTHER channel — never both.
      assert body["events"] == []
      assert body["url"] =~ "/v1/relay/chat-blocked/#{bp.id}"
      assert body["name"] =~ bp.id
      assert is_binary(body["secret"]) and body["secret"] != ""
    end

    test "the secret is stored ENCRYPTED and never leaves in the response", %{
      session: session,
      bp: bp
    } do
      conn = provision(session, bp.id)
      assert conn.status == 200

      [_list, create_request] = StudioLinkFakeHttpClient.requests()
      sent_secret = Jason.decode!(create_request.body)["secret"]

      reloaded = Repo.get!(Barkpark, bp.id)
      assert is_binary(reloaded.push_relay_secret_encrypted)
      assert reloaded.push_relay_secret_encrypted != sent_secret
      assert {:ok, ^sent_secret} = Registry.reveal_push_relay_secret(reloaded)

      # Neither the shared secret nor the admin token may be serialized.
      refute conn.resp_body =~ sent_secret
      refute conn.resp_body =~ @admin_token
    end

    test "reports the scope and status it actually used", %{session: session, bp: bp} do
      body = json_body(provision(session, bp.id))

      assert body["status"] == "created"
      assert body["webhook_id"] == "wh-1"
      assert body["workspace"] == "acme"
      assert body["project"] == "site"
      assert body["dataset"] == "production"
    end

    test "explicit scope + threshold in the body override the bootstrap defaults", %{
      session: session,
      bp: bp
    } do
      conn =
        provision(session, bp.id, %{
          "workspace" => "other",
          "project" => "proj",
          "dataset" => "staging",
          "blocked_threshold_s" => 60
        })

      assert conn.status == 200
      [_list, create_request] = StudioLinkFakeHttpClient.requests()
      assert create_request.url =~ "/w/other/p/proj/v1/webhooks/staging"
      assert Jason.decode!(create_request.body)["blocked_threshold_s"] == 60
    end
  end

  describe "convergence" do
    test "an EXISTING row is re-enabled + rotated, and the box's new secret is adopted" do
      {team, session} = team_with("owner")
      bp = live_barkpark(team)
      receiver = "https://api.barkpark.cloud/v1/relay/chat-blocked/#{bp.id}"

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 200, body: Jason.encode!(%{webhooks: [%{id: "wh-old", url: receiver}]})}},
        {:ok, %{status: 200, body: Jason.encode!(%{webhook: %{id: "wh-old"}})}},
        {:ok,
         %{
           status: 200,
           body: Jason.encode!(%{webhook: %{id: "wh-old"}, secret: "rotated-secret-xyz"})
         }}
      ])

      body = json_body(provision(session, bp.id))

      assert body["status"] == "converged"
      assert body["webhook_id"] == "wh-old"

      assert [_list, reenable, rotate] = StudioLinkFakeHttpClient.requests()
      assert reenable.url =~ "/webhooks/production/wh-old/reenable"
      assert rotate.url =~ "/webhooks/production/wh-old/rotate"

      # Adoption, not push: the box generated the secret and Cloud stored it, so
      # the two agree even though Cloud never knew the previous one.
      assert {:ok, "rotated-secret-xyz"} =
               Registry.reveal_push_relay_secret(Repo.get!(Barkpark, bp.id))
    end

    test "re-provisioning does not create a second row" do
      {team, session} = team_with("admin")
      bp = live_barkpark(team)
      receiver = "https://api.barkpark.cloud/v1/relay/chat-blocked/#{bp.id}"

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 200, body: Jason.encode!(%{webhooks: [%{id: "wh-old", url: receiver}]})}},
        {:ok, %{status: 200, body: Jason.encode!(%{webhook: %{id: "wh-old"}})}},
        {:ok, %{status: 200, body: Jason.encode!(%{webhook: %{id: "wh-old"}, secret: "s2"})}}
      ])

      assert provision(session, bp.id).status == 200

      refute Enum.any?(StudioLinkFakeHttpClient.requests(), fn request ->
               request.method == :post and String.ends_with?(request.url, "/webhooks/production")
             end)
    end
  end

  describe "refusals" do
    test "a plain MEMBER is refused — this spends the admin token and rotates a secret" do
      {team, _admin_session} = team_with("admin")
      member = user_fixture()
      {:ok, _} = Accounts.add_member(team, member, "member")
      {:ok, member_session} = Accounts.create_user_session_token(member)
      bp = live_barkpark(team)

      conn = provision(member_session, bp.id)
      assert conn.status in [401, 403]
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "another team's barkpark is the SAME 404 as a nonexistent one (no existence leak)" do
      {_other_team, _} = team_with("admin")
      {team_a, session_a} = team_with("admin")
      {team_b, _session_b} = team_with("admin")
      _own = live_barkpark(team_a)
      foreign = live_barkpark(team_b)

      foreign_conn = provision(session_a, foreign.id)
      missing_conn = provision(session_a, Ecto.UUID.generate())

      assert foreign_conn.status == 404
      assert missing_conn.status == 404
      assert json_body(foreign_conn) == json_body(missing_conn)
      assert StudioLinkFakeHttpClient.requests() == []
    end

    test "an instance with no stored admin token is a 404 no_admin_token, not a crash" do
      {team, session} = team_with("admin")
      bp = live_barkpark(team, %{admin_token_encrypted: nil})

      conn = provision(session, bp.id)

      assert conn.status == 404
      assert json_body(conn)["error"] == "no_admin_token"
    end

    test "an instance that is not live yet → 409 not_live" do
      {team, session} = team_with("admin")
      bp = live_barkpark(team, %{url: nil})

      conn = provision(session, bp.id)

      assert conn.status == 409
      assert json_body(conn)["error"] == "not_live"
    end

    test "a box too old for the scoped webhook route → 409 push_relay_unsupported (D8 shape)" do
      {team, session} = team_with("admin")
      bp = live_barkpark(team)
      StudioLinkFakeHttpClient.program([{:ok, %{status: 404, body: ~s({"error":"not_found"})}}])

      conn = provision(session, bp.id)

      assert conn.status == 409
      assert json_body(conn)["error"] == "push_relay_unsupported"
    end
  end
end
