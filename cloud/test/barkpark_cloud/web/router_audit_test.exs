defmodule BarkparkCloud.Web.RouterAuditTest do
  @moduledoc """
  The audit read route (`GET /v1/audit`, ADMIN-gated) and the audited write
  seams: the router wraps each mutating route in `Accounts.audit/3` (or a
  best-effort post-commit `record_audit/1` for the Stripe webhook) so a
  successful mutation stamps exactly one correctly-shaped audit row, and a failed
  one stamps none. Driven via Plug.Test, mirroring RouterTest.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Billing
  alias BarkparkCloud.Billing.StubGateway
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Vercel
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  ## Fixtures

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  # An OWNER of a fresh team, plus a session token. {user, team, token}.
  defp logged_in do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  # Add a member to `team` at `role` and return {user, token}.
  defp member_of(team, role) do
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, token}
  end

  defp barkpark_fixture(team, attrs) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  ## Request helpers

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp call_raw(method, path, raw_body, headers) do
    conn = conn(method, path, raw_body) |> put_req_header("content-type", "application/json")
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp actions(team), do: team |> Accounts.list_audit_events() |> Enum.map(& &1.action)

  ## GET /v1/audit — ADMIN-gated read

  describe "GET /v1/audit" do
    test "401 without a bearer token" do
      conn = call(:get, "/v1/audit")
      assert conn.status == 401
    end

    test "200 with an empty list for a fresh admin's team" do
      {_u, _t, token} = logged_in()
      conn = call(:get, "/v1/audit", nil, token)
      assert conn.status == 200
      assert json_body(conn) == %{"events" => []}
    end

    test "a plain MEMBER is 403 (RBAC: the trail is owner/admin-only)" do
      {_owner, team, _owner_token} = logged_in()
      {_member, member_token} = member_of(team, "member")

      conn = call(:get, "/v1/audit", nil, member_token)
      assert conn.status == 403
    end

    test "an ADMIN member gets the trail" do
      {_owner, team, _owner_token} = logged_in()
      {_admin, admin_token} = member_of(team, "admin")

      {:ok, _} =
        Accounts.record_audit(%{team_id: team.id, action: "site.created", target_id: "s-1"})

      conn = call(:get, "/v1/audit", nil, admin_token)
      assert conn.status == 200
      assert %{"events" => [ev]} = json_body(conn)
      assert ev["action"] == "site.created"
    end

    test "returns rows after an audited mutation, newest first, with actor" do
      {user, team, token} = logged_in()

      {:ok, _} =
        Accounts.record_audit(%{
          team_id: team.id,
          actor_user_id: user.id,
          action: "site.created",
          target_type: "site",
          target_id: "s-1"
        })

      conn = call(:get, "/v1/audit", nil, token)
      assert conn.status == 200
      assert %{"events" => [ev]} = json_body(conn)
      assert ev["action"] == "site.created"
      assert ev["actor"]["email"] == user.email
      assert ev["target_id"] == "s-1"
    end

    test "?limit and ?before paginate" do
      {_u, team, token} = logged_in()

      for _ <- 1..3 do
        {:ok, _} = Accounts.record_audit(%{team_id: team.id, action: "site.created"})
      end

      conn = call(:get, "/v1/audit?limit=2", nil, token)
      assert %{"events" => first_page} = json_body(conn)
      assert length(first_page) == 2

      cursor = List.last(first_page)["inserted_at"]
      conn2 = call(:get, "/v1/audit?limit=2&before=" <> URI.encode_www_form(cursor), nil, token)
      assert %{"events" => second_page} = json_body(conn2)
      assert length(second_page) == 1
    end

    test "an admin in team A never sees team B's events" do
      {_ua, _ta, token_a} = logged_in()
      team_b = team_fixture()
      {:ok, _} = Accounts.record_audit(%{team_id: team_b.id, action: "barkpark.deleted"})

      conn = call(:get, "/v1/audit", nil, token_a)
      assert json_body(conn) == %{"events" => []}
    end
  end

  ## DELETE /v1/barkparks/:id

  describe "DELETE /v1/barkparks/:id audits the removal" do
    test "a non-live box delete writes exactly one barkpark.deleted event" do
      {user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{name: "Doomed"})

      conn = call(:delete, "/v1/barkparks/#{bp.id}", nil, token)
      assert conn.status == 200

      assert [ev] = Accounts.list_audit_events(team)
      assert ev.action == "barkpark.deleted"
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id
      assert ev.metadata == %{"name" => "Doomed"}
    end

    test "a live box (deprovision path) writes NO barkpark.deleted event" do
      {_user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{name: "Live", host: "10.0.0.1"})

      conn = call(:delete, "/v1/barkparks/#{bp.id}", nil, token)
      assert conn.status == 202
      assert Accounts.list_audit_events(team) == []
    end
  end

  ## POST /v1/go-live — recorded post-commit (register_managed_barkpark retries
  ## incompatibly with an enclosing txn), so the audit is best-effort here.

  describe "POST /v1/go-live audits the launch" do
    test "an entitled launch writes a barkpark.go_live event for the created row" do
      {user, team, token} = logged_in()
      {:ok, _sub} = Billing.subscribe(team, "supporter")

      conn = call(:post, "/v1/go-live", %{name: "Prod", plan: "supporter"}, token)
      assert conn.status == 201
      bp_id = json_body(conn)["barkpark"]["id"]

      assert [ev] =
               Enum.filter(Accounts.list_audit_events(team), &(&1.action == "barkpark.go_live"))

      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp_id
      assert ev.metadata["name"] == "Prod"
    end
  end

  ## Member / invitation seams

  describe "member + invitation seams" do
    test "POST invitations writes member.invited; a duplicate writes none" do
      {_owner, team, token} = logged_in()

      conn =
        call(
          :post,
          "/v1/teams/#{team.id}/invitations",
          %{email: "new@x.io", role: "member"},
          token
        )

      assert conn.status == 201
      assert [ev] = Accounts.list_audit_events(team)
      assert ev.action == "member.invited"
      assert ev.target_type == "invitation"
      assert ev.metadata["email"] == "new@x.io"

      # A second live invite to the same email 409s — and stamps NO new row.
      dup =
        call(
          :post,
          "/v1/teams/#{team.id}/invitations",
          %{email: "new@x.io", role: "member"},
          token
        )

      assert dup.status == 409
      assert actions(team) == ["member.invited"]
    end

    test "DELETE invitation writes invitation.revoked" do
      {owner, team, token} = logged_in()
      {:ok, %{invitation: inv}} = Accounts.invite_member(team, "gone@x.io", "member", owner)

      conn = call(:delete, "/v1/teams/#{team.id}/invitations/#{inv.id}", nil, token)
      assert conn.status == 200

      assert Enum.any?(Accounts.list_audit_events(team), fn e ->
               e.action == "invitation.revoked" and e.target_id == inv.id
             end)
    end

    test "POST /v1/invitations/accept writes invitation.accepted under the team" do
      {owner, team, _owner_token} = logged_in()
      invitee = user_fixture(%{email: "invitee-#{System.unique_integer([:positive])}@x.io"})
      {:ok, %{token: raw}} = Accounts.invite_member(team, invitee.email, "member", owner)
      {:ok, invitee_token} = Accounts.create_user_session_token(invitee)

      conn = call(:post, "/v1/invitations/accept", %{token: raw}, invitee_token)
      assert conn.status == 200

      assert [ev] =
               Accounts.list_audit_events(team)
               |> Enum.filter(&(&1.action == "invitation.accepted"))

      assert ev.actor_user_id == invitee.id
      assert ev.team_id == team.id
    end

    test "PATCH member role writes member.role_changed; an invalid role writes none" do
      {_owner, team, token} = logged_in()
      {target, _} = member_of(team, "member")

      conn =
        call(:patch, "/v1/teams/#{team.id}/members/#{target.id}", %{role: "admin"}, token)

      assert conn.status == 200

      assert [ev] =
               Enum.filter(
                 Accounts.list_audit_events(team),
                 &(&1.action == "member.role_changed")
               )

      assert ev.target_id == target.id
      assert ev.metadata["new_role"] == "admin"

      # An invalid role 422s and stamps nothing new.
      before = length(Accounts.list_audit_events(team))
      bad = call(:patch, "/v1/teams/#{team.id}/members/#{target.id}", %{role: "wizard"}, token)
      assert bad.status == 422
      assert length(Accounts.list_audit_events(team)) == before
    end

    test "DELETE member writes member.removed" do
      {_owner, team, token} = logged_in()
      {target, _} = member_of(team, "member")

      conn = call(:delete, "/v1/teams/#{team.id}/members/#{target.id}", nil, token)
      assert conn.status == 200

      assert [ev] =
               Enum.filter(Accounts.list_audit_events(team), &(&1.action == "member.removed"))

      assert ev.target_id == target.id
    end
  end

  ## Token seams

  describe "token seams" do
    test "POST /v1/tokens writes token.minted and still returns the plaintext once" do
      {_owner, _team, token} = logged_in()

      conn = call(:post, "/v1/tokens", %{name: "ci-bot", abilities: ["read"]}, token)
      assert conn.status == 201
      assert is_binary(json_body(conn)["token"])

      user = Accounts.verify_user_session_token(token)
      team = Accounts.primary_team(user)
      assert [ev] = Enum.filter(Accounts.list_audit_events(team), &(&1.action == "token.minted"))
      assert ev.metadata["name"] == "ci-bot"
    end

    test "a forbidden mint (member minting root) writes NO token.minted row" do
      {_owner, team, _owner_token} = logged_in()
      {_member, member_token} = member_of(team, "member")

      conn = call(:post, "/v1/tokens", %{name: "escalate", abilities: ["root"]}, member_token)
      assert conn.status == 403
      assert Enum.filter(Accounts.list_audit_events(team), &(&1.action == "token.minted")) == []
    end

    test "DELETE /v1/tokens/:id writes token.revoked" do
      {_owner, team, token} = logged_in()
      mint = call(:post, "/v1/tokens", %{name: "revoke-me", abilities: ["read"]}, token)
      pat_id = json_body(mint)["pat"]["id"]

      conn = call(:delete, "/v1/tokens/#{pat_id}", nil, token)
      assert conn.status == 200

      assert [ev] = Enum.filter(Accounts.list_audit_events(team), &(&1.action == "token.revoked"))
      assert ev.target_id == pat_id
    end
  end

  ## Billing cancel seam

  describe "POST /v1/billing/cancel audits the cancel" do
    test "a password-confirmed cancel writes subscription.canceled and persists" do
      {_owner, team, token} = logged_in()
      {:ok, _sub} = Billing.subscribe(team, "supporter")

      conn = call(:post, "/v1/billing/cancel", %{password: @password}, token)
      assert conn.status == 200

      assert [ev] =
               Enum.filter(
                 Accounts.list_audit_events(team),
                 &(&1.action == "subscription.canceled")
               )

      assert ev.target_type == "subscription"
    end

    test "a wrong-password cancel 401s and writes NO row" do
      {_owner, team, token} = logged_in()
      {:ok, _sub} = Billing.subscribe(team, "supporter")

      conn = call(:post, "/v1/billing/cancel", %{password: "not-it"}, token)
      assert conn.status == 401
      assert Accounts.list_audit_events(team) == []
    end
  end

  ## Stripe webhook — best-effort, post-commit, system actor

  describe "POST /v1/billing/webhook audits with a null (system) actor" do
    test "a valid activation writes subscription.activated (nil actor) AND persists the sub" do
      {_u, team, _token} = logged_in()

      raw =
        Jason.encode!(%{
          "id" => "evt_#{System.unique_integer([:positive])}",
          "type" => "checkout.session.completed",
          "data" => %{
            "object" => %{"metadata" => %{"team_id" => team.id, "plan" => "supporter"}}
          }
        })

      conn =
        call_raw(:post, "/v1/billing/webhook", raw, [
          {"stripe-signature", StubGateway.test_signature()}
        ])

      assert conn.status == 200

      # The subscription persisted (the audit is post-commit + best-effort, so it
      # can never roll the subscription back).
      sub = Billing.active_subscription(team)
      assert sub != nil and sub.status == "active"

      assert [ev] =
               Enum.filter(
                 Accounts.list_audit_events(team),
                 &(&1.action == "subscription.activated")
               )

      assert is_nil(ev.actor_user_id)
      assert ev.metadata["source"] == "stripe_webhook"
      assert ev.metadata["plan"] == "supporter"
    end
  end

  ## Instance-lifecycle levers (OC24) — every headline console button leaves a
  ## trail. The seven async triggers (retry / verify / studio-link /
  ## self-update / rollback / vercel-deploy / resurrect) record post-commit on
  ## the SUCCESS branch only; the sync trio (site-url / autoupdate / domain)
  ## is transactional — a failed action writes NO row (asserted below). No
  ## detail map ever carries a token, a ticket, or a URL that embeds one.

  @instance_admin_token "instance-admin-token-plaintext"
  @instance_url "https://prod.barkpark.cloud"
  @bundle "s3://barkpark-archives/shop-2026-07-09.tar.zst"

  # All-green fake for the :verify_http_client seam — every probe answers a
  # bare 200, so Verify.run/1 yields {:ok, result} with reachable: true. The
  # app-env swap is bleed-free under async: the seam's only other user
  # (verify_test.exs) is async: false, so it never runs concurrently with
  # this file, and swap_verify_client!/0 restores on exit.
  defmodule FakeVerifyHttp do
    def request(_req), do: {:ok, %{status: 200, body: "", headers: []}}
  end

  defp swap_verify_client! do
    prev = Application.get_env(:barkpark_cloud, :verify_http_client)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:barkpark_cloud, :verify_http_client)
        mod -> Application.put_env(:barkpark_cloud, :verify_http_client, mod)
      end
    end)

    Application.put_env(:barkpark_cloud, :verify_http_client, FakeVerifyHttp)
  end

  # Wire the Vercel platform token + in-memory Fake client (vercel_test's
  # idiom — restored on exit).
  defp configure_vercel! do
    base = Application.get_env(:barkpark_cloud, Vercel, [])
    on_exit(fn -> Application.put_env(:barkpark_cloud, Vercel, base) end)

    Application.put_env(
      :barkpark_cloud,
      Vercel,
      Keyword.merge(base, client: Vercel.Fake, token: "vt_test_token")
    )
  end

  # A LIVE instance: url + host + encrypted admin token stored (what the
  # provision-succeed path writes) — the shape the lifecycle relays need.
  defp live_barkpark(team) do
    team
    |> barkpark_fixture(%{})
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> Repo.update!()
  end

  # …plus the dwb-4/5 bootstrap outputs site-url needs to find the
  # revalidation webhook on the instance.
  defp bootstrapped_barkpark(team) do
    team
    |> live_barkpark()
    |> Ecto.Changeset.change(
      template: "blog-starter",
      bootstrap_workspace: "acme",
      bootstrap_project: "default",
      bootstrap_dataset: "production",
      bootstrap_read_token_encrypted: Vault.encrypt("bp_read_secret")
    )
    |> Repo.update!()
  end

  # A vercel-deployable instance (vercel_test's fixture shape): deployable
  # template + bootstrap env stored. No live box needed — deploy_for reads
  # stored state only.
  defp vercel_ready_barkpark(team) do
    env = %{
      "BARKPARK_API_URL" => "https://acme.barkpark.cloud/w/acme/p/default",
      "BARKPARK_TOKEN" => "bp_read_supersecret",
      "BARKPARK_WORKSPACE" => "acme",
      "BARKPARK_PROJECT" => "default",
      "BARKPARK_DATASET" => "production",
      "BARKPARK_WEBHOOK_SECRET" => "whsec_test"
    }

    team
    |> barkpark_fixture(%{})
    |> Ecto.Changeset.change(
      template: "blog-starter",
      bootstrap_workspace: "acme",
      bootstrap_project: "default",
      bootstrap_dataset: "production",
      bootstrap_read_token_encrypted: Vault.encrypt("bp_read_supersecret"),
      bootstrap_env_encrypted: Vault.encrypt(Jason.encode!(env))
    )
    |> Repo.update!()
  end

  # The instance webhook-list response carrying the bootstrap-owned endpoint
  # (what wire_site_url LISTs before it PUTs).
  defp webhook_list_response do
    {:ok,
     %{
       status: 200,
       body:
         Jason.encode!(%{
           webhooks: [%{id: "wh_bootstrap_1", name: "bootstrap-revalidation", active: false}]
         })
     }}
  end

  defp find_events(team, action),
    do: team |> Accounts.list_audit_events() |> Enum.filter(&(&1.action == action))

  describe "lifecycle async triggers audit post-commit on the success branch" do
    test "POST retry writes barkpark.retry_requested; a not-retryable 409 writes none" do
      {user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "boom")

      conn = call(:post, "/v1/barkparks/#{bp.id}/retry", %{}, token)
      assert conn.status == 201

      assert [ev] = find_events(team, "barkpark.retry_requested")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id
      assert ev.metadata == %{"name" => bp.name}

      # The retry's own fresh job is now PENDING → a second retry 409s and
      # stamps nothing new (success branch only).
      dup = call(:post, "/v1/barkparks/#{bp.id}/retry", %{}, token)
      assert dup.status == 409
      assert length(find_events(team, "barkpark.retry_requested")) == 1
    end

    test "POST verify writes barkpark.verify_requested with the headline verdict, never a token" do
      swap_verify_client!()
      {user, team, token} = logged_in()
      bp = live_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/verify", nil, token)
      assert conn.status == 200

      assert [ev] = find_events(team, "barkpark.verify_requested")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id
      assert ev.metadata == %{"name" => bp.name, "reachable" => true}
      refute inspect(ev.metadata) =~ @instance_admin_token
    end

    test "POST studio-link writes barkpark.studio_link_minted — the mint, never the URL/ticket" do
      {user, team, token} = logged_in()
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 201, body: ~s({"ticket":"bplt_audit-ticket-1","expires_in":60})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/studio-link", nil, token)
      assert conn.status == 200

      assert [ev] = find_events(team, "barkpark.studio_link_minted")
      assert ev.actor_user_id == user.id
      assert ev.target_id == bp.id
      assert ev.metadata == %{"name" => bp.name}
      refute inspect(ev.metadata) =~ "bplt_"
      refute inspect(ev.metadata) =~ @instance_admin_token
    end

    test "a failed mint (transport error → 502) writes NO studio_link row" do
      {_user, team, token} = logged_in()
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([{:error, {:http_client, :timeout}}])

      conn = call(:post, "/v1/barkparks/#{bp.id}/studio-link", nil, token)
      assert conn.status == 502
      assert find_events(team, "barkpark.studio_link_minted") == []
    end

    test "POST self-update writes barkpark.self_update_triggered with the force flag" do
      {user, team, token} = logged_in()
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 202, body: ~s({"ok":true,"status":"started"})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/self-update", nil, token)
      assert conn.status == 202

      assert [ev] = find_events(team, "barkpark.self_update_triggered")
      assert ev.actor_user_id == user.id
      assert ev.target_id == bp.id
      assert ev.metadata == %{"name" => bp.name, "force" => false}
    end

    test "an instance 409 (already_running) writes NO self_update row" do
      {_user, team, token} = logged_in()
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 409, body: ~s({"error":{"code":"already_running"}})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/self-update", nil, token)
      assert conn.status == 409
      assert find_events(team, "barkpark.self_update_triggered") == []
    end

    test "POST rollback writes barkpark.rollback_triggered with the REPORTED sha + pin" do
      {user, team, token} = logged_in()
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 202, body: ~s({"status":"started","target_sha":"abc123def456"})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/rollback", nil, token)
      assert conn.status == 202

      assert [ev] = find_events(team, "barkpark.rollback_triggered")
      assert ev.actor_user_id == user.id
      assert ev.target_id == bp.id

      assert ev.metadata == %{
               "name" => bp.name,
               "target_sha" => "abc123def456",
               "pinned_release" => "abc123def456"
             }
    end

    test "an instance 409 (no_previous_slot) writes NO rollback row" do
      {_user, team, token} = logged_in()
      bp = live_barkpark(team)

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 409, body: ~s({"error":{"code":"no_previous_slot"}})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/rollback", nil, token)
      assert conn.status == 409
      assert find_events(team, "barkpark.rollback_triggered") == []
    end

    test "POST vercel-deploy writes barkpark.vercel_deploy_triggered — never the claim state" do
      configure_vercel!()
      {user, team, token} = logged_in()
      bp = vercel_ready_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/vercel-deploy", %{}, token)
      assert conn.status == 201

      assert [ev] = find_events(team, "barkpark.vercel_deploy_triggered")
      assert ev.actor_user_id == user.id
      assert ev.target_id == bp.id
      # The metadata is EXACTLY the instance name — no claim code / claim_url
      # (a bearer-shaped capability link) can ride along.
      assert ev.metadata == %{"name" => bp.name}
    end

    test "a bootstrap-less deploy (409) writes NO vercel_deploy row" do
      configure_vercel!()
      {_user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})

      conn = call(:post, "/v1/barkparks/#{bp.id}/vercel-deploy", %{}, token)
      assert conn.status == 409
      assert find_events(team, "barkpark.vercel_deploy_triggered") == []
    end

    test "POST /v1/resurrect writes barkpark.resurrected for the fresh row with the resolved bundle" do
      {user, team, token} = logged_in()
      {:ok, _sub} = Billing.subscribe(team, "supporter")

      conn =
        call(:post, "/v1/resurrect", %{name: "Shop", bundle_ref: @bundle}, token)

      assert conn.status == 202
      new_id = json_body(conn)["id"]

      assert [ev] = find_events(team, "barkpark.resurrected")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == new_id
      assert ev.metadata == %{"name" => "Shop", "bundle_ref" => @bundle}
    end
  end

  describe "lifecycle sync trio audits transactionally — no row on failure" do
    test "POST site-url writes barkpark.site_url_set with the wired URLs, never the admin token" do
      {user, team, token} = logged_in()
      bp = bootstrapped_barkpark(team)

      StudioLinkFakeHttpClient.program([
        webhook_list_response(),
        {:ok, %{status: 200, body: ~s({"webhook":{"id":"wh_bootstrap_1","active":true}})}}
      ])

      site = "https://acme-blog.vercel.app"
      conn = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: site}, token)
      assert conn.status == 200

      assert [ev] = find_events(team, "barkpark.site_url_set")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id

      assert ev.metadata == %{
               "site_url" => site,
               "webhook_url" => site <> "/api/barkpark/webhook"
             }

      refute inspect(ev.metadata) =~ @instance_admin_token
    end

    test "a failed wire (transport error → 502) writes NO site_url row" do
      {_user, team, token} = logged_in()
      bp = bootstrapped_barkpark(team)

      StudioLinkFakeHttpClient.program([{:error, {:http_client, :timeout}}])

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: "https://x.vercel.app"}, token)

      assert conn.status == 502
      assert find_events(team, "barkpark.site_url_set") == []
    end

    test "a non-http url (422) writes NO site_url row" do
      {_user, team, token} = logged_in()
      bp = bootstrapped_barkpark(team)

      conn = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: "ftp://nope"}, token)
      assert conn.status == 422
      assert find_events(team, "barkpark.site_url_set") == []
    end

    test "PATCH autoupdate writes barkpark.autoupdate_changed with the PERSISTED policy" do
      {user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})

      conn =
        call(:patch, "/v1/barkparks/#{bp.id}/autoupdate", %{autoupdate_enabled: false}, token)

      assert conn.status == 200

      assert [ev] = find_events(team, "barkpark.autoupdate_changed")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id

      assert ev.metadata == %{
               "enabled" => false,
               "paused" => false,
               "pinned_release" => nil
             }
    end

    test "an invalid autoupdate PATCH (422) writes NO row" do
      {_user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})

      conn =
        call(:patch, "/v1/barkparks/#{bp.id}/autoupdate", %{autoupdate_enabled: "nope"}, token)

      assert conn.status == 422
      assert find_events(team, "barkpark.autoupdate_changed") == []
    end

    test "POST domain writes barkpark.domain_attached with the persisted host" do
      {user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})
      host = "audited-#{System.unique_integer([:positive])}.barkpark.cloud"

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: host}, token)
      assert conn.status == 202

      assert [ev] = find_events(team, "barkpark.domain_attached")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "barkpark"
      assert ev.target_id == bp.id
      assert ev.metadata == %{"custom_host" => host}
    end

    test "an invalid domain (422) writes NO domain row" do
      {_user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: "not a host"}, token)
      assert conn.status == 422
      assert find_events(team, "barkpark.domain_attached") == []
    end

    test "a taken host (409) writes NO domain row for the loser" do
      {_user, team, token} = logged_in()
      bp = barkpark_fixture(team, %{})
      other = barkpark_fixture(team, %{})
      host = "claimed-#{System.unique_integer([:positive])}.barkpark.cloud"

      assert call(:post, "/v1/barkparks/#{other.id}/domain", %{domain: host}, token).status ==
               202

      conn = call(:post, "/v1/barkparks/#{bp.id}/domain", %{domain: host}, token)
      assert conn.status == 409

      # Exactly ONE row — the winner's; the refused attach stamped nothing.
      assert [ev] = find_events(team, "barkpark.domain_attached")
      assert ev.target_id == other.id
    end
  end
end
