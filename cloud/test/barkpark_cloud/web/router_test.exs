defmodule BarkparkCloud.Web.RouterTest do
  @moduledoc """
  Drives the cloud-12a JSON API directly via Plug.Test — `conn(...)` built and
  run through `Router.call/2`, no live Bandit socket. Mirrors cloud-8/9's
  DataCase + Ecto sandbox setup.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob}
  alias BarkparkCloud.Billing.StubGateway
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

  # A user who belongs to a fresh team. Returns {user, team}.
  defp user_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
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

  # POST a RAW (already-serialized) body with arbitrary extra headers — used for
  # the webhook, where the body must reach the handler as unparsed bytes and the
  # signature rides in a custom header.
  defp call_raw(method, path, raw_body, headers) do
    conn =
      conn(method, path, raw_body)
      |> put_req_header("content-type", "application/json")

    conn =
      Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # A Stripe-shaped checkout.session.completed event whose SIGNED metadata
  # carries team_id + plan — the shape handle_webhook/2 reads activation from.
  defp checkout_completed_event(team_id, plan) do
    Jason.encode!(%{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => "checkout.session.completed",
      "data" => %{"object" => %{"metadata" => %{"team_id" => team_id, "plan" => plan}}}
    })
  end

  ## POST /v1/auth/login

  describe "POST /v1/auth/login" do
    test "right password → 200 {token, team_id}" do
      {user, team} = user_with_team()

      conn = call(:post, "/v1/auth/login", %{email: user.email, password: @password})

      assert conn.status == 200
      body = json_body(conn)
      assert is_binary(body["token"])
      assert body["team_id"] == team.id

      # The minted token actually authenticates.
      assert %{} = Accounts.verify_user_session_token(body["token"])
    end

    test "wrong password → 401" do
      user = user_fixture()

      conn = call(:post, "/v1/auth/login", %{email: user.email, password: "nope-nope-nope"})

      assert conn.status == 401
      assert json_body(conn)["error"] == "invalid_credentials"
    end

    test "unknown email → 401 (no token)" do
      conn = call(:post, "/v1/auth/login", %{email: "nobody@example.com", password: @password})
      assert conn.status == 401
    end

    test "login for a user with no team → 200 with team_id: null" do
      user = user_fixture()
      conn = call(:post, "/v1/auth/login", %{email: user.email, password: @password})
      assert conn.status == 200
      assert json_body(conn)["team_id"] == nil
      assert is_binary(json_body(conn)["token"])
    end
  end

  ## POST /v1/auth/register

  describe "POST /v1/auth/register" do
    test "happy path → 201 + user + team + owner membership + working token" do
      email = "ada-#{System.unique_integer([:positive])}@example.com"

      conn = call(:post, "/v1/auth/register", %{email: email, password: @password})

      assert conn.status == 201
      body = json_body(conn)
      assert is_binary(body["token"])
      assert is_binary(body["team_id"])

      # The user landed (citext: stored lowercased), with no plaintext password.
      user = Accounts.get_user_by_email(email)
      assert user != nil
      assert user.email == String.downcase(email)
      assert is_binary(user.hashed_password)

      # A team was created and the user owns it.
      team = Accounts.get_team(body["team_id"])
      assert team != nil
      membership = Accounts.get_membership(team, user)
      assert membership != nil
      assert membership.role == "owner"

      # The team slug derives from the email local-part.
      assert team.slug == email |> String.split("@") |> List.first() |> String.downcase()

      # The returned token actually authenticates the just-created user.
      assert %{id: uid} = Accounts.verify_user_session_token(body["token"])
      assert uid == user.id
    end

    test "the returned token authenticates a subsequent /v1/barkparks call" do
      email = "tok-#{System.unique_integer([:positive])}@example.com"
      conn = call(:post, "/v1/auth/register", %{email: email, password: @password})
      assert conn.status == 201
      token = json_body(conn)["token"]

      # Use the registration token directly against an authenticated route.
      barkparks_conn = call(:get, "/v1/barkparks", nil, token)
      assert barkparks_conn.status == 200
      # A brand-new team has no barkparks yet — but the call was authorized.
      assert json_body(barkparks_conn)["barkparks"] == []
    end

    test "explicit team_name → that name, slugified" do
      email = "named-#{System.unique_integer([:positive])}@example.com"

      conn =
        call(:post, "/v1/auth/register", %{
          email: email,
          password: @password,
          team_name: "Ada's Lab"
        })

      assert conn.status == 201
      team = Accounts.get_team(json_body(conn)["team_id"])
      assert team.name == "Ada's Lab"
      assert team.slug == "ada-s-lab"
    end

    test "duplicate team slug is deduped, not a 500" do
      # Pre-seed a team owning the slug a fresh local-part would derive.
      _existing = team_fixture(%{name: "dupe", slug: "dupe"})

      conn =
        call(:post, "/v1/auth/register", %{
          email: "dupe@example.com",
          password: @password,
          team_name: "dupe"
        })

      assert conn.status == 201
      team = Accounts.get_team(json_body(conn)["team_id"])
      # Slug "dupe" was taken → deduped to "dupe-2".
      assert team.slug == "dupe-2"
    end

    test "duplicate email → 409 email_taken" do
      email = "taken-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.register_user(%{email: email, password: @password})

      conn = call(:post, "/v1/auth/register", %{email: email, password: @password})

      assert conn.status == 409
      assert json_body(conn)["error"] == "email_taken"
    end

    test "duplicate email is case-insensitive → 409" do
      {:ok, _user} = Accounts.register_user(%{email: "Mixed@Example.com", password: @password})

      conn = call(:post, "/v1/auth/register", %{email: "mixed@example.com", password: @password})
      assert conn.status == 409
      assert json_body(conn)["error"] == "email_taken"
    end

    test "weak/short password → 422" do
      conn =
        call(:post, "/v1/auth/register", %{
          email: "short-#{System.unique_integer([:positive])}@example.com",
          password: "short"
        })

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "password_invalid"
      assert body["details"]["password"]
    end

    test "bad email → 422" do
      conn =
        call(:post, "/v1/auth/register", %{email: "no-at-sign", password: @password})

      assert conn.status == 422
      assert json_body(conn)["error"] == "email_invalid"
    end

    test "missing email/password → 422 validation_failed" do
      conn = call(:post, "/v1/auth/register", %{password: @password})
      assert conn.status == 422
      assert json_body(conn)["error"] == "validation_failed"
    end

    test "team_name with a NUL/control byte → 422, not a 500 (Postgrex 22021 guard)" do
      # A NUL byte (0x00) in team_name is invalid UTF-8 for a Postgres text
      # column. Unsanitized it reaches the teams INSERT and Postgres raises
      # 22021 character_not_in_repertoire — an uncaught Postgrex error that would
      # escape register/3 as an HTTP 500 on this UNAUTHENTICATED surface. The
      # Team.changeset control-char validation must turn it into a clean 422.
      email = "nul-#{System.unique_integer([:positive])}@example.com"

      conn =
        call(:post, "/v1/auth/register", %{
          email: email,
          password: @password,
          team_name: "evil" <> <<0>> <> "name"
        })

      assert conn.status == 422
      body = json_body(conn)
      # Single offending field → "name_invalid" (the contract's <field>_invalid).
      assert body["error"] in ["name_invalid", "validation_failed"]
      # The transaction rolled back — no orphan user committed.
      assert Accounts.get_user_by_email(email) == nil
    end

    test "team_name with a TAB control char → 422, not a 500" do
      email = "tab-#{System.unique_integer([:positive])}@example.com"

      conn =
        call(:post, "/v1/auth/register", %{
          email: email,
          password: @password,
          team_name: "tab\tinjected"
        })

      assert conn.status == 422
      assert Accounts.get_user_by_email(email) == nil
    end

    test "rollback: a failed membership leaves no orphan user or team" do
      # Force add_member to fail by colliding the (user, team) unique. We can't
      # easily do that mid-transaction from outside, so instead drive a team_name
      # whose slug is reserved → create_team fails → the whole transaction rolls
      # back, leaving NO user behind even though register_user ran first.
      email = "orphan-#{System.unique_integer([:positive])}@example.com"

      conn =
        call(:post, "/v1/auth/register", %{
          email: email,
          password: @password,
          team_name: "admin"
        })

      # "admin" is a reserved slug → create_team rejects → 422, transaction rolls
      # back.
      assert conn.status == 422
      # The user was NOT committed — the transaction rolled the insert back.
      assert Accounts.get_user_by_email(email) == nil
    end
  end

  ## GET /v1/barkparks

  describe "GET /v1/barkparks" do
    test "valid session token → the team's barkparks" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team, %{name: "Prod", slug: "prod"})
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/barkparks", nil, token)

      assert conn.status == 200
      [row] = json_body(conn)["barkparks"]
      assert row["id"] == bp.id
      assert row["slug"] == "prod"
      assert row["health_status"] == "unknown"
      assert row["team_id"] == team.id
    end

    test "no token → 401" do
      conn = call(:get, "/v1/barkparks")
      assert conn.status == 401
      assert json_body(conn)["error"] == "unauthorized"
    end

    test "bad token → 401" do
      conn = call(:get, "/v1/barkparks", nil, "not-a-real-token")
      assert conn.status == 401
    end

    test "team isolation: user A never sees team B's barkparks" do
      {user_a, team_a} = user_with_team()
      {_user_b, team_b} = user_with_team()

      _own = barkpark_fixture(team_a, %{name: "A-own", slug: "a-own"})
      _other = barkpark_fixture(team_b, %{name: "B-secret", slug: "b-secret"})

      {:ok, token_a} = Accounts.create_user_session_token(user_a)
      conn = call(:get, "/v1/barkparks", nil, token_a)

      slugs = conn |> json_body() |> Map.fetch!("barkparks") |> Enum.map(& &1["slug"])
      assert slugs == ["a-own"]
      refute "b-secret" in slugs
    end

    test "an AGENT token cannot satisfy a USER route → 401" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_plaintext, _} = Registry.mint_agent_token(bp, "report")

      conn = call(:get, "/v1/barkparks", nil, agent_plaintext)
      assert conn.status == 401
    end
  end

  ## POST /v1/agent/report

  describe "POST /v1/agent/report" do
    # The cloud-10 report body shape (internal/agent/report.go).
    defp report_body(overrides \\ %{}) do
      Map.merge(
        %{
          "agent_status" => "online",
          "version" => "0.1.0",
          "git_commit" => "abc123def",
          "dirty_tree" => false,
          "health_status" => "up",
          "disk_used_percent" => 41,
          "pg_size_bytes" => 123_456_789,
          "backup_ok" => true,
          "backup_detail" => "fresh",
          "health_checks" => []
        },
        overrides
      )
    end

    test "valid agent token → 200 + the barkpark's health row updated + an event" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")

      conn = call(:post, "/v1/agent/report", report_body(), agent_token)

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      reloaded = Registry.get_barkpark(bp.id)
      assert reloaded.health_status == "up"
      assert reloaded.agent_status == "online"
      assert reloaded.version == "0.1.0"
      assert reloaded.git_commit == "abc123def"
      assert reloaded.last_seen_at != nil

      # The report was recorded as an event.
      assert [event | _] = Registry.recent_events(bp, 5)
      assert event.type == "health"
      assert event.payload["disk_used_percent"] == 41
    end

    test "bad agent token → 401 (no health update)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      conn = call(:post, "/v1/agent/report", report_body(), "bogus-agent-token")
      assert conn.status == 401

      # Untouched.
      assert Registry.get_barkpark(bp.id).health_status == "unknown"
    end

    test "no token → 401" do
      conn = call(:post, "/v1/agent/report", report_body())
      assert conn.status == 401
    end

    test "an out-of-enum health_status is normalized to unknown, not a crash" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")

      conn =
        call(:post, "/v1/agent/report", report_body(%{"health_status" => "weird"}), agent_token)

      assert conn.status == 200
      assert Registry.get_barkpark(bp.id).health_status == "unknown"
    end

    test "a USER session token cannot satisfy an AGENT route → 401" do
      {user, _team} = user_with_team()
      {:ok, user_token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/agent/report", report_body(), user_token)
      assert conn.status == 401
    end
  end

  ## GET /v1/agent/commands  +  POST /v1/agent/results

  describe "agent commands + results" do
    test "GET /v1/agent/commands → 200 [] (empty queue)" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")

      conn = call(:get, "/v1/agent/commands", nil, agent_token)
      assert conn.status == 200
      assert json_body(conn) == []
    end

    test "GET /v1/agent/commands with no token → 401" do
      conn = call(:get, "/v1/agent/commands")
      assert conn.status == 401
    end

    test "POST /v1/agent/results → 200 ok" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")

      results = [%{"id" => "1", "name" => "restart", "approved" => true, "output" => "ok"}]
      conn = call(:post, "/v1/agent/results", results, agent_token)
      assert conn.status == 200
      assert json_body(conn)["ok"] == true
    end
  end

  ## POST /v1/providers

  describe "POST /v1/providers" do
    test "valid session token → 201 connected provider (token never echoed)" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn =
        call(
          :post,
          "/v1/providers",
          %{kind: "hetzner", token: "secret-hetzner-token", label: "main"},
          token
        )

      assert conn.status == 201
      provider = json_body(conn)["provider"]
      assert provider["kind"] == "hetzner"
      assert provider["label"] == "main"
      # The plaintext token is NOT in the response.
      refute Map.has_key?(provider, "token")
      refute Map.has_key?(provider, "encrypted_token")
      refute conn.resp_body =~ "secret-hetzner-token"
    end

    test "no token → 401" do
      conn = call(:post, "/v1/providers", %{kind: "hetzner", token: "x"})
      assert conn.status == 401
    end

    test "invalid kind → 422" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/providers", %{kind: "aws", token: "x"}, token)
      assert conn.status == 422
    end
  end

  ## POST /v1/billing/checkout

  describe "POST /v1/billing/checkout" do
    test "authed team + a priced plan → 200 {checkout_url}" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/billing/checkout", %{plan: "pro"}, token)

      assert conn.status == 200
      url = json_body(conn)["checkout_url"]
      # The Stub's deterministic url is the SHA-256 of team_id<>plan — proving the
      # AUTHED team_id (never a client value) is what was passed to the gateway.
      expected_sha =
        :crypto.hash(:sha256, team.id <> "pro") |> Base.encode16(case: :lower)

      assert url == "https://checkout.stub/" <> expected_sha
    end

    test "the checkout uses the AUTHED team — a client-supplied team_id is ignored" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      # Even if the client tries to smuggle a different team_id in the body, the
      # url is keyed to the AUTHED team's id.
      conn =
        call(:post, "/v1/billing/checkout", %{plan: "starter", team_id: "attacker-team"}, token)

      assert conn.status == 200

      expected_sha =
        :crypto.hash(:sha256, team.id <> "starter") |> Base.encode16(case: :lower)

      assert json_body(conn)["checkout_url"] == "https://checkout.stub/" <> expected_sha
    end

    test "the free plan needs no checkout → 422 plan_invalid" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/billing/checkout", %{plan: "free"}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "plan_invalid"
    end

    test "an unknown plan → 422 plan_invalid" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/billing/checkout", %{plan: "enterprise"}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "plan_invalid"
    end

    test "no token → 401" do
      conn = call(:post, "/v1/billing/checkout", %{plan: "pro"})
      assert conn.status == 401
    end
  end

  ## POST /v1/billing/webhook  (unauthenticated but signature-verified)

  describe "POST /v1/billing/webhook" do
    test "a VALID signature on a checkout.session.completed event activates the subscription" do
      {_user, team} = user_with_team()
      assert is_nil(Billing.active_subscription(team))

      raw = checkout_completed_event(team.id, "pro")

      conn =
        call_raw(:post, "/v1/billing/webhook", raw, [
          {"stripe-signature", StubGateway.test_signature()}
        ])

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      # The team is now actively subscribed on the signed plan.
      sub = Billing.active_subscription(team)
      assert sub != nil
      assert sub.plan == "pro"
      assert sub.status == "active"
    end

    test "an INVALID signature → 400 invalid_signature and NO subscription created" do
      {_user, team} = user_with_team()
      raw = checkout_completed_event(team.id, "pro")

      conn =
        call_raw(:post, "/v1/billing/webhook", raw, [{"stripe-signature", "forged-sig"}])

      assert conn.status == 400
      assert json_body(conn)["error"] == "invalid_signature"
      # A forged webhook grants NOTHING.
      assert is_nil(Billing.active_subscription(team))
    end

    test "a MISSING signature → 400 and NO subscription created" do
      {_user, team} = user_with_team()
      raw = checkout_completed_event(team.id, "pro")

      conn = call_raw(:post, "/v1/billing/webhook", raw, [])

      assert conn.status == 400
      assert is_nil(Billing.active_subscription(team))
    end

    test "a repeated valid event is idempotent — it does not double-subscribe" do
      {_user, team} = user_with_team()
      raw = checkout_completed_event(team.id, "pro")
      sig = [{"stripe-signature", StubGateway.test_signature()}]

      conn1 = call_raw(:post, "/v1/billing/webhook", raw, sig)
      assert conn1.status == 200
      sub1 = Billing.active_subscription(team)
      assert sub1 != nil

      # Same event again → still 200, still exactly ONE active subscription row.
      conn2 = call_raw(:post, "/v1/billing/webhook", raw, sig)
      assert conn2.status == 200
      assert Billing.active_subscription(team).id == sub1.id

      count =
        Repo.aggregate(
          from(s in Billing.Subscription, where: s.team_id == ^team.id),
          :count
        )

      assert count == 1
    end
  end

  ## POST /v1/go-live  (and its /v1/launch alias) — gated on an active subscription

  describe "POST /v1/go-live" do
    # Give `team` an active subscription so go-live's gate passes.
    defp subscribe!(team, plan \\ "pro") do
      {:ok, _sub} = Billing.subscribe(team, plan)
      :ok
    end

    test "WITH an active subscription → 201, a provisioning barkpark row + a job enqueued" do
      {user, team} = user_with_team()
      :ok = subscribe!(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      assert Registry.list_barkparks(team) == []
      assert Repo.aggregate(ProvisionJob, :count) == 0

      conn = call(:post, "/v1/go-live", %{name: "My Prod", plan: "pro"}, token)

      assert conn.status == 201
      bp = json_body(conn)["barkpark"]
      assert bp["name"] == "My Prod"
      assert bp["slug"] == "my-prod"
      assert bp["mode"] == "managed"
      # Honest provisioning state — nothing is live yet (cloud-12b provisions).
      assert bp["health_status"] == "unknown"
      assert bp["agent_status"] == "offline"

      # The row really landed, scoped to the team, and a provision job enqueued.
      assert [%Barkpark{slug: "my-prod"}] = Registry.list_barkparks(team)
      assert Repo.aggregate(ProvisionJob, :count) == 1
    end

    test "NO active subscription → 402 no_active_subscription + NOTHING provisioned" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/go-live", %{name: "My Prod", plan: "pro"}, token)

      assert conn.status == 402
      body = json_body(conn)
      assert body["error"] == "no_active_subscription"
      assert body["checkout_path"] == "/v1/billing/checkout"

      # Provision NOTHING — no barkpark row, no provision job.
      assert Registry.list_barkparks(team) == []
      assert Repo.aggregate(ProvisionJob, :count) == 0
    end

    test "/v1/launch is an alias of go-live (also gated on a subscription)" do
      {user, team} = user_with_team()
      :ok = subscribe!(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/launch", %{provider: "hetzner", name: "Launched"}, token)
      assert conn.status == 201
      assert json_body(conn)["barkpark"]["slug"] == "launched"
      assert [%Barkpark{slug: "launched"}] = Registry.list_barkparks(team)
    end

    test "/v1/launch with NO subscription → 402" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/launch", %{provider: "hetzner", name: "Launched"}, token)
      assert conn.status == 402
      assert json_body(conn)["error"] == "no_active_subscription"
    end

    test "missing name (but subscribed) → 422" do
      {user, team} = user_with_team()
      :ok = subscribe!(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/go-live", %{plan: "pro"}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "name_required"
    end

    test "no token → 401" do
      conn = call(:post, "/v1/go-live", %{name: "X"})
      assert conn.status == 401
    end
  end

  ## Catch-all

  test "an unknown route → 404 JSON" do
    conn = call(:get, "/v1/nope")
    assert conn.status == 404
    assert json_body(conn)["error"] == "not_found"
  end

  ## Dashboard SPA — GET / and /dashboard serve the static single-page app, and
  ## Plug.Static MUST NOT shadow the JSON /v1/* routes.

  describe "dashboard SPA" do
    defp content_type(conn) do
      case get_resp_header(conn, "content-type") do
        [ct | _] -> ct
        _ -> nil
      end
    end

    test "GET / → 200 text/html serving the dashboard shell" do
      conn = call(:get, "/")

      assert conn.status == 200
      assert content_type(conn) =~ "text/html"
      assert conn.resp_body =~ "Barkpark Cloud"
      # The SPA wires up the three asset files.
      assert conn.resp_body =~ "/app.css"
      assert conn.resp_body =~ "/app.js"
    end

    test "GET /dashboard → 200 text/html (deep-link / refresh lands the SPA)" do
      conn = call(:get, "/dashboard")

      assert conn.status == 200
      assert content_type(conn) =~ "text/html"
      assert conn.resp_body =~ "Barkpark Cloud"
    end

    test "GET /index.html → 200 served by Plug.Static" do
      conn = call(:get, "/index.html")

      assert conn.status == 200
      assert content_type(conn) =~ "text/html"
      assert conn.resp_body =~ "Barkpark Cloud"
    end

    test "GET /app.css → 200 text/css from priv/static" do
      conn = call(:get, "/app.css")

      assert conn.status == 200
      assert content_type(conn) =~ "text/css"
      # A token from the stylesheet proves the real file was served.
      assert conn.resp_body =~ "--primary"
    end

    test "GET /app.js → 200 javascript from priv/static" do
      conn = call(:get, "/app.js")

      assert conn.status == 200
      assert content_type(conn) =~ "javascript"
      assert conn.resp_body =~ "Barkpark Cloud"
    end

    test "Plug.Static does NOT shadow the JSON API — /v1 routes still return JSON" do
      # A /v1 route is served by the matchers, not Plug.Static (which excludes
      # "v1" from its allowlist). Unauthorized here is the JSON 401, proving the
      # request reached the router's auth, not a static 404.
      conn = call(:get, "/v1/barkparks")

      assert conn.status == 401
      assert content_type(conn) =~ "application/json"
      assert json_body(conn)["error"] == "unauthorized"
    end

    test "an unknown non-asset path still falls through to the JSON 404" do
      conn = call(:get, "/not-an-asset")

      assert conn.status == 404
      assert content_type(conn) =~ "application/json"
      assert json_body(conn)["error"] == "not_found"
    end
  end
end
