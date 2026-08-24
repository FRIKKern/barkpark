defmodule BarkparkCloud.Web.RouterAutoupdateTest do
  @moduledoc """
  isu-w4 — `PATCH /v1/barkparks/:id/autoupdate`: the team-facing fleet-autoupdate
  policy escape hatch (opt-out / pause / pin). Proves the narrow setter, PATCH
  semantics (absent keys untouched), the ADMIN gate, and team-scope fail-closed.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router
  alias BarkparkCloud.Workers.AutoupdateRolloutWorker

  @opts Router.init([])
  @password "correct-horse-battery"
  @worker_token "worker-token-test-fixed"

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

  defp barkpark_fixture(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  defp patch_autoupdate(id, token, body) do
    conn =
      conn(:patch, "/v1/barkparks/#{id}/autoupdate", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp call(method, path, body, token) do
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

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # ── task-0dd7578bc3d2bcbd fixtures: a LIVE box the arming probe can reach ──
  @admin_token "instance-admin-token-plaintext"

  defp live_behind(team, overrides \\ %{}) do
    n = System.unique_integer([:positive])

    barkpark_fixture(team)
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          host: "203.0.113.#{rem(n, 250) + 1}",
          url: "https://bp-#{n}.barkpark.cloud",
          admin_token_encrypted: Vault.encrypt(@admin_token),
          update_state: "behind",
          update_checked_at: DateTime.utc_now(),
          autoupdate_enabled: true,
          autoupdate_paused: false
        },
        overrides
      )
    )
    |> Repo.update!()
  end

  # GET /v1/admin/self-update as the box answers it, with the #12995
  # `apply_enabled` SIBLING of `check` that `refresh_update_status/1` mirrors
  # into `apply_arming`.
  defp self_update_body(state, apply_enabled) do
    Jason.encode!(%{
      state: "idle",
      apply_enabled: apply_enabled,
      check: %{state: state, running_release: "v0.2.24", latest_release: "v0.3.0"}
    })
  end

  test "team admin sets policy → 200; row updated; blank pin normalized to nil" do
    {user, team} = user_with_team()
    bp = barkpark_fixture(team)
    {:ok, token} = Accounts.create_user_session_token(user)

    conn =
      patch_autoupdate(bp.id, token, %{
        "autoupdate_enabled" => false,
        "autoupdate_paused" => true,
        "pinned_release" => "  "
      })

    assert conn.status == 200

    assert json_body(conn)["autoupdate"] == %{
             "enabled" => false,
             "paused" => true,
             "pinned_release" => nil,
             "channel" => "prod"
           }

    reloaded = Registry.get_barkpark(bp.id)
    assert reloaded.autoupdate_enabled == false
    assert reloaded.autoupdate_paused == true
    assert reloaded.pinned_release == nil
  end

  test "PATCH leaves absent keys unchanged" do
    {user, team} = user_with_team()

    bp =
      barkpark_fixture(team) |> Ecto.Changeset.change(autoupdate_enabled: true) |> Repo.update!()

    {:ok, token} = Accounts.create_user_session_token(user)

    conn = patch_autoupdate(bp.id, token, %{"pinned_release" => "v0.2.24"})

    assert conn.status == 200
    reloaded = Registry.get_barkpark(bp.id)
    # only the pin changed; enabled stayed true
    assert reloaded.pinned_release == "v0.2.24"
    assert reloaded.autoupdate_enabled == true
  end

  # cch-w62-bl — the 422 arm is FLAT and carries the changeset's own answer.
  # This route used to be the router's one mixed-shape route: flat 404s beside
  # a nested, details-less `%{error: %{code: "invalid"}}` 422 — so the console's
  # per-field details ladder (wave 37, D412) was unreachable here and a
  # PERMANENT validation refusal rendered as a generic. The flat shape below is
  # what the ladder reads; the envelope-shape census
  # (router_error_envelope_census_test.exs) pins the route all-flat.
  test "a refused policy → 422 FLAT %{error, details} naming the field and rule" do
    {user, team} = user_with_team()
    bp = barkpark_fixture(team)
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = patch_autoupdate(bp.id, token, %{"pinned_release" => String.duplicate("v", 256)})

    assert conn.status == 422
    body = json_body(conn)
    # FLAT: the slug is a string at the top level, never `%{"code" => …}` …
    assert body["error"] == "invalid"
    # … and the changeset's per-field answer rides `details` at the TOP level,
    # where friendly()'s ladder reads it.
    assert body["details"] == %{"pinned_release" => ["should be at most 255 character(s)"]}
    # the row did not move
    assert Registry.get_barkpark(bp.id).pinned_release == nil
  end

  test "a plain team member → 403" do
    {user, team} = user_with_team("member")
    bp = barkpark_fixture(team)
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = patch_autoupdate(bp.id, token, %{"autoupdate_paused" => true})
    assert conn.status == 403
    assert Registry.get_barkpark(bp.id).autoupdate_paused == false
  end

  test "an admin of another team gets 404 (scope fail-closed, no existence leak)" do
    {_owner, team_a} = user_with_team()
    bp = barkpark_fixture(team_a)

    {other, _team_b} = user_with_team()
    {:ok, token} = Accounts.create_user_session_token(other)

    conn = patch_autoupdate(bp.id, token, %{"autoupdate_paused" => true})
    assert conn.status == 404
  end

  test "unauthenticated → 401" do
    {_user, team} = user_with_team()
    bp = barkpark_fixture(team)

    conn = patch_autoupdate(bp.id, nil, %{"autoupdate_paused" => true})
    assert conn.status == 401
  end

  # ── isu-w5.2 (review): channel is an OPERATOR lever — never tenant-writable ─
  # A tenant-writable channel would let any team admin park a behind staging box
  # (or pause one) and close the canary gate (staging_gate_open?/0) for the
  # WHOLE fleet — or jump the update queue ahead of it. The tenant PATCH ignores
  # the key; the write lives on the worker-token surface tested below.
  test "tenant PATCH ignores channel — echoed read-only, row untouched" do
    {user, team} = user_with_team()
    bp = barkpark_fixture(team)
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = patch_autoupdate(bp.id, token, %{"channel" => "staging"})
    # 200 per PATCH semantics (uncastable keys are ignored), but the channel
    # did NOT move — the echo stays honest to the row
    assert conn.status == 200
    assert json_body(conn)["autoupdate"]["channel"] == "prod"
    assert Registry.get_barkpark(bp.id).channel == "prod"
  end

  describe "PATCH /v1/admin/barkparks/:id/channel (operator channel lever)" do
    test "worker token assigns staging → 200, row updated" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      conn =
        call(
          :patch,
          "/v1/admin/barkparks/#{bp.id}/channel",
          %{"channel" => "staging"},
          @worker_token
        )

      assert conn.status == 200
      assert json_body(conn) == %{"ok" => true, "id" => bp.id, "channel" => "staging"}
      assert Registry.get_barkpark(bp.id).channel == "staging"
    end

    test "rejects an unknown channel → 422, row unchanged" do
      {_user, team} = user_with_team()
      bp = barkpark_fixture(team)

      conn =
        call(
          :patch,
          "/v1/admin/barkparks/#{bp.id}/channel",
          %{"channel" => "canary"},
          @worker_token
        )

      assert conn.status == 422
      assert Registry.get_barkpark(bp.id).channel == "prod"
    end

    test "fails CLOSED: no token → 401; a team-admin session token → 401" do
      {user, team} = user_with_team()
      bp = barkpark_fixture(team)
      {:ok, token} = Accounts.create_user_session_token(user)

      path = "/v1/admin/barkparks/#{bp.id}/channel"
      assert call(:patch, path, %{"channel" => "staging"}, nil).status == 401
      assert call(:patch, path, %{"channel" => "staging"}, token).status == 401
      assert Registry.get_barkpark(bp.id).channel == "prod"
    end

    test "unknown / malformed id → 404" do
      body = %{"channel" => "staging"}
      missing = "/v1/admin/barkparks/#{Ecto.UUID.generate()}/channel"
      assert call(:patch, missing, body, @worker_token).status == 404

      assert call(:patch, "/v1/admin/barkparks/not-a-uuid/channel", body, @worker_token).status ==
               404
    end
  end

  # ── isu-w5.2: pin honesty on the console Update relay ──────────────────────
  test "self-update on a PINNED box → 409 pinned (no force)" do
    {user, team} = user_with_team()

    bp =
      barkpark_fixture(team) |> Ecto.Changeset.change(pinned_release: "v0.2.24") |> Repo.update!()

    {:ok, token} = Accounts.create_user_session_token(user)

    conn =
      conn(:post, "/v1/barkparks/#{bp.id}/self-update", "{}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(@opts)

    assert conn.status == 409
    assert json_body(conn)["error"]["code"] == "pinned"
    # the body NAMES the pin — the console conflict modal shows which release
    # holds the box (S3 reads error.pinned_release)
    assert json_body(conn)["error"]["pinned_release"] == "v0.2.24"
  end

  # ── isu-w5.2: fleet-wide kill switch (platform-operator gated) ─────────────
  describe "GET/POST /v1/admin/autoupdate (kill switch)" do
    test "worker token: GET reflects state, halt/resume toggle it" do
      assert json_body(call(:get, "/v1/admin/autoupdate", nil, @worker_token))["halted"] == false

      halt = call(:post, "/v1/admin/autoupdate/halt", %{}, @worker_token)
      assert halt.status == 200
      assert json_body(halt)["halted"] == true
      assert json_body(call(:get, "/v1/admin/autoupdate", nil, @worker_token))["halted"] == true

      resume = call(:post, "/v1/admin/autoupdate/resume", %{}, @worker_token)
      assert resume.status == 200
      assert json_body(resume)["halted"] == false
      assert Registry.autoupdate_halted?() == false
    end

    test "fails CLOSED: no token → 401 on every route, state untouched" do
      assert call(:get, "/v1/admin/autoupdate", nil, nil).status == 401
      assert call(:post, "/v1/admin/autoupdate/halt", %{}, nil).status == 401
      assert call(:post, "/v1/admin/autoupdate/resume", %{}, nil).status == 401
      assert Registry.autoupdate_halted?() == false
    end

    test "fails CLOSED: a plain user session token is NOT a platform operator → 401" do
      {user, _team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)
      assert call(:post, "/v1/admin/autoupdate/halt", %{}, token).status == 401
      assert Registry.autoupdate_halted?() == false
    end
  end

  # ── isu-w5.2: fleet-list JSON contract emission (Decision 10) ──────────────
  test "GET /v1/barkparks emits autoupdate_enabled/paused, pinned_release, channel, update_checked_at" do
    {user, team} = user_with_team()

    _bp =
      barkpark_fixture(team)
      |> Ecto.Changeset.change(
        autoupdate_enabled: false,
        autoupdate_paused: true,
        pinned_release: "v0.2.24",
        channel: "staging",
        update_checked_at: ~U[2026-07-10 12:00:00.000000Z],
        autoupdate_triggered_at: ~U[2026-07-10 12:05:00.000000Z]
      )
      |> Repo.update!()

    {:ok, token} = Accounts.create_user_session_token(user)
    conn = call(:get, "/v1/barkparks", nil, token)
    assert conn.status == 200

    [row] = json_body(conn)["barkparks"]
    assert row["autoupdate_enabled"] == false
    assert row["autoupdate_paused"] == true
    assert row["pinned_release"] == "v0.2.24"
    assert row["channel"] == "staging"
    assert row["update_checked_at"] == "2026-07-10T12:00:00.000000Z"
    # the in-flight marker rides along — the console "Updating" badge reads it
    assert row["autoupdate_triggered_at"] == "2026-07-10T12:05:00.000000Z"
  end

  # ── dr-w24-s2: the commit-distance measurement leaves the database ─────────
  #
  # The control plane has measured commit distance hourly since W21 and NOTHING
  # read it: no serializer, no route, no CLI, no console. Prod carries rows that
  # read commit_distance 2493 / commit_ancestry "behind" / update_state
  # "current" — the honest column and the reassuring one on the SAME ROW, with
  # only the reassuring one reaching a human. This asserts the three keys are on
  # the wire, and that a NULL distance travels as null (never 0).
  test "GET /v1/barkparks emits commit_distance, commit_ancestry, commit_distance_checked_at" do
    {user, team} = user_with_team()

    _measured =
      barkpark_fixture(team)
      |> Ecto.Changeset.change(
        name: "measured",
        update_state: "current",
        commit_distance: 2493,
        commit_ancestry: "behind",
        commit_distance_checked_at: ~U[2026-08-08 12:17:01.000000Z]
      )
      |> Repo.update!()

    _unmeasured =
      barkpark_fixture(team)
      |> Ecto.Changeset.change(
        name: "unmeasured",
        update_state: "current",
        commit_distance: nil,
        commit_ancestry: "unknown",
        commit_distance_checked_at: ~U[2026-08-08 12:17:08.000000Z]
      )
      |> Repo.update!()

    {:ok, token} = Accounts.create_user_session_token(user)
    conn = call(:get, "/v1/barkparks", nil, token)
    assert conn.status == 200

    rows = json_body(conn)["barkparks"]
    measured = Enum.find(rows, &(&1["name"] == "measured"))
    unmeasured = Enum.find(rows, &(&1["name"] == "unmeasured"))

    # All three keys, present on the row that carries a measurement.
    assert measured["commit_distance"] == 2493
    assert measured["commit_ancestry"] == "behind"
    assert measured["commit_distance_checked_at"] == "2026-08-08T12:17:01.000000Z"
    # …beside the release-tag grade they contradict. Both travel; the reader
    # decides. (update_state is pinned at `current` because no release tag has
    # been cut since 2026-07-08, not because it cannot say `behind`.)
    assert measured["update_state"] == "current"

    # UNMEASURED travels as null, never 0 — the whole honesty rung of the field.
    assert Map.has_key?(unmeasured, "commit_distance")
    assert unmeasured["commit_distance"] == nil
    assert unmeasured["commit_ancestry"] == "unknown"
    assert unmeasured["commit_distance_checked_at"] == "2026-08-08T12:17:08.000000Z"
  end

  # ── task-0dd7578bc3d2bcbd: arm BEFORE resume, enforced ─────────────────────
  #
  # `autoupdate_paused` has no automatic clear — its only `false` writer is this
  # route. Resuming an unarmed box therefore looks like a remedy and is not one:
  # the rollout's next advance draws a 503 off the box's own `Runner.enabled?/0`
  # and (since #13474) skips it, so the box reads UNPAUSED and still never
  # updates. These pin the ordering, and the recovery it makes possible.
  describe "arm-before-resume ordering" do
    test "resuming a MEASURED-unarmed box is refused with the remedy named" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      bp = live_behind(team, %{autoupdate_paused: true, apply_arming: "unarmed"})

      # The guard re-measures; the box still says one-click apply is off.
      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 200, body: self_update_body("behind", false)}}
      ])

      conn = patch_autoupdate(bp.id, token, %{"autoupdate_paused" => false})

      assert conn.status == 409
      body = json_body(conn)
      assert body["error"] == "instance_not_armed"
      assert body["details"]["field"] == "autoupdate_paused"
      assert body["details"]["apply_arming"] == "unarmed"
      assert body["details"]["remedy"] =~ "BARKPARK_SELF_UPDATE_APPLY=1"

      assert Registry.get_barkpark(bp.id).autoupdate_paused,
             "the refusal must not half-apply — the box stays paused"
    end

    test "a STRING \"false\" is caught by the same cast, not waved through" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)
      bp = live_behind(team, %{autoupdate_paused: true, apply_arming: "unarmed"})

      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 200, body: self_update_body("behind", false)}}
      ])

      conn = patch_autoupdate(bp.id, token, %{"autoupdate_paused" => "false"})

      assert conn.status == 409,
             "reading the CHANGESET rather than the raw body is what closes this bypass"
    end

    test "ONLY the transition: an already-unpaused unarmed box may still be edited" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)
      bp = live_behind(team, %{autoupdate_paused: false, apply_arming: "unarmed"})

      # ARMED SO THE MUTANT CANNOT HIDE. Program the probe to say "unarmed", so
      # that a guard keyed on the steady state (`get_field`) instead of the
      # transition (`get_change`) would actually reach a refusal here. Without
      # this the probe is unprogrammed, errors, fails open, and the test would
      # pass on a broken guard — a false certificate.
      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 200, body: self_update_body("behind", false)}}
      ])

      conn = patch_autoupdate(bp.id, token, %{"pinned_release" => "v0.2.24"})

      assert conn.status == 200,
             "the guard fires on paused true->false, never on the steady state — " <>
               "an unrelated policy edit must not be collateral"

      assert Registry.get_barkpark(bp.id).pinned_release == "v0.2.24"
    end

    test "the guard RE-MEASURES: arm the box and resume works immediately" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      # Stored arming is STALE — the sweep last saw it unarmed up to an hour ago.
      bp = live_behind(team, %{autoupdate_paused: true, apply_arming: "unarmed"})

      # The operator has since armed and restarted it; the box now says so.
      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 200, body: self_update_body("behind", true)}}
      ])

      conn = patch_autoupdate(bp.id, token, %{"autoupdate_paused" => false})

      assert conn.status == 200,
             "refusing on the stored value would block an operator who armed the box " <>
               "thirty seconds ago until the next :17 sweep — this guard must not " <>
               "become the latch it exists to remove"

      fresh = Registry.get_barkpark(bp.id)
      refute fresh.autoupdate_paused
      assert fresh.apply_arming == "armed"
    end

    test "FAILS OPEN on an unprovable negative: an unreachable box may still be resumed" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)
      bp = live_behind(team, %{autoupdate_paused: true, apply_arming: "unarmed"})

      StudioLinkFakeHttpClient.program([{:error, :nxdomain}])

      conn = patch_autoupdate(bp.id, token, %{"autoupdate_paused" => false})

      assert conn.status == 200,
             "refusing on a measurement we could not take would strand the operator " <>
               "with no way forward — a NEW unclearable state, which is the defect " <>
               "this row exists to remove"

      refute Registry.get_barkpark(bp.id).autoupdate_paused
    end
  end

  # ── THE RECOVERY PROOF ─────────────────────────────────────────────────────
  #
  # The defining property of this bug is a state the worker enters automatically
  # and that no code path clears. A test that only proves the pause HAPPENS
  # re-certifies the bug. So this drives a box into `autoupdate_paused` through
  # the worker's own remaining machine-writer — the settle-grace containment in
  # `settle_one/1`, which #13474 deliberately did NOT change — and then walks the
  # intended recovery all the way back to eligibility.
  describe "the latch can be left" do
    test "paused by the worker -> armed -> resumed -> eligible again" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      stale = DateTime.add(DateTime.utc_now(), -30 * 60, :second)
      bp = live_behind(team, %{autoupdate_triggered_at: stale})

      # (1) THE MACHINE LATCHES IT. The wave never settled inside the grace, so
      # the worker clears the marker and pauses the box for investigation.
      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 200, body: self_update_body("behind", false)}}
      ])

      AutoupdateRolloutWorker.perform(%Oban.Job{})

      latched = Registry.get_barkpark(bp.id)
      assert latched.autoupdate_paused, "the worker latched it, with no human in the loop"
      refute latched.autoupdate_triggered_at

      # (2) IT IS OUT OF THE ROLLOUT, and nothing in the plane will bring it back.
      refute Registry.next_autoupdate_candidate(),
             "a paused box is not a candidate — this is the stuck state"

      # (3) THE ORDERING IS ENFORCED. Resuming before arming is refused, so the
      # operator cannot convert a visible stuck state into a silent one.
      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 200, body: self_update_body("behind", false)}}
      ])

      assert patch_autoupdate(bp.id, token, %{"autoupdate_paused" => false}).status == 409
      assert Registry.get_barkpark(bp.id).autoupdate_paused, "still latched"

      # (4) THE OPERATOR ARMS THE BOX (BARKPARK_SELF_UPDATE_APPLY=1 + restart).
      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 200, body: self_update_body("behind", true)}}
      ])

      # (5) AND THE RESUME NOW LANDS.
      assert patch_autoupdate(bp.id, token, %{"autoupdate_paused" => false}).status == 200

      recovered = Registry.get_barkpark(bp.id)
      refute recovered.autoupdate_paused, "THE LATCH IS CLEARED"
      assert recovered.apply_arming == "armed"

      # (6) AND THE BOX IS BACK IN THE ROLLOUT — the property that makes this a
      # recovery rather than a flag flip.
      assert %{id: id} = Registry.next_autoupdate_candidate()
      assert id == bp.id, "eligible again, end to end"
    end

    # task-a207d875e61a2e02, criterion 3. The case above latches a box that is BOTH
    # settle-failed AND unarmed, so its 409 is correct. This is the other half: a
    # box latched purely by the settle timer, on a box that is demonstrably ARMED.
    # The two machine-observed conditions must not collapse into one row shape, or
    # the sole exit from a machine-set latch gets gated on an irrelevant remedy.
    test "a settle-latched box that IS armed resumes without the arming refusal" do
      {user, team} = user_with_team()
      {:ok, token} = Accounts.create_user_session_token(user)

      stale = DateTime.add(DateTime.utc_now(), -30 * 60, :second)
      bp = live_behind(team, %{autoupdate_triggered_at: stale})

      # ARMED (apply_enabled: true) and still `behind` after the grace — a MEASURED
      # failure to land, so the worker contains it.
      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 200, body: self_update_body("behind", true)}}
      ])

      AutoupdateRolloutWorker.perform(%Oban.Job{})

      latched = Registry.get_barkpark(bp.id)
      assert latched.autoupdate_paused, "measured failure to settle → contained"
      assert latched.apply_arming == "armed", "and recorded as armed, not unarmed"

      # The resume probe re-measures and reads `armed`, so refuse_unarmed_resume/2
      # ALLOWS: the operator is not told to arm a box that is already armed.
      StudioLinkFakeHttpClient.program([
        {:ok, %{status: 200, body: self_update_body("behind", true)}}
      ])

      assert patch_autoupdate(bp.id, token, %{"autoupdate_paused" => false}).status == 200,
             "a settle-latch is not an arming problem and must not be refused as one"

      refute Registry.get_barkpark(bp.id).autoupdate_paused
    end
  end
end
