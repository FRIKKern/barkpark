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
  alias BarkparkCloud.Web.Router

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
end
