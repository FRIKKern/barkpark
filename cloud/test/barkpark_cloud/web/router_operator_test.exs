defmodule BarkparkCloud.Web.RouterOperatorTest do
  @moduledoc """
  GR39 — the session-gated `/v1/operator/*` read seam that turns the 401-dead
  Operator console live. The fleet-ops surface (`/v1/admin/*` + `/v1/internal/*`)
  is `require_worker`, so a browser SESSION bearer is 401-dead there; these thin
  proxies gate on `Auth.require_platform_operator` instead — the SAME
  `Notifications.platform_admin_emails/0` allowlist that feeds `/v1/me`'s
  `platform_operator` boolean.

  Proves the fail-closed 401/403/200 matrix across all six endpoints, that the
  deliveries surface exposes ONLY nil-team `fleet_digest` rows (never a
  team-scoped row and never a nil-team identity email), the fleet shape, and the
  warm-pool shape.

  `async: false` — the operator allowlist is process-global Application config
  (`:platform_admin_emails`), so these tests must not run concurrently against a
  shared key (mirrors DailyDigestWorkerTest).
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Notifications.Delivery
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # Every operator endpoint under test, as {method, path}. The autoupdate trio
  # plus fleet / deliveries / warm-pool.
  @endpoints [
    {:get, "/v1/operator/autoupdate"},
    {:post, "/v1/operator/autoupdate/halt"},
    {:post, "/v1/operator/autoupdate/resume"},
    {:get, "/v1/operator/fleet"},
    {:get, "/v1/operator/deliveries"},
    {:get, "/v1/operator/warm-pool"}
  ]

  setup do
    # Each test owns the allowlist explicitly; restore the config default after.
    prior = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    on_exit(fn -> Application.put_env(:barkpark_cloud, :platform_admin_emails, prior) end)
    :ok
  end

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp user_with_team(role \\ "owner") do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {user, team}
  end

  # A registered user whose email IS on the platform-operator allowlist (the
  # allowlist resolves config emails against registered users, so the account
  # must exist AND be listed).
  defp operator_fixture do
    {user, team} = user_with_team()
    Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
    {user, team}
  end

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  defp delivery_fixture(attrs) do
    # inserted_at is a managed timestamp (not castable) — pop it and stamp it
    # after insert so the newest-first ordering test can control the clock.
    {inserted_at, attrs} = Map.pop(Enum.into(attrs, %{}), :inserted_at)

    {:ok, d} =
      %Delivery{}
      |> Delivery.changeset(
        Enum.into(attrs, %{
          recipient: "someone-#{System.unique_integer([:positive])}@example.com",
          kind: "transactional",
          status: "sent",
          attempts: 1
        })
      )
      |> Repo.insert()

    if inserted_at do
      d |> Ecto.Changeset.change(inserted_at: inserted_at) |> Repo.update!()
    else
      d
    end
  end

  defp call(method, path, token) do
    conn = conn(method, path)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp session_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  ## 1. Fail-closed auth matrix — 401 (no session) / 403 (non-operator session)

  test "no token → 401 on every /v1/operator/* endpoint (fail-closed)" do
    for {method, path} <- @endpoints do
      conn = call(method, path, nil)
      assert conn.status == 401, "#{method} #{path} should 401 without a token"
      assert json_body(conn)["error"] == "unauthorized"
    end
  end

  test "a plain (non-operator) user session → 403 on every endpoint" do
    {user, _team} = user_with_team()
    token = session_token(user)

    for {method, path} <- @endpoints do
      conn = call(method, path, token)
      assert conn.status == 403, "#{method} #{path} should 403 for a non-operator"
      assert json_body(conn)["error"] == "forbidden"
    end

    # the toggle endpoints must not have moved the kill switch
    assert Registry.autoupdate_halted?() == false
  end

  test "an operator session → 200 on every endpoint" do
    {operator, _team} = operator_fixture()
    token = session_token(operator)

    for {method, path} <- @endpoints do
      conn = call(method, path, token)
      assert conn.status == 200, "#{method} #{path} should 200 for an operator"
    end
  end

  ## 2. autoupdate kill-switch read/toggle over the SESSION seam

  test "operator GET reflects state; halt/resume toggle it" do
    {operator, _team} = operator_fixture()
    token = session_token(operator)

    assert json_body(call(:get, "/v1/operator/autoupdate", token))["halted"] == false

    halt = call(:post, "/v1/operator/autoupdate/halt", token)
    assert halt.status == 200
    assert json_body(halt)["halted"] == true
    assert Registry.autoupdate_halted?() == true
    assert json_body(call(:get, "/v1/operator/autoupdate", token))["halted"] == true

    resume = call(:post, "/v1/operator/autoupdate/resume", token)
    assert resume.status == 200
    assert json_body(resume)["halted"] == false
    assert Registry.autoupdate_halted?() == false
  end

  ## 3. Fleet roll-up shape

  test "GET /v1/operator/fleet returns the cross-team roll-up + staging_gate_open" do
    {operator, op_team} = operator_fixture()
    token = session_token(operator)

    # a barkpark in ANOTHER team must appear — the seam is cross-team by design
    {_other, other_team} = user_with_team()

    bp =
      barkpark_fixture(other_team)
      |> Ecto.Changeset.change(
        channel: "staging",
        update_state: "behind",
        autoupdate_triggered_at: ~U[2026-07-10 12:05:00.000000Z]
      )
      |> Repo.update!()

    # and one in the operator's own team, to prove it is not team-scoped
    _own = barkpark_fixture(op_team)

    conn = call(:get, "/v1/operator/fleet", token)
    assert conn.status == 200
    body = json_body(conn)

    assert is_boolean(body["staging_gate_open"])

    row = Enum.find(body["barkparks"], &(&1["id"] == bp.id))
    assert row["name"] == bp.name
    assert row["channel"] == "staging"
    assert row["update_state"] == "behind"
    assert row["autoupdate_triggered_at"] == "2026-07-10T12:05:00.000000Z"

    # both teams' instances are present (cross-team, ≥ 2 rows)
    assert length(body["barkparks"]) >= 2
  end

  ## 4. Deliveries — ONLY nil-team fleet_digest rows; no leak

  test "GET /v1/operator/deliveries returns nil-team fleet_digest rows and never leaks team or identity rows" do
    {operator, _op_team} = operator_fixture()
    token = session_token(operator)

    {_owner, team} = user_with_team()

    fleet = delivery_fixture(%{team_id: nil, event: "fleet_digest", recipient: "ops@example.com"})
    team_row = delivery_fixture(%{team_id: team.id, event: "past_due"})
    # a nil-team NON-fleet row (identity email) — is_nil(team_id) alone would
    # leak it, so the event filter must exclude it
    identity_row = delivery_fixture(%{team_id: nil, event: "reset"})

    conn = call(:get, "/v1/operator/deliveries", token)
    assert conn.status == 200
    rows = json_body(conn)["deliveries"]
    ids = Enum.map(rows, & &1["id"])

    assert fleet.id in ids
    refute team_row.id in ids
    refute identity_row.id in ids

    # every returned row is a fleet_digest send
    assert Enum.map(rows, & &1["event"]) |> Enum.uniq() == ["fleet_digest"]
  end

  test "GET /v1/operator/deliveries is newest-first and ?limit caps the page" do
    {operator, _t} = operator_fixture()
    token = session_token(operator)

    older =
      delivery_fixture(%{
        team_id: nil,
        event: "fleet_digest",
        inserted_at: ~U[2026-07-01 00:00:00.000000Z]
      })

    newer =
      delivery_fixture(%{
        team_id: nil,
        event: "fleet_digest",
        inserted_at: ~U[2026-07-02 00:00:00.000000Z]
      })

    rows = json_body(call(:get, "/v1/operator/deliveries", token))["deliveries"]
    ids = Enum.map(rows, & &1["id"])
    assert Enum.find_index(ids, &(&1 == newer.id)) < Enum.find_index(ids, &(&1 == older.id))

    limited = json_body(call(:get, "/v1/operator/deliveries?limit=1", token))["deliveries"]
    assert length(limited) == 1
    assert hd(limited)["id"] == newer.id
  end

  ## 5. Warm-pool shape

  test "GET /v1/operator/warm-pool returns {ready: count}" do
    {operator, _t} = operator_fixture()
    token = session_token(operator)

    conn = call(:get, "/v1/operator/warm-pool", token)
    assert conn.status == 200
    assert json_body(conn) == %{"ready" => Registry.count_ready_warm_servers()}
  end
end
