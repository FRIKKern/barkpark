defmodule BarkparkCloud.Web.RouterAuditTest do
  @moduledoc """
  The audit read route (`GET /v1/audit`, ADMIN-gated) and the audited write
  seams: the router wraps each mutating route in `Accounts.audit/3` (or a
  best-effort post-commit `record_audit/1` for the Stripe webhook) so a
  successful mutation stamps exactly one correctly-shaped audit row, and a failed
  one stamps none. Driven via Plug.Test, mirroring RouterTest.
  """
  # async: false — the GitHub credential seams toggle the global
  # `BarkparkCloud.GitHub` app env to simulate a configured App (same reason the
  # dedicated GitHub router tests run non-async), so this module must not race a
  # parallel test reading `GitHub.configured?/0`.
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Billing
  alias BarkparkCloud.Billing.StubGateway
  alias BarkparkCloud.GitHub
  alias BarkparkCloud.GitHub.Fake
  alias BarkparkCloud.Registry
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

  defp site_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    bp = barkpark_fixture(team, %{})

    {:ok, site} =
      Registry.create_site(bp, Enum.into(attrs, %{name: "Site #{n}", slug: "site-#{n}"}))

    site
  end

  # Simulate a wired GitHub App (id + private key present) so `configured?/0` is
  # true; the client stays the in-memory Fake, so validation costs nothing. The
  # on_exit restores the base config (whole-module async: false makes this safe).
  defp configure_github do
    base = Application.get_env(:barkpark_cloud, GitHub, [])

    Application.put_env(
      :barkpark_cloud,
      GitHub,
      Keyword.merge(base, app_id: "test-app-id", private_key: "dummy-pem", app_slug: "bp-deploy")
    )

    on_exit(fn -> Application.put_env(:barkpark_cloud, GitHub, base) end)
  end

  defp events(team, action),
    do: team |> Accounts.list_audit_events() |> Enum.filter(&(&1.action == action))

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

  ## OC24 cluster A — credential / settings seams
  ##
  ## The secrets law is verified structurally, not just by shape: every credential
  ## route asserts the plaintext material (token / secret / value) is absent from
  ## the audit row's metadata.

  describe "provider connect seam" do
    test "POST /v1/providers writes provider.connected — kind+label only, NEVER the token" do
      {user, team, token} = logged_in()

      conn =
        call(
          :post,
          "/v1/providers",
          %{kind: "hetzner", token: "secret-hz-token", label: "main"},
          token
        )

      assert conn.status == 201

      assert [ev] = events(team, "provider.connected")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "provider"
      assert ev.metadata["kind"] == "hetzner"
      assert ev.metadata["label"] == "main"
      # The plaintext credential never reaches the audit row.
      refute Enum.any?(Map.values(ev.metadata), &(&1 == "secret-hz-token"))
      refute Map.has_key?(ev.metadata, "token")
      refute Map.has_key?(ev.metadata, "credential")
    end
  end

  describe "github credential seams" do
    test "POST /v1/github/installations writes github.installation_connected (login only)" do
      configure_github()
      {user, team, token} = logged_in()

      conn = call(:post, "/v1/github/installations", %{installation_id: "4242"}, token)
      assert conn.status == 201

      assert [ev] = events(team, "github.installation_connected")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "github_installation"
      assert is_binary(ev.metadata["account_login"])
      # The installation handle is stored encrypted, never in the audit row.
      refute Map.has_key?(ev.metadata, "installation_id")
    end

    test "DELETE /v1/github/installation writes github.installation_disconnected" do
      configure_github()
      {user, team, token} = logged_in()
      {:ok, _} = GitHub.record_installation(team, "4242")

      conn = call(:delete, "/v1/github/installation", nil, token)
      assert conn.status == 200

      assert [ev] = events(team, "github.installation_disconnected")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "github_installation"
    end

    test "a disconnect with NO installation 404s and writes NO row" do
      configure_github()
      {_user, team, token} = logged_in()

      conn = call(:delete, "/v1/github/installation", nil, token)
      assert conn.status == 404
      assert events(team, "github.installation_disconnected") == []
    end

    test "POST /v1/github/repos writes github.repo_pushed (repo + template + count)" do
      configure_github()
      {user, team, token} = logged_in()
      {:ok, _} = GitHub.record_installation(team, "4242")
      Fake.reset()

      conn =
        call(
          :post,
          "/v1/github/repos",
          %{template: "blog-starter", name: "my-blog", private: true},
          token
        )

      assert conn.status == 201

      assert [ev] = events(team, "github.repo_pushed")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "github_repo"
      assert ev.metadata["repo_full_name"] == "octo-4242/my-blog"
      assert ev.metadata["template"] == "blog-starter"
      assert ev.metadata["pushed"] > 0
    end
  end

  describe "env-var seams" do
    test "POST /v1/env-vars writes env_var.created — key name only, NEVER the value" do
      {user, team, token} = logged_in()

      conn =
        call(:post, "/v1/env-vars", %{key: "API_TOKEN", value: "super-secret", scope: "team"}, token)

      assert conn.status == 201

      assert [ev] = events(team, "env_var.created")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "env_var"
      assert ev.metadata["key"] == "API_TOKEN"
      # The plaintext value never reaches the audit row.
      refute Enum.any?(Map.values(ev.metadata), &(&1 == "super-secret"))
      refute Map.has_key?(ev.metadata, "value")
    end

    test "DELETE /v1/env-vars/:id writes env_var.deleted" do
      {_user, team, token} = logged_in()
      {:ok, ev} = Registry.put_env_var(team, %{key: "DELME", value: "v", scope: "team"})

      conn = call(:delete, "/v1/env-vars/#{ev.id}", nil, token)
      assert conn.status == 200

      assert [audit] = events(team, "env_var.deleted")
      assert audit.metadata["key"] == "DELME"
    end

    # Transactional no-row proof for the credential/settings family: the audit
    # rides put_env_var's transaction, so a write-once rejection rolls the audit
    # row back too — exactly one env_var.created event survives both POSTs.
    test "a write-once conflict 409s and writes NO second row" do
      {_user, team, token} = logged_in()

      assert call(:post, "/v1/env-vars", %{key: "ONCE", value: "v1", is_shown_once: true}, token).status ==
               201

      dup = call(:post, "/v1/env-vars", %{key: "ONCE", value: "v2"}, token)
      assert dup.status == 409
      assert length(events(team, "env_var.created")) == 1
    end
  end

  describe "notifications settings seams" do
    test "PUT /v1/notifications/settings writes notifications.settings_changed (field NAMES, no secret)" do
      {user, team, token} = logged_in()

      conn =
        call(
          :put,
          "/v1/notifications/settings",
          %{"alerts_enabled" => true, "smtp_password" => "hunter2"},
          token
        )

      assert conn.status == 200

      assert [ev] = events(team, "notifications.settings_changed")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "notification_settings"
      # The submitted field NAMES are recorded; the secret VALUE is not.
      assert "smtp_password" in ev.metadata["fields"]
      refute Enum.any?(List.flatten(Map.values(ev.metadata)), &(&1 == "hunter2"))
    end

    test "PUT /v1/notifications/channels writes notifications.channels_changed (type only, no creds)" do
      {_user, team, token} = logged_in()

      conn =
        call(
          :put,
          "/v1/notifications/channels",
          %{
            "type" => "slack",
            "enabled" => true,
            "credentials" => %{"url" => "https://hooks.slack.com/services/secret-hook"}
          },
          token
        )

      assert conn.status == 200

      assert [ev] = events(team, "notifications.channels_changed")
      assert ev.metadata["type"] == "slack"
      assert ev.metadata["enabled"] == true
      # The channel credentials (chat webhook URL) never reach the audit row.
      refute Map.has_key?(ev.metadata, "credentials")
      refute Enum.any?(Map.values(ev.metadata), &(&1 == "https://hooks.slack.com/services/secret-hook"))
    end

    test "PUT /v1/notifications/events writes notifications.events_changed" do
      {_user, team, token} = logged_in()

      conn =
        call(
          :put,
          "/v1/notifications/events",
          %{"event" => "provision_succeeded", "channels" => ["slack"]},
          token
        )

      assert conn.status == 200

      assert [ev] = events(team, "notifications.events_changed")
      assert ev.metadata["event"] == "provision_succeeded"
      assert ev.metadata["channels"] == ["slack"]
    end
  end

  ## OC24 cluster B — Sites consistency (create + promote already audit)

  describe "site sibling seams" do
    test "POST /v1/sites/:id/deploy writes site.deploy_requested for a freshly minted row" do
      {user, team, token} = logged_in()
      site = site_fixture(team)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/deploy",
          %{git_ref: "abc123", artifact_url: "file:///tmp/app.tgz"},
          token
        )

      assert conn.status == 201

      assert [ev] = events(team, "site.deploy_requested")
      assert ev.actor_user_id == user.id
      assert ev.target_type == "deployment"
      assert ev.metadata["site_id"] == site.id
      assert ev.metadata["git_ref"] == "abc123"
      assert ev.metadata["has_artifact"] == true
    end

    test "POST /v1/sites/:id/artifact writes site.artifact_uploaded (filename + bytes)" do
      {user, team, token} = logged_in()
      site = site_fixture(team)

      conn =
        conn(:post, "/v1/sites/#{site.id}/artifact", "tarball-bytes")
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Router.call(@opts)

      assert conn.status == 201

      assert [ev] = events(team, "site.artifact_uploaded")
      assert ev.actor_user_id == user.id
      assert ev.metadata["bytes"] > 0
      assert is_binary(ev.metadata["filename"])
    end

    test "POST /v1/sites/:id/env writes site.env_changed — key names only, NEVER the values" do
      {user, team, token} = logged_in()
      site = site_fixture(team)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/env",
          %{env: %{"DB_URL" => "postgres://secret", "API_KEY" => "sk-live"}},
          token
        )

      assert conn.status == 200

      assert [ev] = events(team, "site.env_changed")
      assert ev.actor_user_id == user.id
      assert Enum.sort(ev.metadata["keys"]) == ["API_KEY", "DB_URL"]
      refute Enum.any?(List.flatten(Map.values(ev.metadata)), &(&1 == "sk-live"))
    end

    test "POST /v1/sites/:id/domains writes site.domain_added" do
      {_user, team, token} = logged_in()
      site = site_fixture(team)

      conn = call(:post, "/v1/sites/#{site.id}/domains", %{domain: "shop.example.com"}, token)
      assert conn.status == 200

      assert [ev] = events(team, "site.domain_added")
      assert ev.metadata["domain"] == "shop.example.com"
    end

    # Transactional no-row proof for the Sites family: a cross-site domain
    # collision rolls the audit row back with the changeset.
    test "a domain collision 409s and writes NO site.domain_added row" do
      {_user, team, token} = logged_in()
      site_a = site_fixture(team)
      site_b = site_fixture(team)
      {:ok, _} = Registry.add_site_domain(site_a, "taken.example.com")

      conn = call(:post, "/v1/sites/#{site_b.id}/domains", %{domain: "taken.example.com"}, token)
      assert conn.status == 409
      assert events(team, "site.domain_added") == []
    end

    test "POST /v1/sites/:id/github writes site.github_connected — repo/branch, NEVER the secret" do
      {user, team, token} = logged_in()
      site = site_fixture(team)

      conn =
        call(
          :post,
          "/v1/sites/#{site.id}/github",
          %{repo: "octo/app", branch: "main", webhook_secret: "whsec-plaintext"},
          token
        )

      assert conn.status == 200

      assert [ev] = events(team, "site.github_connected")
      assert ev.actor_user_id == user.id
      assert ev.metadata["repo"] == "octo/app"
      assert ev.metadata["branch"] == "main"
      # The webhook secret never reaches the audit row.
      refute Enum.any?(Map.values(ev.metadata), &(&1 == "whsec-plaintext"))
      refute Map.has_key?(ev.metadata, "webhook_secret")
    end

    test "DELETE /v1/sites/:id/github writes site.github_disconnected" do
      {_user, team, token} = logged_in()
      site = site_fixture(team)
      {:ok, _} = Registry.set_site_github(site, "octo/app", "main", "whsec")

      conn = call(:delete, "/v1/sites/#{site.id}/github", nil, token)
      assert conn.status == 200

      assert [ev] = events(team, "site.github_disconnected")
      assert ev.metadata["repo"] == "octo/app"
    end
  end
end
