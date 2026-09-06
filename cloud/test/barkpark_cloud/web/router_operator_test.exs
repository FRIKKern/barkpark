defmodule BarkparkCloud.Web.RouterOperatorTest do
  @moduledoc """
  GR39 — the session-gated `/v1/operator/*` read seam that turns the 401-dead
  Operator console live. The fleet-ops surface (`/v1/admin/*` + `/v1/internal/*`)
  is `require_worker`, so a browser SESSION bearer is 401-dead there; these thin
  proxies gate on `Auth.require_platform_operator` instead — the SAME
  `Notifications.platform_admin_emails/0` allowlist that feeds `/v1/me`'s
  `platform_operator` boolean.

  Proves the fail-closed 401/403/200 matrix across all SEVEN endpoints (the
  seventh, `/v1/operator/barkparks/without-agent-token`, is the disarmed-box
  census — task-5cc3689cb0ab6637), that the
  deliveries surface returns the receipts a REAL `deliver_fleet_digest/1` run
  writes and nothing else (never a team-scoped alert row, never an identity
  email), the fleet shape, and the warm-pool shape.

  §2b is the PRINCIPAL BOUNDARY (isu-backlog-operator-principal): the fleet kill
  switch has one human principal — the platform operator — and the two doors are
  DISJOINT. A worker token is refused on `/v1/operator/autoupdate*` (401: it is
  not a session, so authentication fails before the allowlist is consulted), an
  operator session is refused on `/v1/admin/autoupdate*` (401: it is not the
  worker secret), a foreign team's OWNER passes neither, and no refused call ever
  moves the switch. The positive side of this ruling — that `bp cloud rollout`
  now knocks on the operator door with the caller's session — is pinned in
  `internal/cli/cloud_autoupdate_cmd_test.go` and
  `internal/cloudclient/autoupdate_test.go`.

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
    {:get, "/v1/operator/warm-pool"},
    {:get, "/v1/operator/barkparks/without-agent-token"}
  ]

  # The kill-switch trio on BOTH sides of the principal boundary. The operator
  # trio is session-gated (`require_platform_operator`); the admin trio is the
  # faceless WORKER's (`require_worker`) and stays that way — the off-box Go
  # provisioner is its only caller.
  @operator_autoupdate [
    {:get, "/v1/operator/autoupdate"},
    {:post, "/v1/operator/autoupdate/halt"},
    {:post, "/v1/operator/autoupdate/resume"}
  ]

  @admin_autoupdate [
    {:get, "/v1/admin/autoupdate"},
    {:post, "/v1/admin/autoupdate/halt"},
    {:post, "/v1/admin/autoupdate/resume"}
  ]

  # The value config/test.exs pins as `:worker_token` — the same constant the
  # nine other worker-auth suites present. Using the REAL configured secret is
  # what makes the refusals below mean something: a made-up string would 401 on
  # `require_worker` for being wrong, and would prove nothing about the
  # principal boundary.
  @worker_token "worker-token-test-fixed"

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

  ## 2b. The PRINCIPAL BOUNDARY — isu-backlog-operator-principal
  ##
  ## The ruling: the fleet kill switch has ONE human principal, the platform
  ## operator (a session whose email is on the `PLATFORM_ADMIN_EMAILS`
  ## allowlist), and it is reachable from BOTH shipped human surfaces — the
  ## console SPA and `bp cloud rollout`. The `/v1/admin/autoupdate*` trio stays
  ## the faceless WORKER's and is NOT widened.
  ##
  ## The tests above prove the operator door OPENS. These prove it is a door and
  ## not a hole: that the two credentials do not cross, in BOTH directions, and
  ## that a refused call moves nothing. Without the negative half, "the operator
  ## can halt the fleet" is compatible with "and so can everyone else".

  test "the WORKER token opens the /v1/admin/autoupdate trio (the control for the refusals below)" do
    # This is the non-vacuity check. Every refusal below presents @worker_token;
    # if that constant were stale or wrong, `require_worker`'s constant-time
    # compare would 401 it for being a BAD SECRET and the refusals would prove
    # nothing about the principal boundary. So first: it is a real, working
    # worker credential on the routes that are actually the worker's.
    assert json_body(call(:get, "/v1/admin/autoupdate", @worker_token))["halted"] == false

    halt = call(:post, "/v1/admin/autoupdate/halt", @worker_token)
    assert halt.status == 200
    assert Registry.autoupdate_halted?() == true

    resume = call(:post, "/v1/admin/autoupdate/resume", @worker_token)
    assert resume.status == 200
    assert Registry.autoupdate_halted?() == false
  end

  test "a WORKER token is refused on every /v1/operator/autoupdate route, and moves nothing" do
    # 401, NOT 403, and the distinction is load-bearing:
    # `require_platform_operator/2` runs `require_user/2` FIRST, and a worker
    # secret is not a session token — `verify_user_session_token/2` returns nil,
    # so AUTHENTICATION fails and the allowlist check is never reached. 403 is
    # reserved for a credential that resolved to a real human who is simply not
    # on the list (the "plain session" test above). A machine secret is not a
    # human, so it cannot earn the 403 wording.
    for {method, path} <- @operator_autoupdate do
      conn = call(method, path, @worker_token)

      assert conn.status == 401,
             "#{method} #{path} must refuse the WORKER token (got #{conn.status}) — " <>
               "the operator seam is for human sessions, not the off-box provisioner secret"

      assert json_body(conn)["error"] == "unauthorized"
    end

    assert Registry.autoupdate_halted?() == false,
           "a refused worker call moved the fleet kill switch"
  end

  test "an OPERATOR session is refused on every /v1/admin/autoupdate route, and moves nothing" do
    {operator, _team} = operator_fixture()
    token = session_token(operator)

    # Non-vacuity in the other direction: this exact token DOES open the
    # operator seam, so a 401 below is about the DOOR, not a dud session.
    assert call(:get, "/v1/operator/autoupdate", token).status == 200

    for {method, path} <- @admin_autoupdate do
      conn = call(method, path, token)

      assert conn.status == 401,
             "#{method} #{path} must refuse even an OPERATOR session (got #{conn.status}) — " <>
               "the worker routes are not a second operator door"

      assert json_body(conn)["error"] == "unauthorized"
    end

    assert Registry.autoupdate_halted?() == false
  end

  test "a FOREIGN team's OWNER session passes neither door" do
    # The operator allowlist holds exactly one email; the foreigner owns their
    # own team, which is the strongest team authority the product grants. Team
    # role and platform-operator are different axes (GR46) — owning a team must
    # buy nothing at all here.
    {operator, _op_team} = operator_fixture()
    foreign = session_token(elem(user_with_team("owner"), 0))

    for {method, path} <- @operator_autoupdate do
      conn = call(method, path, foreign)
      assert conn.status == 403, "#{method} #{path} let a foreign team owner through"
      body = json_body(conn)
      assert body["error"] == "forbidden"
      assert body["required"] == "platform_operator"
      assert body["scope"] == "platform"
    end

    for {method, path} <- @admin_autoupdate do
      assert call(method, path, foreign).status == 401,
             "#{method} #{path} let a foreign team owner through"
    end

    assert Registry.autoupdate_halted?() == false

    # …and the operator still gets in, so the refusals above are about WHO the
    # caller is, not about a route that is dead for everyone.
    assert call(:get, "/v1/operator/autoupdate", session_token(operator)).status == 200
  end

  test "the two doors are DISJOINT — no single credential opens both" do
    {operator, _op_team} = operator_fixture()
    op = session_token(operator)
    plain = session_token(elem(user_with_team(), 0))

    # One full-equality matrix rather than six independent asserts: a widening
    # on EITHER side (an operator session accepted by require_worker, a worker
    # token accepted by the operator seam, a plain session accepted anywhere)
    # changes a cell and reds this test, and no cell can be satisfied by
    # accident the way a scattered `assert status != 200` can.
    matrix =
      for {label, token} <- [
            {"worker token", @worker_token},
            {"operator session", op},
            {"plain session", plain}
          ] do
        {label, call(:get, "/v1/operator/autoupdate", token).status,
         call(:get, "/v1/admin/autoupdate", token).status}
      end

    assert matrix == [
             {"worker token", 401, 200},
             {"operator session", 200, 401},
             {"plain session", 403, 401}
           ]
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

  test "GET /v1/operator/fleet carries the ARMING roster, and UNMEASURED is not UNARMED" do
    # The read the retro-arm gate needs: WHICH boxes will 503 the moment the
    # rollout reaches them. It only works if the three worlds survive the wire —
    # a pre-#12995 box (no `apply_enabled` key, so NULL on the row) must NOT
    # arrive looking like a measured unarmed box, or every old box lands on the
    # worklist and the roster is worthless.
    {operator, op_team} = operator_fixture()
    token = session_token(operator)

    measured_at = ~U[2026-08-20 09:15:00.000000Z]

    unarmed =
      barkpark_fixture(op_team)
      |> Ecto.Changeset.change(apply_arming: "unarmed", apply_arming_checked_at: measured_at)
      |> Repo.update!()

    armed =
      barkpark_fixture(op_team)
      |> Ecto.Changeset.change(apply_arming: "armed", apply_arming_checked_at: measured_at)
      |> Repo.update!()

    # Never measured: both columns NULL, exactly as a pre-#12995 row sits today.
    unmeasured = barkpark_fixture(op_team)

    body = json_body(call(:get, "/v1/operator/fleet", token))
    row = fn bp -> Enum.find(body["barkparks"], &(&1["id"] == bp.id)) end

    assert row.(unarmed)["apply_arming"] == "unarmed"
    assert row.(unarmed)["apply_arming_checked_at"] == "2026-08-20T09:15:00.000000Z"
    assert row.(armed)["apply_arming"] == "armed"

    # THE DISCRIMINATION, asserted as a difference and not as two independent
    # equalities: a serializer that defaulted the absent measurement to "unarmed"
    # (or to false) would satisfy an `== "unarmed"` on the unarmed row just as
    # happily.
    assert is_nil(row.(unmeasured)["apply_arming"])
    assert is_nil(row.(unmeasured)["apply_arming_checked_at"])

    refute row.(unmeasured)["apply_arming"] == row.(unarmed)["apply_arming"],
           "an unmeasured box and a measured-unarmed box read the same on the wire — " <>
             "the retro-arm roster cannot tell an old box from a broken one"

    # And the operator can actually ANSWER the question off this payload.
    worklist =
      body["barkparks"]
      |> Enum.filter(&(&1["apply_arming"] == "unarmed"))
      |> Enum.map(& &1["id"])

    assert unarmed.id in worklist
    refute armed.id in worklist
    refute unmeasured.id in worklist
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

    ids =
      json_body(call(:get, "/v1/operator/deliveries", token))["deliveries"]
      |> Enum.map(& &1["id"])

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
      older
      |> Ecto.Changeset.change(inserted_at: ~U[2026-07-01 00:00:00.000000Z])
      |> Repo.update!()

    newer =
      newer
      |> Ecto.Changeset.change(inserted_at: ~U[2026-07-02 00:00:00.000000Z])
      |> Repo.update!()

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

  ## 6. The disarmed-box census — GET /v1/operator/barkparks/without-agent-token
  ##
  ## task-5cc3689cb0ab6637. The auth matrix above already covers this path (it
  ## is in @endpoints), so these tests are about the PAYLOAD: that the route
  ## reports the boxes the Registry census reports, and that every row names
  ## the REMEDY rather than leaving the operator with a count.

  test "GET /v1/operator/barkparks/without-agent-token reports the disarmed boxes, and each row names its remedy" do
    {operator, team} = operator_fixture()
    token = session_token(operator)

    disarmed = barkpark_fixture(team)
    {:ok, pt, _t} = Registry.mint_agent_token(disarmed, "report:health")
    {:ok, _} = Registry.revoke_agent_token(pt)

    live = barkpark_fixture(team)
    {:ok, _pt, _t} = Registry.mint_agent_token(live, "report:health")

    conn = call(:get, "/v1/operator/barkparks/without-agent-token", token)
    assert conn.status == 200
    body = json_body(conn)

    slugs = Enum.map(body["barkparks"], & &1["slug"])
    assert disarmed.slug in slugs
    refute live.slug in slugs
    assert body["count"] == length(body["barkparks"])

    row = Enum.find(body["barkparks"], &(&1["slug"] == disarmed.slug))

    # The remedy is on the ROW, in the imperative — a census that answers only
    # a number is a number an operator cannot act on.
    assert row["remedy"] =~ "re-provision"
    assert row["remedy"] =~ "resurrect"

    # And the fields that separate DISARMED from NEVER ARMED ride with it.
    assert row["revoked_token_count"] == 1
    assert row["last_revoked_at"]
    assert row["agent_status"] == disarmed.agent_status
    assert row["suspended"] == false

    # EVERY row names its remedy, not just the one under test.
    assert Enum.all?(body["barkparks"], &is_binary(&1["remedy"]))
  end

  # Console review of #16486, folded in: a box with NO token ever and NO check-in
  # is provisioning, not disarmed. Its remedy must say what TO do (wait, re-check
  # after N minutes) and must NOT be the terminal "re-provision or resurrect".
  test "a still-provisioning box (no token ever, never seen) gets a WAIT remedy with a clock, not re-provision" do
    {operator, team} = operator_fixture()
    token = session_token(operator)

    fresh = barkpark_fixture(team)
    assert fresh.last_seen_at == nil, "the fixture must never have checked in"

    conn = call(:get, "/v1/operator/barkparks/without-agent-token", token)
    assert conn.status == 200
    row = Enum.find(json_body(conn)["barkparks"], &(&1["slug"] == fresh.slug))
    assert row, "a never-armed box must still be IN the census — it holds no live token"

    assert row["token_count"] == 0
    assert row["inserted_at"], "inserted_at rides on the row so the operator can see the clock"
    assert row["remedy"] =~ "still provisioning"
    assert row["remedy"] =~ ~r/re-check this census after \d+ min/
    refute row["remedy"] =~ "resurrect"
    refute row["remedy"] =~ ~r/^re-provision/
  end

  test "a never-armed box registered PAST the support-provision threshold is told the provision never completed" do
    {operator, team} = operator_fixture()
    token = session_token(operator)

    old = barkpark_fixture(team)

    past =
      DateTime.add(
        DateTime.utc_now(),
        -(Registry.stale_after_seconds("provision_support") + 60),
        :second
      )
    {:ok, _} = old |> Ecto.Changeset.change(inserted_at: past) |> Repo.update()

    conn = call(:get, "/v1/operator/barkparks/without-agent-token", token)
    row = Enum.find(json_body(conn)["barkparks"], &(&1["slug"] == old.slug))
    assert row

    assert row["remedy"] =~ "the provision never completed"
    assert row["remedy"] =~ "Re-provision the box"
    refute row["remedy"] =~ "still provisioning"
  end

  test "a DISARMED box (had a token, revoked) keeps the terminal remedy — the wait branch is scoped to never-armed" do
    {operator, team} = operator_fixture()
    token = session_token(operator)

    disarmed = barkpark_fixture(team)
    {:ok, pt, _t} = Registry.mint_agent_token(disarmed, "report:health")
    {:ok, _} = Registry.revoke_agent_token(pt)

    conn = call(:get, "/v1/operator/barkparks/without-agent-token", token)
    row = Enum.find(json_body(conn)["barkparks"], &(&1["slug"] == disarmed.slug))
    assert row["remedy"] =~ "re-provision or resurrect"
    refute row["remedy"] =~ "still provisioning"
  end
end
