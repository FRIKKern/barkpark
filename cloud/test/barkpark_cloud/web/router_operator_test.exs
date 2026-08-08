defmodule BarkparkCloud.Web.RouterOperatorTest do
  @moduledoc """
  GR39 — the session-gated `/v1/operator/*` read seam that turns the 401-dead
  Operator console live. The fleet-ops surface (`/v1/admin/*` + `/v1/internal/*`)
  is `require_worker`, so a browser SESSION bearer is 401-dead there; these thin
  proxies gate on `Auth.require_platform_operator` instead — the SAME
  `Notifications.platform_admin_emails/0` allowlist that feeds `/v1/me`'s
  `platform_operator` boolean.

  Proves the fail-closed 401/403/200 matrix across all six endpoints, that the
  deliveries surface returns the receipts a REAL `deliver_fleet_digest/1` run
  writes and nothing else (never a team-scoped alert row, never an identity
  email), the fleet shape, and the warm-pool shape.

  RETRACTED (cch-w56-s3): this moduledoc used to say the deliveries surface
  "exposes ONLY nil-team `fleet_digest` rows". It pinned a shape the writer can
  never produce — `deliver_fleet_digest/1` builds targets under an
  `is_binary(team_id)` guard, so every receipt carries a REAL `team_id` — which
  is why the old fixtures were 8/8 green under BOTH the broken reader and the
  fixed one. The deliveries tests now DRIVE the writer and read the route.

  `async: false` — the operator allowlist is process-global Application config
  (`:platform_admin_emails`), so these tests must not run concurrently against a
  shared key (mirrors DailyDigestWorkerTest).
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Notifications, Registry, Repo}
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

  ## 4. Deliveries — the receipts a REAL digest run writes; no leak
  ##
  ## These tests DRIVE `Notifications.deliver_fleet_digest/1` — real team, real
  ## membership rows, real Mailer (Swoosh test adapter), real Repo insert — and
  ## then dispatch the real route. A hand-inserted `%Delivery{}` cannot stand in:
  ## the only shape a fixture is free to invent is one `record_delivery/5` can
  ## never write, and that is exactly how the previous version of this file
  ## stayed green under a reader that returned nothing on prod.

  # One real digest run for `team`, returning the Delivery rows it wrote.
  defp drive_digest(team) do
    before = Repo.all(Delivery) |> MapSet.new(& &1.id)
    barkpark = barkpark_fixture(team)
    assert {:ok, %{sent: sent}} = Notifications.deliver_fleet_digest([barkpark])
    assert sent > 0, "the digest must actually send for this drive to prove anything"
    Repo.all(Delivery) |> Enum.reject(&MapSet.member?(before, &1.id))
  end

  test "GET /v1/operator/deliveries returns the receipts a REAL digest run wrote" do
    {operator, _op_team} = operator_fixture()
    token = session_token(operator)

    {_member, team} = user_with_team("member")
    [receipt] = drive_digest(team)

    # the writer's own shape, restated here so the reader is tested against
    # reality and not against a fixture's imagination
    assert receipt.event == "fleet_digest"
    assert receipt.team_id == team.id
    refute is_nil(receipt.team_id)

    conn = call(:get, "/v1/operator/deliveries", token)
    assert conn.status == 200
    rows = json_body(conn)["deliveries"]

    assert receipt.id in Enum.map(rows, & &1["id"]),
           "the operator log must return the row a real deliver_fleet_digest/1 run just wrote"

    row = Enum.find(rows, &(&1["id"] == receipt.id))
    assert row["event"] == "fleet_digest"
    assert row["recipient"] == receipt.recipient
    assert row["status"] == "sent"
  end

  test "GET /v1/operator/deliveries is CROSS-TEAM — every team's digest receipts, one page" do
    {operator, _op_team} = operator_fixture()
    token = session_token(operator)

    {_a, team_a} = user_with_team("member")
    {_b, team_b} = user_with_team("member")
    [a_receipt] = drive_digest(team_a)
    [b_receipt] = drive_digest(team_b)

    ids = json_body(call(:get, "/v1/operator/deliveries", token))["deliveries"] |> Enum.map(& &1["id"])

    assert a_receipt.id in ids
    assert b_receipt.id in ids
  end

  test "GET /v1/operator/deliveries never leaks a team alert row or an identity email" do
    {operator, _op_team} = operator_fixture()
    token = session_token(operator)

    {_owner, team} = user_with_team()
    [receipt] = drive_digest(team)

    # The EVENT filter is now the only filter, so these two are what it holds
    # back: a team-scoped alert row and a user-scoped identity email.
    team_row = delivery_fixture(%{team_id: team.id, event: "past_due"})
    identity_row = delivery_fixture(%{team_id: nil, event: "reset"})

    rows = json_body(call(:get, "/v1/operator/deliveries", token))["deliveries"]
    ids = Enum.map(rows, & &1["id"])

    assert receipt.id in ids
    refute team_row.id in ids
    refute identity_row.id in ids
    assert rows |> Enum.map(& &1["event"]) |> Enum.uniq() == ["fleet_digest"]
  end

  test "GET /v1/operator/deliveries is newest-first and ?limit caps the page" do
    {operator, _t} = operator_fixture()
    token = session_token(operator)

    {_u1, team_a} = user_with_team("member")
    {_u2, team_b} = user_with_team("member")

    # Real receipts; only the CLOCK is controlled (inserted_at is a managed
    # timestamp, so the ordering assertion needs it stamped after insert).
    [older] = drive_digest(team_a)
    [newer] = drive_digest(team_b)

    older =
      older |> Ecto.Changeset.change(inserted_at: ~U[2026-07-01 00:00:00.000000Z]) |> Repo.update!()

    newer =
      newer |> Ecto.Changeset.change(inserted_at: ~U[2026-07-02 00:00:00.000000Z]) |> Repo.update!()

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
