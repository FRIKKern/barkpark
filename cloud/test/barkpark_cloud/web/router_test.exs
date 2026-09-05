defmodule BarkparkCloud.Web.RouterTest do
  @moduledoc """
  Drives the cloud-12a JSON API directly via Plug.Test — `conn(...)` built and
  run through `Router.call/2`, no live Bandit socket. Mirrors cloud-8/9's
  DataCase + Ecto sandbox setup.
  """
  # async: false — this module swaps node-global env
  # (`:barkpark_cloud, :platform_admin_emails`), which is ONE value for the whole
  # node: while held, every concurrent async test sees that operator allowlist.
  # Ratchet: scripts/async_env_seam_scan.exs.
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn
  import Ecto.Query, only: [from: 2]

  alias BarkparkCloud.{Accounts, Billing, Events, Notifications, Registry, Repo}
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob}
  alias BarkparkCloud.Billing.StubGateway
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  # The register handler spends the node-global "register:" ETS bucket on EVERY
  # call (arpss w3 — the check precedes validation by design), and Plug.Test
  # conns all arrive as 127.0.0.1, so this module's register calls accumulate
  # against ONE 30/60s budget across the whole run. Today's call count keeps the
  # margin, but a mystery 429 in an unrelated register test is the worst kind of
  # flake — start every test with a clean limiter. async: false (above), so no
  # concurrent spender races the reset.
  setup do
    BarkparkCloud.DeviceAuth.RateLimiter.reset()
    :ok
  end

  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"

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

  # dwb-13: spend a team's ONE free trial (ledger stamped in the past, no live
  # sub) so go-live's auto-start returns :trial_used and the 402 gate stands.
  defp exhaust_trial(team) do
    past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:microsecond)

    {1, _} =
      Repo.update_all(
        from(t in BarkparkCloud.Accounts.Team, where: t.id == ^team.id),
        set: [trial_started_at: past, trial_ends_at: past]
      )

    :ok
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

  # Count a barkpark's ACTIVE (pending|claimed) provision jobs — bounded to at
  # most one by the dwb-11 one-active-job index. "Never two boxes" == this == 1.
  defp active_provisions(bp) do
    from(j in ProvisionJob,
      where:
        j.barkpark_id == ^bp.id and j.kind == "provision" and
          j.status in ["pending", "claimed"]
    )
    |> Repo.aggregate(:count, :id)
  end

  # A Stripe-shaped checkout.session.completed event whose SIGNED metadata
  # carries team_id + plan — the shape handle_webhook/2 reads activation from.
  defp checkout_completed_event(team_id, plan) do
    Jason.encode!(%{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => "checkout.session.completed",
      "data" => %{"object" => %{"metadata" => %{"team_id" => team_id, "plan" => plan}}}
    })
  end

  # A Stripe-shaped invoice.payment_failed event keyed on the gateway customer id
  # — the dunning trigger that marks the live sub past_due.
  defp payment_failed_event(customer_id) do
    Jason.encode!(%{
      "id" => "evt_#{System.unique_integer([:positive])}",
      "type" => "invoice.payment_failed",
      "data" => %{"object" => %{"customer" => customer_id}}
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

    test "a fresh signup is granted a free trial and is immediately entitled (BILL-1)" do
      email = "trial-#{System.unique_integer([:positive])}@example.com"
      conn = call(:post, "/v1/auth/register", %{email: email, password: @password})
      assert conn.status == 201

      team = Accounts.get_team(json_body(conn)["team_id"])

      # Entitled the instant they sign up — no operator/SSH, no card.
      assert Billing.entitled?(team)

      # The grant is a trial: active, no gateway ids, a future period end.
      sub = Billing.live_subscription(team)
      assert sub.plan == "trial"
      assert sub.status == "active"
      assert is_nil(sub.gateway_customer_id)
      assert is_nil(sub.gateway_subscription_id)
      assert sub.current_period_end
      assert DateTime.compare(sub.current_period_end, DateTime.utc_now()) == :gt
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

    test "the fleet row carries the reachability counters (cch-w34-s2)" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team, %{name: "Prod", slug: "prod"})
      {:ok, token} = Accounts.create_user_session_token(user)

      # A fresh row: BOTH keys present, carrying their honest zero/false — a
      # client can state "0 missed heartbeat windows", not infer it.
      conn = call(:get, "/v1/barkparks", nil, token)
      [row] = json_body(conn)["barkparks"]
      assert Map.has_key?(row, "unreachable_count")
      assert Map.has_key?(row, "unreachable_notification_sent")
      assert row["unreachable_count"] == 0
      assert row["unreachable_notification_sent"] == false

      # After the staleness sweep has bumped and latched, the counters are the
      # evidence behind the health axis.
      {:ok, bumped} = Registry.bump_unreachable(bp)
      {:ok, _} = Registry.mark_offline(bumped)

      conn2 = call(:get, "/v1/barkparks", nil, token)
      [row2] = json_body(conn2)["barkparks"]
      assert row2["unreachable_count"] == 1
      assert row2["unreachable_notification_sent"] == true
      assert row2["health_status"] == "unknown"
    end

    test "the fleet row carries the BP-ONB-09 verify verdict fields" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team, %{name: "Prod", slug: "prod"})
      {:ok, token} = Accounts.create_user_session_token(user)

      # A never-verified row: barkpark_json still carries BOTH keys, honest NULL.
      conn = call(:get, "/v1/barkparks", nil, token)
      [row] = json_body(conn)["barkparks"]
      assert Map.has_key?(row, "verify_reachable")
      assert Map.has_key?(row, "last_verified_at")
      assert is_nil(row["verify_reachable"])
      assert is_nil(row["last_verified_at"])

      # After a persisted verdict the fleet row reflects it.
      {:ok, _} =
        Registry.record_verify_result(bp, %{
          reachable: true,
          verified_at: "2026-07-16T00:00:00.000000Z"
        })

      conn2 = call(:get, "/v1/barkparks", nil, token)
      [row2] = json_body(conn2)["barkparks"]
      assert row2["verify_reachable"] == true
      assert row2["last_verified_at"] =~ "2026-07-16"
    end

    # jpf-w1-queue-age-alarm (charter D6): the fleet row carries the age of the
    # oldest never-claimed queued container deployment — a NUMBER, nil when
    # none — computed by Registry.queued_deploy_age_map/1, ONE GROUP BY for the
    # whole list. The stalled VERDICT belongs to the clients (Go/SPA at 300s);
    # this payload only states the raw fact.
    test "producer-backed Go attention fixture stays fresh against queued_deploy_age_seconds" do
      fixture_path =
        Path.expand("../../../../internal/cli/testdata/attention_order_cases.json", __DIR__)

      fixture = fixture_path |> File.read!() |> Jason.decode!()
      fixture_rows = fixture["barkparks"]
      stalled_fixture = Enum.find(fixture_rows, &(&1["name"] == "stall-1"))
      young_fixture = Enum.find(fixture_rows, &(&1["name"] == "Zeta"))
      empty_fixture = Enum.find(fixture_rows, &(&1["name"] == "alpha"))

      assert length(fixture_rows) == 16

      assert Enum.all?(fixture_rows, &Map.has_key?(&1, "queued_deploy_age_seconds")),
             "every Go ranking row must preserve the field the producer always emits"

      assert fixture_rows
             |> Enum.map(& &1["queued_deploy_age_seconds"])
             |> Enum.reject(&is_nil/1)
             |> Enum.sort() == [90, 420]

      {user, team} = user_with_team()

      bp =
        barkpark_fixture(team, %{
          name: stalled_fixture["name"],
          slug: "stall-1",
          host: stalled_fixture["host"],
          health_status: stalled_fixture["health_status"],
          agent_status: stalled_fixture["agent_status"],
          last_seen_at: stalled_fixture["last_seen_at"]
        })

      {:ok, token} = Accounts.create_user_session_token(user)

      # No sites, no deployments: the key is PRESENT and honestly nil — "none
      # queued" must be distinguishable from a field that was never emitted.
      conn = call(:get, "/v1/barkparks", nil, token)
      [row] = json_body(conn)["barkparks"]

      assert Map.take(row, ["queued_deploy_age_seconds"]) ==
               Map.take(empty_fixture, ["queued_deploy_age_seconds"])

      # TWO SITES on the box (the active-deployment unique index allows only
      # ONE active production row per site), 7 minutes and 2 minutes queued:
      # the aggregate must name the OLDEST row's age across the whole box
      # (max age == min inserted_at over the Deployment→Site join).
      {:ok, site_a} = Registry.create_site(bp, %{name: "S1", slug: "s1"})
      {:ok, site_b} = Registry.create_site(bp, %{name: "S2", slug: "s2"})

      {:ok, d_old} =
        Registry.create_deployment(site_a, %{
          git_ref: "old-sha",
          artifact_url: "file:///tmp/a.tgz"
        })

      {:ok, d_new} =
        Registry.create_deployment(site_b, %{
          git_ref: "new-sha",
          artifact_url: "file:///tmp/b.tgz"
        })

      backdate = fn id, seconds ->
        ts = DateTime.add(DateTime.utc_now(), -seconds, :second)

        {1, _} =
          Repo.update_all(
            from(d in BarkparkCloud.Registry.Deployment, where: d.id == ^id),
            set: [inserted_at: ts]
          )
      end

      backdate.(d_old.id, 420)
      backdate.(d_new.id, 120)

      conn2 = call(:get, "/v1/barkparks", nil, token)
      [row2] = json_body(conn2)["barkparks"]
      age = row2["queued_deploy_age_seconds"]
      assert is_integer(age), "expected a number, got: #{inspect(age)}"
      assert age >= 420 and age < 480, "oldest row is ~420s old, got #{age}"

      projection_keys =
        ~w(name host health_status agent_status queued_deploy_age_seconds)

      normalized_producer_row =
        Map.put(row2, "queued_deploy_age_seconds", stalled_fixture["queued_deploy_age_seconds"])

      assert Map.take(normalized_producer_row, projection_keys) ==
               Map.take(stalled_fixture, projection_keys)

      # Once the stalled rows leave "queued", a real young row supplies the
      # fixture's below-fence arm through the same producer serialization.
      {:ok, _} = Registry.transition_deployment(d_old, %{status: "building"})
      {:ok, _} = Registry.transition_deployment(d_new, %{status: "building"})

      {:ok, site_young} = Registry.create_site(bp, %{name: "S3", slug: "s3"})

      {:ok, d_young} =
        Registry.create_deployment(site_young, %{
          git_ref: "young-sha",
          artifact_url: "file:///tmp/c.tgz"
        })

      backdate.(d_young.id, 90)

      conn3 = call(:get, "/v1/barkparks", nil, token)
      [row3] = json_body(conn3)["barkparks"]
      young_age = row3["queued_deploy_age_seconds"]
      assert is_integer(young_age), "expected a number, got: #{inspect(young_age)}"
      assert young_age >= 90 and young_age < 150, "young row is ~90s old, got #{young_age}"

      normalized_young_row =
        Map.put(row3, "queued_deploy_age_seconds", young_fixture["queued_deploy_age_seconds"])

      assert Map.take(normalized_young_row, ["queued_deploy_age_seconds"]) ==
               Map.take(young_fixture, ["queued_deploy_age_seconds"])

      # Status filter has TEETH: once every queued row leaves "queued" the field
      # returns to nil — a "building" row is the reaper's business, not this
      # alarm's. (This is the arm that reds if the WHERE clause is dropped.)
      {:ok, _} = Registry.transition_deployment(d_young, %{status: "building"})

      conn4 = call(:get, "/v1/barkparks", nil, token)
      [row4] = json_body(conn4)["barkparks"]
      assert is_nil(row4["queued_deploy_age_seconds"])
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

    test "scope=all lists every membership with team envelopes and excludes outsiders" do
      {user, primary_team} = user_with_team()
      secondary_team = team_fixture(%{name: "Secondary", slug: "secondary"})
      outsider_team = team_fixture(%{name: "Outsider", slug: "outsider"})
      {:ok, _} = Accounts.add_member(secondary_team, user, "member")

      _primary = barkpark_fixture(primary_team, %{name: "Primary", slug: "primary"})
      _secondary = barkpark_fixture(secondary_team, %{name: "Secondary", slug: "secondary"})
      _outsider = barkpark_fixture(outsider_team, %{name: "Secret", slug: "secret"})

      {:ok, token} = Accounts.create_user_session_token(user)
      conn = call(:get, "/v1/barkparks?scope=all", nil, token)

      assert conn.status == 200
      rows = json_body(conn)["barkparks"]
      assert Enum.map(rows, & &1["slug"]) |> Enum.sort() == ["primary", "secondary"]

      assert Enum.map(rows, & &1["team"]["slug"]) |> Enum.sort() ==
               [primary_team.slug, secondary_team.slug] |> Enum.sort()

      assert Enum.find(rows, &(&1["slug"] == "secondary"))["team"]["role"] == "member"

      refute Enum.any?(rows, &(&1["slug"] == "secret"))
    end

    test "scope=all rejects a team-scoped PAT" do
      {user, team} = user_with_team()

      {:ok, plaintext, _token} =
        Accounts.create_personal_access_token(user, team, %{name: "read", abilities: ["read"]})

      conn = call(:get, "/v1/barkparks?scope=all", nil, plaintext)
      assert conn.status == 401
      assert json_body(conn)["error"] == "unauthorized"
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

      conn = call(:post, "/v1/billing/checkout", %{plan: "supporter"}, token)

      assert conn.status == 200
      url = json_body(conn)["checkout_url"]
      # The Stub's deterministic url is the SHA-256 of team_id<>plan — proving the
      # AUTHED team_id (never a client value) is what was passed to the gateway.
      expected_sha =
        :crypto.hash(:sha256, team.id <> "supporter") |> Base.encode16(case: :lower)

      assert url == "https://checkout.stub/" <> expected_sha
    end

    test "the checkout uses the AUTHED team — a client-supplied team_id is ignored" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      # Even if the client tries to smuggle a different team_id in the body, the
      # url is keyed to the AUTHED team's id.
      conn =
        call(:post, "/v1/billing/checkout", %{plan: "supporter", team_id: "attacker-team"}, token)

      assert conn.status == 200

      expected_sha =
        :crypto.hash(:sha256, team.id <> "supporter") |> Base.encode16(case: :lower)

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
      conn = call(:post, "/v1/billing/checkout", %{plan: "supporter"})
      assert conn.status == 401
    end
  end

  ## POST /v1/billing/webhook  (unauthenticated but signature-verified)

  describe "POST /v1/billing/webhook" do
    test "a VALID signature on a checkout.session.completed event activates the subscription" do
      {_user, team} = user_with_team()
      assert is_nil(Billing.active_subscription(team))

      raw = checkout_completed_event(team.id, "supporter")

      conn =
        call_raw(:post, "/v1/billing/webhook", raw, [
          {"stripe-signature", StubGateway.test_signature()}
        ])

      assert conn.status == 200
      assert json_body(conn)["ok"] == true

      # The team is now actively subscribed on the signed plan.
      sub = Billing.active_subscription(team)
      assert sub != nil
      assert sub.plan == "supporter"
      assert sub.status == "active"
    end

    test "an INVALID signature → 400 invalid_signature and NO subscription created" do
      {_user, team} = user_with_team()
      raw = checkout_completed_event(team.id, "supporter")

      conn =
        call_raw(:post, "/v1/billing/webhook", raw, [{"stripe-signature", "forged-sig"}])

      assert conn.status == 400
      assert json_body(conn)["error"] == "invalid_signature"
      # A forged webhook grants NOTHING.
      assert is_nil(Billing.active_subscription(team))
    end

    test "a MISSING signature → 400 and NO subscription created" do
      {_user, team} = user_with_team()
      raw = checkout_completed_event(team.id, "supporter")

      conn = call_raw(:post, "/v1/billing/webhook", raw, [])

      assert conn.status == 400
      assert is_nil(Billing.active_subscription(team))
    end

    test "a repeated valid event is idempotent — it does not double-subscribe" do
      {_user, team} = user_with_team()
      raw = checkout_completed_event(team.id, "supporter")
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

    test "a REDELIVERED invoice.payment_failed emails the past_due alert exactly once" do
      {_user, team} = user_with_team()
      {:ok, sub} = Billing.subscribe(team, "supporter")
      raw = payment_failed_event(sub.gateway_customer_id)
      sig = [{"stripe-signature", StubGateway.test_signature()}]

      # First dunning event: the sub lands past_due and the team is emailed once.
      assert call_raw(:post, "/v1/billing/webhook", raw, sig).status == 200
      assert Billing.live_subscription(team).status == "past_due"
      assert length(Notifications.list_deliveries(team)) == 1

      # Stripe REDELIVERS the same event (webhook at-least-once semantics): still
      # 200, still past_due — but NO duplicate email to the paying customer.
      assert call_raw(:post, "/v1/billing/webhook", raw, sig).status == 200
      assert call_raw(:post, "/v1/billing/webhook", raw, sig).status == 200

      assert Billing.live_subscription(team).status == "past_due"
      assert length(Notifications.list_deliveries(team)) == 1
    end
  end

  ## POST /v1/go-live  (and its /v1/launch alias) — gated on an active subscription

  describe "POST /v1/go-live" do
    # Give `team` an active subscription so go-live's gate passes.
    defp subscribe!(team, plan \\ "supporter") do
      {:ok, _sub} = Billing.subscribe(team, plan)
      :ok
    end

    test "WITH an active subscription → 201, a provisioning barkpark row + a job enqueued" do
      {user, team} = user_with_team()
      :ok = subscribe!(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      assert Registry.list_barkparks(team) == []
      assert Repo.aggregate(ProvisionJob, :count) == 0

      conn = call(:post, "/v1/go-live", %{name: "My Prod", plan: "supporter"}, token)

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

    test "dwb-11: rapid double-submit of the SAME launch creates ONE box, not two (quota headroom)" do
      {user, team} = user_with_team()
      # supporter → quota 3, so the QUOTA gate is NOT what stops the duplicate —
      # the (team, slug) unique index is. This is the paid-team double-click case.
      :ok = subscribe!(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn1 = call(:post, "/v1/go-live", %{name: "My Prod", plan: "supporter"}, token)
      assert conn1.status == 201

      # The double-click: same name → same slug. The barkparks_team_slug_unique_idx
      # is the launch idempotency guard — the second submit is a 422, never a
      # second billed box, even though the plan has 2 slots to spare.
      conn2 = call(:post, "/v1/go-live", %{name: "My Prod", plan: "supporter"}, token)
      assert conn2.status == 422

      # Exactly ONE barkpark and ONE provision job from the two intents.
      assert [%Barkpark{slug: "my-prod"}] = Registry.list_barkparks(team)
      assert Repo.aggregate(ProvisionJob, :count) == 1
    end

    test "dwb-13: no subscription + unused trial → AUTO-STARTS the free trial → 201 + provisions" do
      # The auto-start entitlement step: a never-trialed team's first launch with
      # no subscription starts its ONE free trial here (fewest clicks) instead of
      # a dead-end 402 — and provisions the box.
      {user, team} = user_with_team()
      refute Billing.entitled?(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/go-live", %{name: "My Prod", plan: "supporter"}, token)

      assert conn.status == 201
      # A trial was started AND the box provisioned.
      assert Billing.entitled?(team)
      assert %{plan: "trial"} = Billing.live_subscription(team)
      assert [%Barkpark{slug: "my-prod"}] = Registry.list_barkparks(team)
      assert Repo.aggregate(ProvisionJob, :count) == 1
    end

    test "NO subscription AND trial ALREADY USED → 402 no_active_subscription + NOTHING provisioned" do
      # Once the one free trial is spent (ledger stamped, no live sub), go-live
      # can no longer auto-start a second — the 402 stands and the user must pay.
      {user, team} = user_with_team()
      exhaust_trial(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/go-live", %{name: "My Prod", plan: "supporter"}, token)

      assert conn.status == 402
      body = json_body(conn)
      assert body["error"] == "no_active_subscription"
      assert body["checkout_path"] == "/v1/billing/checkout"

      # Provision NOTHING — no barkpark row, no provision job, no second trial.
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

    test "/v1/launch with NO subscription and an exhausted trial → 402" do
      {user, team} = user_with_team()
      exhaust_trial(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/launch", %{provider: "hetzner", name: "Launched"}, token)
      assert conn.status == 402
      assert json_body(conn)["error"] == "no_active_subscription"
    end

    test "missing name (but subscribed) → 422" do
      {user, team} = user_with_team()
      :ok = subscribe!(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/go-live", %{plan: "supporter"}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "name_required"
    end

    test "no token → 401" do
      conn = call(:post, "/v1/go-live", %{name: "X"})
      assert conn.status == 401
    end
  end

  ## GET /v1/me

  describe "GET /v1/me" do
    test "valid session token → 200 {user, team}" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/me", nil, token)

      assert conn.status == 200
      body = json_body(conn)
      assert body["user"]["id"] == user.id
      assert body["user"]["email"] == user.email
      assert body["team"]["id"] == team.id
      assert body["team"]["name"] == team.name
      assert body["team"]["slug"] == team.slug

      # The onboarding summary is folded in so the SPA renders the checklist on
      # boot with no second round-trip.
      assert body["onboarding"]["completed"] == false
      assert body["onboarding"]["all_done"] == false
      assert length(body["onboarding"]["steps"]) == 3
    end

    test "user with no team → team is nil" do
      user = user_fixture()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/me", nil, token)

      assert conn.status == 200
      body = json_body(conn)
      assert body["user"]["email"] == user.email
      assert body["team"] == nil
    end

    test "no token → 401" do
      conn = call(:get, "/v1/me")
      assert conn.status == 401
    end

    test "bad token → 401" do
      conn = call(:get, "/v1/me", nil, "not-a-real-token")
      assert conn.status == 401
    end

    test "PAT caller gets onboarding_json with NO gateway/customer ids leaked" do
      {user, team} = user_with_team()

      {:ok, pat, _tok} =
        Accounts.create_personal_access_token(user, team, %{
          name: "ci-pat",
          abilities: ["read"]
        })

      # Give the team a subscription so the DB actually holds gateway ids that a
      # leak WOULD surface — the assertion below is non-vacuous.
      {:ok, sub} = Billing.subscribe(team, "supporter")
      assert is_binary(sub.gateway_customer_id)
      assert is_binary(sub.gateway_subscription_id)

      conn = call(:get, "/v1/me", nil, pat)
      assert conn.status == 200

      # onboarding rides on the PAT read...
      ob = json_body(conn)["onboarding"]
      assert ob["completed"] == false
      assert length(ob["steps"]) == 3

      # ...and the raw body never carries the opaque gateway references.
      refute String.contains?(conn.resp_body, sub.gateway_customer_id)
      refute String.contains?(conn.resp_body, sub.gateway_subscription_id)
      refute String.contains?(conn.resp_body, "gateway_customer_id")
      refute String.contains?(conn.resp_body, "gateway_subscription_id")
    end

    # platform-operator (charter GR9 interim principal). The boolean is derived
    # SOLELY from the :platform_admin_emails allowlist — fail-closed to false
    # when the allowlist is unset/empty, never from a team role.

    test "unset allowlist → platform_operator false (fail-closed)" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      # No :platform_admin_emails configured (test default) — even an owner is
      # NOT a platform operator. Distinct random email keeps this immune to any
      # allowlist a concurrent async test might momentarily set.
      conn = call(:get, "/v1/me", nil, token)

      assert conn.status == 200
      assert json_body(conn)["user"]["platform_operator"] == false
    end

    test "session email in :platform_admin_emails → platform_operator true" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      prev = Application.get_env(:barkpark_cloud, :platform_admin_emails)
      Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
      on_exit(fn -> Application.put_env(:barkpark_cloud, :platform_admin_emails, prev) end)

      conn = call(:get, "/v1/me", nil, token)

      assert conn.status == 200
      assert json_body(conn)["user"]["platform_operator"] == true
    end
  end

  ## GET/POST /v1/onboarding

  describe "GET /v1/onboarding" do
    test "no token → 401" do
      conn = call(:get, "/v1/onboarding")
      assert conn.status == 401
    end

    test "fresh team → 200, completed false, 3 steps all done:false" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/onboarding", nil, token)

      assert conn.status == 200
      ob = json_body(conn)["onboarding"]
      assert ob["completed"] == false
      assert ob["all_done"] == false
      assert Enum.map(ob["steps"], & &1["key"]) == ~w(subscription instance published_doc)
      assert Enum.all?(ob["steps"], &(&1["done"] == false))
    end

    test "the instance step flips done once the team has a barkpark" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)
      _bp = barkpark_fixture(team)

      conn = call(:get, "/v1/onboarding", nil, token)
      ob = json_body(conn)["onboarding"]
      step = Enum.find(ob["steps"], &(&1["key"] == "instance"))
      assert step["done"] == true
    end

    test "a plain member CAN read onboarding (GET is not admin-gated)" do
      {_m, _t, m_token} = user_with_role("member")

      conn = call(:get, "/v1/onboarding", nil, m_token)
      assert conn.status == 200
      assert json_body(conn)["onboarding"]["completed"] == false
    end
  end

  describe "POST /v1/onboarding" do
    test "no token → 401" do
      conn = call(:post, "/v1/onboarding", %{action: "skip"})
      assert conn.status == 401
    end

    test "advance persists last_step and echoes updated status" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/onboarding", %{action: "advance", step: "instance"}, token)

      assert conn.status == 200
      assert json_body(conn)["onboarding"]["last_step"] == "instance"
      assert Accounts.get_team(team.id).onboarding_state["last_step"] == "instance"
    end

    test "advance with an unknown step → 422 unknown_step" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/onboarding", %{action: "advance", step: "bogus"}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "unknown_step"
    end

    test "ack published_doc marks it done" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/onboarding", %{action: "ack", step: "published_doc"}, token)
      assert conn.status == 200
      step = Enum.find(json_body(conn)["onboarding"]["steps"], &(&1["key"] == "published_doc"))
      assert step["done"] == true
    end

    test "complete when steps incomplete → 422 steps_incomplete" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/onboarding", %{action: "complete"}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "steps_incomplete"
    end

    test "complete when all steps done → 200 completed:true with completed_at set" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      {:ok, _sub} = Billing.subscribe(team, "supporter")
      bp = barkpark_fixture(team)
      {:ok, _ev} = Registry.record_event(bp, "content", %{"published_count" => 2})

      conn = call(:post, "/v1/onboarding", %{action: "complete"}, token)
      assert conn.status == 200
      ob = json_body(conn)["onboarding"]
      assert ob["completed"] == true
      assert ob["completed_at"] != nil
    end

    test "skip → 200 completed:true even with steps incomplete" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/onboarding", %{action: "skip"}, token)
      assert conn.status == 200
      assert json_body(conn)["onboarding"]["completed"] == true
    end

    test "an unknown action → 422 bad_action" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/onboarding", %{action: "explode"}, token)
      assert conn.status == 422
      assert json_body(conn)["error"] == "bad_action"
    end

    ## SECURITY — RBAC gate: mutations are owner/admin-only.

    test "member → POST /v1/onboarding (skip) ⇒ 403; the team's onboarding is untouched" do
      {_m, team, m_token} = user_with_role("member")

      conn = call(:post, "/v1/onboarding", %{action: "skip"}, m_token)
      assert conn.status == 403
      assert json_body(conn)["error"] == "forbidden"

      # The guard actually protected state: the team is still onboarding.
      refute Accounts.onboarding_status(Accounts.get_team(team.id)).completed?
    end

    test "member → POST /v1/onboarding (advance/ack/complete) all ⇒ 403" do
      {_m, _t, m_token} = user_with_role("member")

      for body <- [
            %{action: "advance", step: "instance"},
            %{action: "ack", step: "published_doc"},
            %{action: "complete"}
          ] do
        conn = call(:post, "/v1/onboarding", body, m_token)
        assert conn.status == 403, "expected 403 for #{inspect(body)}, got #{conn.status}"
      end
    end

    test "admin → POST /v1/onboarding (skip) ⇒ 200 (admin satisfies the gate)" do
      {_a, _t, a_token} = user_with_role("admin")

      conn = call(:post, "/v1/onboarding", %{action: "skip"}, a_token)
      assert conn.status == 200
      assert json_body(conn)["onboarding"]["completed"] == true
    end

    ## SECURITY — cross-team tenancy: a caller only ever touches THEIR team.

    test "a user's onboarding writes hit their OWN team, never another team's" do
      {_owner_a, team_a, token_a} = user_with_role("owner")
      {_owner_b, team_b, _token_b} = user_with_role("owner")

      # User A skips their onboarding.
      conn = call(:post, "/v1/onboarding", %{action: "skip"}, token_a)
      assert conn.status == 200

      # Team A is completed; team B is entirely unaffected (no cross-tenant write).
      assert Accounts.onboarding_status(Accounts.get_team(team_a.id)).completed?
      refute Accounts.onboarding_status(Accounts.get_team(team_b.id)).completed?
    end

    test "a user reads only THEIR team's onboarding, never another team's state" do
      {_owner_a, _team_a, token_a} = user_with_role("owner")
      {_owner_b, team_b, _token_b} = user_with_role("owner")

      # Team B has an instance; team A does not.
      _bp_b = barkpark_fixture(team_b)

      conn = call(:get, "/v1/onboarding", nil, token_a)
      ob = json_body(conn)["onboarding"]
      # A's instance step is NOT satisfied by B's barkpark.
      step = Enum.find(ob["steps"], &(&1["key"] == "instance"))
      assert step["done"] == false
    end
  end

  ## GET /v1/subscription

  describe "GET /v1/subscription" do
    test "no active subscription → 200 {subscription: nil}" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/subscription", nil, token)

      assert conn.status == 200
      assert json_body(conn)["subscription"] == nil
    end

    test "active subscription → 200 {subscription: {plan, status, started_at}}" do
      {user, team} = user_with_team()
      {:ok, _sub} = Billing.subscribe(team, "supporter")
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/subscription", nil, token)

      assert conn.status == 200
      sub = json_body(conn)["subscription"]
      assert sub["plan"] == "supporter"
      assert sub["status"] == "active"
      assert is_binary(sub["started_at"])
      # Gateway customer / subscription ids are NEVER serialized.
      refute Map.has_key?(sub, "gateway_customer_id")
      refute Map.has_key?(sub, "gateway_subscription_id")
    end

    test "user with no team → 200 {subscription: nil}" do
      user = user_fixture()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/subscription", nil, token)
      assert conn.status == 200
      assert json_body(conn)["subscription"] == nil
    end

    test "no token → 401" do
      conn = call(:get, "/v1/subscription")
      assert conn.status == 401
    end
  end

  ## GET /v1/providers

  describe "GET /v1/providers" do
    test "valid session token → 200 {providers: [...]}" do
      {user, team} = user_with_team()
      {:ok, _p} = Registry.connect_provider(team, "hetzner", "tok", label: "main")
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/providers", nil, token)

      assert conn.status == 200
      [p] = json_body(conn)["providers"]
      assert p["kind"] == "hetzner"
      assert p["label"] == "main"
      # The encrypted token is NEVER serialized.
      refute Map.has_key?(p, "encrypted_token")
      refute conn.resp_body =~ "tok"
    end

    test "the row carries updated_at, so a rotation is not a byte-identical payload" do
      {user, team} = user_with_team()
      {:ok, _p} = Registry.connect_provider(team, "hetzner", "tok", label: "main")
      {:ok, token} = Accounts.create_user_session_token(user)

      [fresh] = json_body(call(:get, "/v1/providers", nil, token))["providers"]
      assert is_binary(fresh["updated_at"])
      # A first connect fills both stamps from one autogenerate entry — the
      # console reads that as "never rotated" and shows no update line.
      assert fresh["updated_at"] == fresh["inserted_at"]

      {:ok, _} = Registry.connect_provider(team, "hetzner", "rotated-tok")

      [after_rotation] = json_body(call(:get, "/v1/providers", nil, token))["providers"]
      assert after_rotation["id"] == fresh["id"]
      assert after_rotation["inserted_at"] == fresh["inserted_at"]

      assert after_rotation["updated_at"] > fresh["updated_at"],
             "without updated_at the payload is byte-identical across a rotation and the console cannot show it"

      refute after_rotation["updated_at"] == after_rotation["inserted_at"]
      refute call(:get, "/v1/providers", nil, token).resp_body =~ "rotated-tok"
    end

    test "empty team → 200 {providers: []}" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/providers", nil, token)
      assert conn.status == 200
      assert json_body(conn)["providers"] == []
    end

    test "team isolation: user A never sees team B's providers" do
      {user_a, _team_a} = user_with_team()
      {_user_b, team_b} = user_with_team()
      {:ok, _p} = Registry.connect_provider(team_b, "hetzner", "b-token", label: "b")

      {:ok, token_a} = Accounts.create_user_session_token(user_a)
      conn = call(:get, "/v1/providers", nil, token_a)

      assert conn.status == 200
      assert json_body(conn)["providers"] == []
    end

    test "no token → 401" do
      conn = call(:get, "/v1/providers")
      assert conn.status == 401
    end
  end

  ## DELETE /v1/barkparks/:id

  describe "DELETE /v1/barkparks/:id" do
    test "non-live instance (host nil) → 200 {ok: true} and the row is gone" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:delete, "/v1/barkparks/#{bp.id}", nil, token)

      assert conn.status == 200
      assert json_body(conn)["ok"] == true
      assert json_body(conn)["status"] == "removed"
      assert Registry.list_barkparks(team) == []
    end

    test "non-live instance with a pending provision job → 409 provisioning_in_progress, row kept" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      # host is still nil, but a provision is in flight: deleting the row now would
      # strand a billed box the control plane can no longer see.
      {:ok, _job} = Registry.enqueue_provision_job(bp)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:delete, "/v1/barkparks/#{bp.id}", nil, token)

      assert conn.status == 409
      assert json_body(conn)["error"] == "provisioning_in_progress"
      # The barkpark row must still exist.
      assert Registry.get_barkpark(bp.id) != nil
    end

    test "live instance (host set) → 202 deprovisioning, a pending deprovision job exists" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.10"})
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:delete, "/v1/barkparks/#{bp.id}", nil, token)

      assert conn.status == 202
      assert json_body(conn)["status"] == "deprovisioning"
      # The row is NOT deleted yet — the worker tears the box down first.
      assert [%Barkpark{id: kept}] = Registry.list_barkparks(team)
      assert kept == bp.id
      # Exactly one pending deprovision job is enqueued.
      assert %{status: "pending"} = Registry.latest_deprovision_status_map([bp.id])[bp.id]
    end

    test "a duplicate DELETE on a live instance is deduped → still 202, one active job" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.10"})
      {:ok, token} = Accounts.create_user_session_token(user)

      conn1 = call(:delete, "/v1/barkparks/#{bp.id}", nil, token)
      conn2 = call(:delete, "/v1/barkparks/#{bp.id}", nil, token)

      assert conn1.status == 202
      assert conn2.status == 202

      active =
        Repo.aggregate(
          from(j in ProvisionJob,
            where:
              j.barkpark_id == ^bp.id and j.kind == "deprovision" and
                j.status in ["pending", "claimed"]
          ),
          :count
        )

      assert active == 1
    end

    test "wrong team → 404 (no existence leak), row untouched" do
      {user_a, _team_a} = user_with_team()
      {_user_b, team_b} = user_with_team()
      bp_b = barkpark_fixture(team_b)
      {:ok, token_a} = Accounts.create_user_session_token(user_a)

      conn = call(:delete, "/v1/barkparks/#{bp_b.id}", nil, token_a)

      assert conn.status == 404
      assert Registry.get_barkpark(bp_b.id) != nil
    end

    test "nonexistent id → 404" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:delete, "/v1/barkparks/#{Ecto.UUID.generate()}", nil, token)
      assert conn.status == 404
    end

    test "no token → 401" do
      conn = call(:delete, "/v1/barkparks/#{Ecto.UUID.generate()}")
      assert conn.status == 401
    end
  end

  ## Internal deprovision queue

  describe "POST /v1/internal/deprovision-jobs/claim" do
    test "worker token + a pending deprovision job → 200 {job_id, ip, dns_label, dns_zone}" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team, %{slug: "tear"})
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.20"})
      {:ok, job} = Registry.enqueue_deprovision_job(bp)

      conn = call(:post, "/v1/internal/deprovision-jobs/claim", %{}, @worker_token)

      assert conn.status == 200
      body = json_body(conn)
      assert body["job_id"] == job.id
      assert body["ip"] == "203.0.113.20"
      assert body["dns_label"] == Barkpark.provisioning_subdomain(Registry.get_barkpark(bp.id))
      assert body["dns_zone"] == Barkpark.base_domain()
    end

    test "worker token + no pending job → 204 (empty body)" do
      conn = call(:post, "/v1/internal/deprovision-jobs/claim", %{}, @worker_token)
      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "no token → 401" do
      conn = call(:post, "/v1/internal/deprovision-jobs/claim", %{}, nil)
      assert conn.status == 401
    end

    test "a bad token → 401" do
      conn = call(:post, "/v1/internal/deprovision-jobs/claim", %{}, "not-the-worker-token")
      assert conn.status == 401
    end
  end

  describe "POST /v1/internal/deprovision-jobs/:id/succeed" do
    test "worker token → 200 and the barkpark is deleted" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.21"})
      {:ok, job} = Registry.enqueue_deprovision_job(bp)

      conn = call(:post, "/v1/internal/deprovision-jobs/#{job.id}/succeed", %{}, @worker_token)

      assert conn.status == 200
      assert json_body(conn)["ok"] == true
      assert Registry.get_barkpark(bp.id) == nil
    end

    test "IDEMPOTENT: a second succeed on the already-gone job → 200" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.22"})
      {:ok, job} = Registry.enqueue_deprovision_job(bp)

      conn1 = call(:post, "/v1/internal/deprovision-jobs/#{job.id}/succeed", %{}, @worker_token)
      conn2 = call(:post, "/v1/internal/deprovision-jobs/#{job.id}/succeed", %{}, @worker_token)

      assert conn1.status == 200
      assert conn2.status == 200
    end

    test "succeed on a FAILED deprovision job → 409 conflict, the barkpark stays" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.25"})
      {:ok, job} = Registry.enqueue_deprovision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "hcloud unreachable")

      conn = call(:post, "/v1/internal/deprovision-jobs/#{job.id}/succeed", %{}, @worker_token)

      assert conn.status == 409
      assert json_body(conn)["error"] == "conflict"
      # A straggler succeed must NOT resurrect a failed job and delete the barkpark.
      assert %Barkpark{} = Registry.get_barkpark(bp.id)
    end

    test "no token → 401" do
      conn =
        call(:post, "/v1/internal/deprovision-jobs/#{Ecto.UUID.generate()}/succeed", %{}, nil)

      assert conn.status == 401
    end
  end

  describe "POST /v1/internal/deprovision-jobs/:id/fail" do
    test "worker token + {error} → 200, job failed, barkpark stays" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.23"})
      {:ok, job} = Registry.enqueue_deprovision_job(bp)

      conn =
        call(
          :post,
          "/v1/internal/deprovision-jobs/#{job.id}/fail",
          %{error: "hcloud down"},
          @worker_token
        )

      assert conn.status == 200
      assert json_body(conn)["ok"] == true
      # The barkpark is NOT deleted on a failed removal.
      assert %Barkpark{} = Registry.get_barkpark(bp.id)

      assert %{status: "failed", error: "hcloud down"} =
               Registry.latest_deprovision_status_map([bp.id])[bp.id]
    end

    test "unknown job id → 404" do
      conn =
        call(
          :post,
          "/v1/internal/deprovision-jobs/#{Ecto.UUID.generate()}/fail",
          %{error: "x"},
          @worker_token
        )

      assert conn.status == 404
    end

    test "no token → 401" do
      conn =
        call(
          :post,
          "/v1/internal/deprovision-jobs/#{Ecto.UUID.generate()}/fail",
          %{error: "x"},
          nil
        )

      assert conn.status == 401
    end
  end

  ## POST /v1/barkparks/:id/retry

  describe "POST /v1/barkparks/:id/retry" do
    test "failed latest job → 201 {ok: true} and a fresh job is enqueued" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "boom")
      {:ok, token} = Accounts.create_user_session_token(user)

      assert Repo.aggregate(ProvisionJob, :count) == 1

      conn = call(:post, "/v1/barkparks/#{bp.id}/retry", %{}, token)

      assert conn.status == 201
      assert json_body(conn)["ok"] == true
      # A second (pending) job is now enqueued.
      assert Repo.aggregate(ProvisionJob, :count) == 2
    end

    test "non-failed latest job (pending) → 409 not_retryable, no new job" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _job} = Registry.enqueue_provision_job(bp)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/barkparks/#{bp.id}/retry", %{}, token)

      assert conn.status == 409
      assert json_body(conn)["error"] == "not_retryable"
      # Still exactly the one pending job — no concurrent second provision.
      assert Repo.aggregate(ProvisionJob, :count) == 1
    end

    test "dwb-11: sequential double-click Retry never enqueues a second provision" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "boom")
      {:ok, token} = Accounts.create_user_session_token(user)

      # First click re-enqueues a fresh pending provision (201).
      conn1 = call(:post, "/v1/barkparks/#{bp.id}/retry", %{}, token)
      assert conn1.status == 201

      # The second click, once the first has landed a pending job, is stopped by
      # the route's own latest-status gate (latest is now `pending`, not `failed`).
      conn2 = call(:post, "/v1/barkparks/#{bp.id}/retry", %{}, token)
      assert conn2.status == 409
      assert json_body(conn2)["error"] == "not_retryable"

      # Exactly ONE active (pending/claimed) provision job — never two boxes.
      assert active_provisions(bp) == 1
    end

    test "dwb-11: a Retry that RACES an already-open provision is refused (no second box)" do
      # The true concurrent double-click: BOTH requests read the last job as
      # `failed` and clear the route's latest-status gate before either enqueues.
      # Reproduced deterministically as "an ACTIVE provision + a NEWER failed job"
      # — the exact state the losing request sees: its gate passes (latest ==
      # failed) but an active provision already exists. Pre-fix, enqueue would
      # insert a SECOND pending provision here → two workers, two billed boxes.
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      # An in-flight provision (the box the winning request already re-opened).
      {:ok, _active} = Registry.enqueue_provision_job(bp)

      # A later `failed` row (terminal → outside the one-active index, so the
      # insert is allowed) makes `latest_provision_job` report `failed`.
      {:ok, _newer_failed} =
        %ProvisionJob{}
        |> ProvisionJob.changeset(%{barkpark_id: bp.id, status: "failed", error: "prior"})
        |> Repo.insert()

      conn = call(:post, "/v1/barkparks/#{bp.id}/retry", %{}, token)
      assert conn.status == 409
      assert json_body(conn)["error"] == "already_provisioning"

      # Still exactly ONE active provision — the race did not open a second box.
      assert active_provisions(bp) == 1
    end

    test "wrong team → 404" do
      {user_a, _team_a} = user_with_team()
      {_user_b, team_b} = user_with_team()
      bp_b = barkpark_fixture(team_b)
      {:ok, job} = Registry.enqueue_provision_job(bp_b)
      {:ok, _} = Registry.fail_job(job.id, "boom")
      {:ok, token_a} = Accounts.create_user_session_token(user_a)

      conn = call(:post, "/v1/barkparks/#{bp_b.id}/retry", %{}, token_a)
      assert conn.status == 404
    end

    test "no token → 401" do
      conn = call(:post, "/v1/barkparks/#{Ecto.UUID.generate()}/retry", %{})
      assert conn.status == 401
    end

    test "dwb-11: stranded launch (managed, never live, NO job) is retryable — no dead end" do
      # The go-live enqueue-hiccup state: the 201 stood, the row exists, but the
      # provision-job insert failed (only logged). Pre-fix Retry 409'd forever.
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      assert Repo.aggregate(ProvisionJob, :count) == 0
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/barkparks/#{bp.id}/retry", %{}, token)

      assert conn.status == 201
      assert Repo.aggregate(ProvisionJob, :count) == 1
    end

    test "dwb-11: a self_hosted instance with no job is NOT retryable (never ours to provision)" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team, %{mode: "self_hosted"})
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/barkparks/#{bp.id}/retry", %{}, token)

      assert conn.status == 409
      assert json_body(conn)["error"] == "not_retryable"
      assert Repo.aggregate(ProvisionJob, :count) == 0
    end

    test "dwb-11: a LIVE managed box (host set) with no job is NOT retryable" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, bp} = Registry.upsert_health(bp, %{host: "203.0.113.9", health_status: "up"})
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/barkparks/#{bp.id}/retry", %{}, token)

      assert conn.status == 409
      assert json_body(conn)["error"] == "not_retryable"
      assert Repo.aggregate(ProvisionJob, :count) == 0
    end
  end

  ## GET /v1/barkparks — provision_status / provision_error merge

  describe "GET /v1/barkparks provision_status merge" do
    test "a barkpark with a FAILED latest job carries provision_status + provision_error" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "out of capacity")
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/barkparks", nil, token)

      assert conn.status == 200
      [row] = json_body(conn)["barkparks"]
      assert row["provision_status"] == "failed"
      assert row["provision_error"] == "out of capacity"
    end

    test "a barkpark with a PENDING job carries provision_status, no error" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _job} = Registry.enqueue_provision_job(bp)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/barkparks", nil, token)

      [row] = json_body(conn)["barkparks"]
      assert row["provision_status"] == "pending"
      assert row["provision_error"] == nil
    end

    test "a barkpark with an active deprovision job carries deprovision_status" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.24"})
      {:ok, _} = Registry.enqueue_deprovision_job(bp)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/barkparks", nil, token)

      assert conn.status == 200
      [row] = json_body(conn)["barkparks"]
      assert row["deprovision_status"] == "pending"
    end

    test "a barkpark with a FAILED latest deprovision job carries deprovision_status + deprovision_error" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.26"})
      {:ok, job} = Registry.enqueue_deprovision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "hcloud server in use")
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/barkparks", nil, token)

      assert conn.status == 200
      [row] = json_body(conn)["barkparks"]
      assert row["deprovision_status"] == "failed"
      assert row["deprovision_error"] == "hcloud server in use"
    end

    test "a barkpark with NO job omits the provision_status key entirely" do
      {user, team} = user_with_team()
      _bp = barkpark_fixture(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:get, "/v1/barkparks", nil, token)

      [row] = json_body(conn)["barkparks"]
      refute Map.has_key?(row, "provision_status")
      refute Map.has_key?(row, "provision_error")
    end

    test "team isolation: a team's provision_status is not leaked to another team" do
      {_user_a, team_a} = user_with_team()
      {user_b, team_b} = user_with_team()
      bp_a = barkpark_fixture(team_a)
      {:ok, job_a} = Registry.enqueue_provision_job(bp_a)
      {:ok, _} = Registry.fail_job(job_a.id, "team A only")
      _bp_b = barkpark_fixture(team_b)
      {:ok, token_b} = Accounts.create_user_session_token(user_b)

      conn = call(:get, "/v1/barkparks", nil, token_b)

      rows = json_body(conn)["barkparks"]
      # Team B sees only its own (job-less) barkpark, never team A's failed status.
      assert length(rows) == 1
      refute conn.resp_body =~ "team A only"
    end
  end

  ## GET /v1/events — SSE auth branches (the parking success path is exercised
  ## via the broadcast integration tests below; here we cover the synchronous
  ## auth/no-team branches that return before the receive loop parks).

  describe "GET /v1/events (auth)" do
    test "no token → 401" do
      conn = call(:get, "/v1/events")
      assert conn.status == 401
      assert json_body(conn)["error"] == "unauthorized"
    end

    test "bad Bearer token → 401" do
      conn = call(:get, "/v1/events", nil, "not-a-real-token")
      assert conn.status == 401
    end

    test "bad ?ticket= query param → 401 (query-param auth path is wired)" do
      conn = call(:get, "/v1/events?ticket=not-a-real-ticket")
      assert conn.status == 401
    end

    test "valid ?ticket= for a teamless user → 422 no_team (query-param auth resolves a real user)" do
      user = user_fixture()
      {:ok, ticket} = Accounts.create_sse_ticket(user)

      conn = call(:get, "/v1/events?ticket=#{ticket}")

      assert conn.status == 422
      assert json_body(conn)["error"] == "no_team"
    end

    # THE LEAK THIS SLICE CLOSES (cch-w3). A 30-day session token in the query
    # string lands in every access log and proxy trace; `?token=` used to accept
    # one. It is now dead: only a single-use `?ticket=` opens the stream from a
    # URL, and a session token stays credible ONLY in the Authorization header,
    # which is never written anywhere.
    test "a session token in the query string no longer opens the stream" do
      # A TEAMLESS user throughout, so every branch answers synchronously (a
      # user WITH a team parks in the SSE receive loop and would hang the test):
      # 401 = the credential was refused, 422 no_team = it resolved a real user.
      user = user_fixture()
      {:ok, token} = Accounts.create_user_session_token(user)

      # The retired parameter name: not a weaker check now — no check at all.
      assert call(:get, "/v1/events?token=#{token}").status == 401
      # And it is not merely the NAME that changed: a session token is not a
      # ticket, so renaming the param in a bookmarked URL buys nothing either.
      assert call(:get, "/v1/events?ticket=#{token}").status == 401
      # The header path still takes a session token (curl / an EventSource
      # polyfill / the CLI) — that path never writes the credential into a URL.
      assert call(:get, "/v1/events", nil, token).status == 422
    end
  end

  ## Live-event broadcasts at mutation points. The test process SUBSCRIBES to its
  ## team's :pg group, performs the mutation through the router (synchronously, in
  ## this same process), and asserts the coarse invalidation event lands.

  describe "live events (push_event broadcasts)" do
    test "POST /v1/agent/report broadcasts a fleet event" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, agent_token, _} = Registry.mint_agent_token(bp, "report")
      :ok = Events.subscribe(team.id)

      conn = call(:post, "/v1/agent/report", report_body(), agent_token)
      assert conn.status == 200

      assert_receive {:bpcloud_event, %{type: "fleet"}}
    end

    test "DELETE /v1/barkparks/:id broadcasts a fleet event" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, token} = Accounts.create_user_session_token(user)
      :ok = Events.subscribe(team.id)

      conn = call(:delete, "/v1/barkparks/#{bp.id}", nil, token)
      assert conn.status == 200

      assert_receive {:bpcloud_event, %{type: "fleet"}}
    end

    test "POST /v1/barkparks/:id/retry broadcasts a fleet event" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, job} = Registry.enqueue_provision_job(bp)
      {:ok, _} = Registry.fail_job(job.id, "boom")
      {:ok, token} = Accounts.create_user_session_token(user)
      :ok = Events.subscribe(team.id)

      conn = call(:post, "/v1/barkparks/#{bp.id}/retry", %{}, token)
      assert conn.status == 201

      assert_receive {:bpcloud_event, %{type: "fleet"}}
    end

    test "POST /v1/internal/deprovision-jobs/:id/succeed broadcasts a fleet event" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.27"})
      {:ok, job} = Registry.enqueue_deprovision_job(bp)
      :ok = Events.subscribe(team.id)

      conn = call(:post, "/v1/internal/deprovision-jobs/#{job.id}/succeed", %{}, @worker_token)
      assert conn.status == 200

      assert_receive {:bpcloud_event, %{type: "fleet"}}
    end

    test "a webhook activation broadcasts subscription + fleet events" do
      {_user, team} = user_with_team()
      :ok = Events.subscribe(team.id)
      raw = checkout_completed_event(team.id, "supporter")

      conn =
        call_raw(:post, "/v1/billing/webhook", raw, [
          {"stripe-signature", StubGateway.test_signature()}
        ])

      assert conn.status == 200
      assert_receive {:bpcloud_event, %{type: "subscription"}}
      assert_receive {:bpcloud_event, %{type: "fleet"}}
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

    defp cache_control(conn) do
      case get_resp_header(conn, "cache-control") do
        [cc | _] -> cc
        _ -> nil
      end
    end

    test "GET /fonts/Inter-var.woff2 → 200 with immutable 1-year cache" do
      conn = call(:get, "/fonts/Inter-var.woff2")

      assert conn.status == 200
      # Content-stable self-hosted font: the dedicated plug ahead of the
      # no-cache SPA plug serves it with a long immutable lifetime.
      assert cache_control(conn) == "public, max-age=31536000, immutable"
    end

    test "GET /app.css stays no-cache (SPA files must revalidate every deploy)" do
      conn = call(:get, "/app.css")

      assert conn.status == 200
      # The immutable fonts plug must NOT bleed onto the unversioned SPA assets —
      # they revalidate so a returning operator never sees stale console UI.
      assert cache_control(conn) == "no-cache"
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

  ## RBAC role gating (rbac-roles) — money/infra-destructive routes gate on the
  ## team grant; reads stay at member. The existing `user_with_team/0` grants
  ## "owner", so the happy-path tests above keep passing (owner satisfies every
  ## gate); these add the member/admin negative paths.

  describe "RBAC role gating" do
    # A user holding `role` in a fresh team, plus a live session token.
    # Returns {user, team, token}.
    defp user_with_role(role) do
      user = user_fixture()
      team = team_fixture()
      {:ok, _} = Accounts.add_member(team, user, role)
      {:ok, token} = Accounts.create_user_session_token(user)
      {user, team, token}
    end

    test "member → POST /v1/billing/checkout ⇒ 403 forbidden; owner ⇒ 200" do
      {_m, _t, m_token} = user_with_role("member")
      conn = call(:post, "/v1/billing/checkout", %{plan: "supporter"}, m_token)
      assert conn.status == 403
      assert json_body(conn)["error"] == "forbidden"

      {_o, _t2, o_token} = user_with_role("owner")
      conn = call(:post, "/v1/billing/checkout", %{plan: "supporter"}, o_token)
      assert conn.status == 200
    end

    test "admin (not owner) → POST /v1/billing/checkout ⇒ 403 (owner-only)" do
      {_a, _t, a_token} = user_with_role("admin")
      conn = call(:post, "/v1/billing/checkout", %{plan: "supporter"}, a_token)
      assert conn.status == 403
      assert json_body(conn)["error"] == "forbidden"
    end

    test "member → POST /v1/go-live ⇒ 403; admin (subscribed) ⇒ 201" do
      {_m, _t, m_token} = user_with_role("member")
      conn = call(:post, "/v1/go-live", %{name: "Box", plan: "supporter"}, m_token)
      assert conn.status == 403
      assert json_body(conn)["error"] == "forbidden"

      {_a, team, a_token} = user_with_role("admin")
      :ok = subscribe!(team)
      conn = call(:post, "/v1/go-live", %{name: "Admin Box", plan: "supporter"}, a_token)
      assert conn.status == 201
    end

    test "member → POST /v1/launch ⇒ 403 (shares the go_live admin gate)" do
      {_m, _t, m_token} = user_with_role("member")
      conn = call(:post, "/v1/launch", %{provider: "hetzner", name: "X"}, m_token)
      assert conn.status == 403
    end

    # cch-w36-s1 — THE CROWN CHAIN, WALKED BY ONE PRINCIPAL. Every leg of this
    # already had a single-hop test; none of them walked the chain, which is the
    # only way the contradiction is visible: the 402 hands the admin a
    # `checkout_path` the SAME admin is then refused at. Two authorities disagree
    # by design (launch is team-admin, paying is owner) — this pins that they
    # both SAY which one they wanted.
    test "cch-w36-s1: an admin with a spent trial walks launch(402) → its own checkout_path(403 owner)" do
      {_a, team, a_token} = user_with_role("admin")
      exhaust_trial(team)

      launch = call(:post, "/v1/launch", %{provider: "hetzner", name: "Crown"}, a_token)
      assert launch.status == 402
      launch_body = json_body(launch)
      assert launch_body["error"] == "no_active_subscription"
      checkout_path = launch_body["checkout_path"]
      assert checkout_path == "/v1/billing/checkout"

      # The SAME principal knocks on the door the 402 just handed them.
      checkout = call(:post, checkout_path, %{plan: "supporter"}, a_token)
      assert checkout.status == 403

      assert json_body(checkout) == %{
               "error" => "forbidden",
               "required" => "owner",
               "scope" => "team"
             }
    end

    test "cch-w36-s1: a plain member is refused BEFORE the 402, and the refusal names 'admin'" do
      # Full-map equality, not a slug check: the whole point is the evidence
      # BESIDE the slug — without it this body is byte-identical to the
      # owner-only billing refusal above, and the console guessed "plan limit".
      {_m, team, m_token} = user_with_role("member")
      exhaust_trial(team)

      conn = call(:post, "/v1/launch", %{provider: "hetzner", name: "Crown"}, m_token)

      assert conn.status == 403

      assert json_body(conn) == %{
               "error" => "forbidden",
               "required" => "admin",
               "scope" => "team"
             }
    end

    test "member → DELETE /v1/barkparks/:id ⇒ 403; admin ⇒ 200 removed" do
      {_m, team_m, m_token} = user_with_role("member")
      bp_m = barkpark_fixture(team_m)
      conn = call(:delete, "/v1/barkparks/#{bp_m.id}", nil, m_token)
      assert conn.status == 403

      {_a, team_a, a_token} = user_with_role("admin")
      bp_a = barkpark_fixture(team_a)
      conn = call(:delete, "/v1/barkparks/#{bp_a.id}", nil, a_token)
      assert conn.status == 200
      assert json_body(conn)["status"] == "removed"
    end

    test "member → POST /v1/barkparks/:id/retry ⇒ 403" do
      {_m, team_m, m_token} = user_with_role("member")
      bp_m = barkpark_fixture(team_m)
      conn = call(:post, "/v1/barkparks/#{bp_m.id}/retry", %{}, m_token)
      assert conn.status == 403
    end

    test "member → POST /v1/providers ⇒ 403; admin ⇒ 201" do
      {_m, _t, m_token} = user_with_role("member")
      conn = call(:post, "/v1/providers", %{kind: "hetzner", token: "x"}, m_token)
      assert conn.status == 403

      {_a, _t2, a_token} = user_with_role("admin")
      conn = call(:post, "/v1/providers", %{kind: "hetzner", token: "x", label: "main"}, a_token)
      assert conn.status == 201
    end

    test "member → reads (GET /v1/barkparks, GET /v1/me) stay ungated ⇒ 200" do
      {_m, _t, m_token} = user_with_role("member")

      conn = call(:get, "/v1/barkparks", nil, m_token)
      assert conn.status == 200

      conn = call(:get, "/v1/me", nil, m_token)
      assert conn.status == 200
    end

    test "no token → gated route ⇒ 401 (auth before authz)" do
      conn = call(:post, "/v1/providers", %{kind: "hetzner", token: "x"})
      assert conn.status == 401
      assert json_body(conn)["error"] == "unauthorized"
    end

    test "authenticated user with NO team → gated route ⇒ 403 (no grant)" do
      user = user_fixture()
      {:ok, token} = Accounts.create_user_session_token(user)

      conn = call(:post, "/v1/providers", %{kind: "hetzner", token: "x"}, token)
      assert conn.status == 403
      assert json_body(conn)["error"] == "forbidden"
    end
  end

  ## Keyset pagination — the compound cursor

  # An admin of a fresh team, plus a live session token.
  defp tied_feed_admin do
    {user, team} = user_with_team()
    {:ok, token} = Accounts.create_user_session_token(user)
    {team, token}
  end

  # `count` audit rows sharing ONE inserted_at. insert_all (not record_audit)
  # because the stamp must be identical to the microsecond, and the table
  # carries a BEFORE UPDATE trigger, so the value cannot be corrected after
  # the fact.
  defp seed_tied_audit(team, ts, count) do
    rows =
      for _ <- 1..count do
        %{
          id: Ecto.UUID.generate(),
          team_id: team.id,
          action: "site.created",
          metadata: %{},
          inserted_at: ts
        }
      end

    {^count, _} = Repo.insert_all(BarkparkCloud.Accounts.AuditEvent, rows)
    Enum.map(rows, & &1.id)
  end

  defp seed_tied_deliveries(team, ts, count) do
    rows =
      for i <- 1..count do
        %{
          id: Ecto.UUID.generate(),
          team_id: team.id,
          recipient: "ops#{i}@example.com",
          event: "provision_failed",
          channel: "email",
          kind: "alert",
          status: "sent",
          attempts: 1,
          inserted_at: ts,
          updated_at: ts
        }
      end

    {^count, _} = Repo.insert_all(BarkparkCloud.Notifications.Delivery, rows)
    Enum.map(rows, & &1.id)
  end

  defp get_page(token, path, key) do
    conn = call(:get, path, nil, token)
    assert conn.status == 200
    json_body(conn)[key]
  end

  # Walk `path_fn` with the full `(inserted_at, id)` cursor until a short page,
  # and return every id seen IN ORDER (duplicates included — the caller asserts
  # they are absent).
  defp walk_all(token, key, path_fn, limit) do
    Enum.reduce_while(1..10, {nil, nil, []}, fn _, {before, before_id, acc} ->
      cursor =
        if before,
          do: "&before=" <> URI.encode_www_form(before) <> "&before_id=" <> before_id,
          else: ""

      page = get_page(token, path_fn.(limit) <> cursor, key)
      acc = acc ++ Enum.map(page, & &1["id"])

      if length(page) < limit do
        {:halt, acc}
      else
        last = List.last(page)
        {:cont, {last["inserted_at"], last["id"], acc}}
      end
    end)
  end

  # gr-bl-delivery-keyset-tiebreak: both paginated feeds ORDER BY the compound
  # key `(inserted_at DESC, id DESC)` but historically PAGED on half of it
  # (`inserted_at < ^before`). A page boundary landing between two rows that
  # share a stamp therefore dropped every tied row on the far side — permanently,
  # silently, and exactly in the workloads that make ties routine (a fan-out
  # writes one delivery per recipient in one instant; a burst of audited writes
  # lands in one microsecond). These tests seed an ALL-TIED page so the boundary
  # is guaranteed to fall mid-tie, then assert the union of the pages is the
  # whole set with nothing seen twice and nothing missing.
  describe "keyset pagination across an inserted_at tie" do
    test "GET /v1/audit: every tied row is enumerated exactly once across pages" do
      {team, token} = tied_feed_admin()
      ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      ids = seed_tied_audit(team, ts, 5)

      seen = walk_all(token, "events", fn n -> "/v1/audit?limit=#{n}" end, 2)

      assert length(seen) == length(Enum.uniq(seen)), "a page boundary duplicated a tied row"
      assert Enum.sort(seen) == Enum.sort(ids), "a page boundary dropped a tied row"
    end

    test "GET /v1/notifications/deliveries: every tied row is enumerated exactly once" do
      {team, token} = tied_feed_admin()
      ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      ids = seed_tied_deliveries(team, ts, 5)

      seen =
        walk_all(token, "deliveries", fn n -> "/v1/notifications/deliveries?limit=#{n}" end, 2)

      assert length(seen) == length(Enum.uniq(seen)), "a page boundary duplicated a tied row"
      assert Enum.sort(seen) == Enum.sort(ids), "a page boundary dropped a tied row"
    end

    test "BACKWARD COMPATIBLE: `before` with no `before_id` is still the stamp-only cutoff" do
      {team, token} = tied_feed_admin()
      ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      _ids = seed_tied_audit(team, ts, 5)
      _dids = seed_tied_deliveries(team, ts, 5)

      audit_p1 = get_page(token, "/v1/audit?limit=2", "events")
      assert length(audit_p1) == 2
      stamp = List.last(audit_p1)["inserted_at"]

      # Unchanged legacy semantics: a stamp-only cutoff is STRICTLY older, so an
      # all-tied trail yields nothing after page one. That is the historical
      # behaviour, kept byte-for-byte for bookmarked URLs — the tiebreak arm
      # engages only when the id half arrives (the tests above).
      assert get_page(token, "/v1/audit?limit=2&before=" <> URI.encode_www_form(stamp), "events") ==
               []

      del_p1 = get_page(token, "/v1/notifications/deliveries?limit=2", "deliveries")
      assert length(del_p1) == 2
      dstamp = List.last(del_p1)["inserted_at"]

      assert get_page(
               token,
               "/v1/notifications/deliveries?limit=2&before=" <> URI.encode_www_form(dstamp),
               "deliveries"
             ) == []
    end

    test "a garbage before_id degrades to the stamp-only cutoff, never a 500" do
      {team, token} = tied_feed_admin()
      ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      _ids = seed_tied_audit(team, ts, 3)
      _dids = seed_tied_deliveries(team, ts, 3)
      stamp = URI.encode_www_form(DateTime.to_iso8601(ts))

      # `id` is a :binary_id — a raw non-UUID in that comparison would raise
      # Ecto.Query.CastError (a 500 on a typo'd cursor).
      assert get_page(token, "/v1/audit?limit=2&before=#{stamp}&before_id=not-a-uuid", "events") ==
               []

      assert get_page(
               token,
               "/v1/notifications/deliveries?limit=2&before=#{stamp}&before_id=not-a-uuid",
               "deliveries"
             ) == []
    end
  end

  # bp-login-ux-w2-front-door-plug: the two plug-level fixes at the pipeline seam
  # — www→apex 308 canonicalization (device-link ?code= must survive) and real
  # client-IP recovery behind the Caddy loopback front.
  describe "front door: www→apex 308 canonicalization" do
    # :dashboard_url is https://barkpark.cloud in every env (config.exs), so the
    # www host under test is www.barkpark.cloud.
    test "www.<dashboard-host> → 308 to the apex, path + ?code= query preserved" do
      conn = Router.call(conn(:get, "https://www.barkpark.cloud/activate?code=TEST-1234"), @opts)

      assert conn.status == 308

      assert get_resp_header(conn, "location") == [
               "https://barkpark.cloud/activate?code=TEST-1234"
             ]

      # halted before :match, so no route body was rendered.
      assert conn.halted
    end

    test "www 308 preserves a bare path with no query string (no dangling '?')" do
      conn = Router.call(conn(:get, "https://www.barkpark.cloud/dashboard"), @opts)

      assert conn.status == 308
      assert get_resp_header(conn, "location") == ["https://barkpark.cloud/dashboard"]
    end

    test "apex itself is NOT redirected (no loop)" do
      conn = Router.call(conn(:get, "https://barkpark.cloud/up"), @opts)
      assert conn.status == 200
    end

    test "localhost /up stays 200 un-redirected (blue/green health gate safe)" do
      conn = Router.call(conn(:get, "http://localhost:4100/up"), @opts)
      assert conn.status == 200
      refute conn.status == 308
    end

    test "raw-IP health probe (no X-Forwarded-Host) is not redirected" do
      conn = Router.call(conn(:get, "http://127.0.0.1:4101/up"), @opts)
      assert conn.status == 200
    end

    test "api.barkpark.cloud passes through untouched" do
      conn = Router.call(conn(:get, "https://api.barkpark.cloud/up"), @opts)
      assert conn.status == 200
    end

    test "lookalike hosts pass through untouched (no accidental canonicalization)" do
      for host <- [
            "https://www.barkpark.cloud.evil.com/up",
            "https://wwwbarkpark.cloud/up",
            "https://www.api.barkpark.cloud/up"
          ] do
        conn = Router.call(conn(:get, host), @opts)
        assert conn.status == 200, "expected passthrough for #{host}, got #{conn.status}"
      end
    end
  end

  describe "front door: real client IP behind the Caddy loopback front" do
    # Router.call runs the full pipeline; :trust_forwarded_ip sets conn.remote_ip
    # early and nothing downstream resets it, so the returned conn carries the
    # resolved IP — the same value peer_ip/1 hands the start:<ip> rate bucket and
    # session_opts.
    test "X-Forwarded-For honored when the peer is loopback" do
      # Plug.Test defaults remote_ip to {127,0,0,1} — a trusted loopback peer.
      conn =
        conn(:get, "http://localhost:4100/up")
        |> put_req_header("x-forwarded-for", "203.0.113.5")
        |> Router.call(@opts)

      assert conn.remote_ip == {203, 0, 113, 5}
    end

    test "X-Forwarded-For IGNORED when the peer is NOT loopback (no bucket forgery)" do
      conn =
        %{conn(:get, "http://localhost:4100/up") | remote_ip: {198, 51, 100, 9}}
        |> put_req_header("x-forwarded-for", "203.0.113.5")
        |> Router.call(@opts)

      # A directly-reachable client cannot move remote_ip with a spoofed header.
      assert conn.remote_ip == {198, 51, 100, 9}
    end

    test "no X-Forwarded-For → loopback peer is left as-is" do
      conn = Router.call(conn(:get, "http://localhost:4100/up"), @opts)
      assert conn.remote_ip == {127, 0, 0, 1}
    end

    # cch-w1-peer-ip-pin. Measured on production: 48 of 49 user_tokens rows carry
    # 172.18.0.1 and exactly one carries a real client IP. Caddy is a HOST systemd
    # service reverse-proxying to localhost:4100, but Docker's hairpin NAT rewrites
    # the source the container sees to the bridge GATEWAY — so the loopback-only
    # guard was a permanent no-op in prod and every session recorded the gateway.
    test "X-Forwarded-For honored when the peer is the docker bridge gateway" do
      conn =
        %{conn(:get, "http://localhost:4100/up") | remote_ip: {172, 18, 0, 1}}
        |> put_req_header("x-forwarded-for", "203.0.113.5")
        |> Router.call(@opts)

      assert conn.remote_ip == {203, 0, 113, 5}
    end

    # THE PIN, not a 172.16/12 widening (charter D5). This is the ONLY case that
    # distinguishes the two: the three tests above pass under BOTH. With the wide
    # version applied, this peer successfully forged 203.0.113.5 — and
    # cloud-postfix-1 sits on 172.18.0.2 publishing 0.0.0.0:587 to the internet,
    # so widening would hand an internet-facing SMTP container the ability to
    # forge any client's session IP and rate-limit bucket. Do not "simplify" the
    # trusted-peer list into a CIDR range to make this test pass.
    test "X-Forwarded-For IGNORED for a private peer that is NOT the gateway" do
      conn =
        %{conn(:get, "http://localhost:4100/up") | remote_ip: {172, 18, 0, 77}}
        |> put_req_header("x-forwarded-for", "203.0.113.5")
        |> Router.call(@opts)

      assert conn.remote_ip == {172, 18, 0, 77}
    end

    # WHY trusting the gateway is safe: RemoteIp resolves the RIGHTMOST unproxied
    # entry, not the leftmost. Caddy APPENDS the real peer at the right end, so a
    # client-supplied XFF prefix is discarded even once the gateway is trusted.
    # (Had it been leftmost, trusting the gateway would have opened universal
    # client-side IP forgery.) This test pins the property the router's comment
    # claims — it used to claim the opposite.
    test "a multi-hop chain resolves to the RIGHTMOST entry, so a client prefix cannot forge" do
      conn =
        %{conn(:get, "http://localhost:4100/up") | remote_ip: {172, 18, 0, 1}}
        |> put_req_header("x-forwarded-for", "1.2.3.4, 203.0.113.5")
        |> Router.call(@opts)

      assert conn.remote_ip == {203, 0, 113, 5}
    end

    # The trusted peer is config-driven (charter D6) so compose's pinned subnet
    # and the router share ONE source of truth: an operator who moves the bridge
    # moves this value, and nothing about the guard's SHAPE changes.
    test "the trusted-peer list is config-driven, and an unlisted peer stays untrusted" do
      original = Application.get_env(:barkpark_cloud, :trusted_proxy_peers)
      Application.put_env(:barkpark_cloud, :trusted_proxy_peers, [{10, 9, 8, 7}])
      on_exit(fn -> Application.put_env(:barkpark_cloud, :trusted_proxy_peers, original) end)

      trusted =
        %{conn(:get, "http://localhost:4100/up") | remote_ip: {10, 9, 8, 7}}
        |> put_req_header("x-forwarded-for", "203.0.113.5")
        |> Router.call(@opts)

      assert trusted.remote_ip == {203, 0, 113, 5}

      # ...and the default gateway is no longer trusted once it is out of the list.
      untrusted =
        %{conn(:get, "http://localhost:4100/up") | remote_ip: {172, 18, 0, 1}}
        |> put_req_header("x-forwarded-for", "203.0.113.5")
        |> Router.call(@opts)

      assert untrusted.remote_ip == {172, 18, 0, 1}
    end
  end

  # wave 13 S2. `Sites.Deploy.fail/2` writes the SAME string to `failure_reason`
  # and to `detail`, and the build console is raw remote output — so scrubbing
  # only `failure_reason` would ship a redacted field sitting beside its
  # unredacted twin in ONE response. Driven as a plain authenticated NON-admin
  # team member through GET /v1/sites/:id/deployments/:dep_id.
  describe "deployment_json — the failure capture is scrubbed on every field, not just one" do
    @deploy_secret "sk-live-9aB3xQ7zLmNpR4tV6wY2"
    @deploy_capture "ssh: remote said Authorization: Bearer sk-live-9aB3xQ7zLmNpR4tV6wY2"
    @deploy_scrubbed "ssh: remote said Authorization: Bearer [redacted]"

    test "failure_reason, detail AND console all refuse the secret; the DB row stays raw" do
      {user, team} = user_with_team()
      n = System.unique_integer([:positive])
      {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
      {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})

      {:ok, d} =
        Registry.create_deployment(site, %{git_ref: "v1-sha", artifact_url: "file:///tmp/v1.tgz"})

      # What Sites.Deploy.fail/2 writes: the same string in both fields, plus the
      # console line the stage fold appended.
      {:ok, d} =
        Registry.transition_deployment(d, %{
          status: "failed",
          failure_reason: @deploy_capture,
          detail: @deploy_capture,
          # "BUILD" — a stage name Sites.Deploy.stages/1 actually RECOGNIZES, so
          # the stage fold below is exercised rather than filtered away. A
          # lowercase name here made the whole-payload assertion vacuously green.
          console: [
            %{
              "line" => @deploy_capture,
              "detail" => @deploy_capture,
              "stage" => "BUILD",
              "status" => "failed"
            }
          ]
        })

      {:ok, token} = Accounts.create_user_session_token(user)
      conn = call(:get, "/v1/sites/#{site.id}/deployments/#{d.id}", nil, token)
      assert conn.status == 200

      dep = json_body(conn)["deployment"]

      # No field in the payload carries it, and none is redacted while a twin is not.
      refute Jason.encode!(dep) =~ @deploy_secret
      assert dep["failure_reason"] == @deploy_scrubbed
      assert dep["detail"] == @deploy_scrubbed
      assert [%{"line" => @deploy_scrubbed, "detail" => @deploy_scrubbed}] = dep["console"]

      # The stage fold recomputes from the RAW row (Sites.Deploy.stages/1 reads
      # d.console, not this serializer's output), so it is its own boundary.
      assert %{"detail" => @deploy_scrubbed} =
               Enum.find(dep["stages"], &(&1["name"] == "BUILD"))

      # The store is untouched — ops recovery reads the raw bytes.
      raw = Repo.get(Registry.Deployment, d.id)
      assert raw.failure_reason == @deploy_capture
      assert raw.detail == @deploy_capture
      assert [%{"line" => @deploy_capture}] = raw.console
    end

    test "the commit a person deployed survives — a git SHA is not redacted" do
      {user, team} = user_with_team()
      n = System.unique_integer([:positive])
      {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
      {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: "s-#{n}"})

      {:ok, d} =
        Registry.create_deployment(site, %{git_ref: "v1-sha", artifact_url: "file:///tmp/v1.tgz"})

      sha_line = "build of 0f28d541e9a1b2c3d4e5f60718293a4b5c6d7e8f failed"

      {:ok, d} =
        Registry.transition_deployment(d, %{
          status: "failed",
          failure_reason: sha_line,
          detail: sha_line
        })

      {:ok, token} = Accounts.create_user_session_token(user)
      conn = call(:get, "/v1/sites/#{site.id}/deployments/#{d.id}", nil, token)
      assert conn.status == 200

      dep = json_body(conn)["deployment"]
      assert dep["failure_reason"] == sha_line
      assert dep["detail"] == sha_line
    end
  end
end
