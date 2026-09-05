defmodule Barkpark.Plugins.Github.Web.OpsLiveTest do
  @moduledoc """
  The read-only `:ops` sync-health console at `/admin/github`: it paints
  `Github.Health.snapshot/1` (per-dataset cursor/lag/pending panel + mirror
  queue depth + open conflicts grouped by kind) and exposes exactly ONE control
  — a per-row Resolve button wired to the already-built `Conflicts.resolve/1`.
  Everything else is read-only. Gated `:ops` (admin), never public/anonymous.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.QueryCounter

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Plugins.Github.Conflicts
  alias Barkpark.Plugins.Github.Web.OpsLive

  @admin_token "github-ops-admin-test-token"

  # Ecto's per-query telemetry event; `metadata.source` is the queried table.
  # The `oban_jobs` table is read exactly ONCE per `Health.snapshot/0` (its
  # `queue_snapshot` reads the `github_mirror` queue depth) and nothing else on
  # this admin-gated mount touches it — Oban runs `testing: :manual` in the test
  # env, so there is no background staging poll. That makes an `oban_jobs` read
  # the unique, once-per-snapshot signature of a Health probe: counting it proves
  # the disconnected mount runs 0 snapshots and the connected mount runs exactly 1.

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "github ops admin", "production", [
        "read",
        "write",
        "admin"
      ])

    conn = build_conn() |> init_test_session(%{"api_token" => @admin_token})
    {:ok, conn: conn}
  end

  defp seed_conflict(kind, issue, opts \\ []) do
    {:ok, c} =
      Conflicts.record(%{
        repo: Keyword.get(opts, :repo, "FRIKKern/barkpark"),
        issue: issue,
        doc_id: Keyword.get(opts, :doc_id, "gh-#{issue}"),
        dataset: "production",
        kind: kind,
        detail: %{}
      })

    c
  end

  describe "mount + render" do
    test "paints the header, the per-dataset panel and the mirror queue panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/github")

      assert html =~ "GitHub Sync"
      # per-dataset panel — default dataset is "production"
      assert html =~ ~s(data-role="github-dataset")
      assert html =~ "production"
      assert html =~ "cursor"
      assert html =~ "lag"
      # mirror queue panel
      assert html =~ ~s(data-role="github-queue")
      assert html =~ "github_mirror"
    end

    test "shows the 'plugin not provisioned' banner when the bridge is dark", %{conn: conn} do
      # no GitHub creds are configured in the test env → active: false
      {:ok, _view, html} = live(conn, "/admin/github")

      assert html =~ ~s(data-role="github-health-inactive")
      assert html =~ "not provisioned"
    end

    test "renders the empty-state when there are zero open conflicts", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/github")

      assert html =~ ~s(data-role="github-health-empty")
      refute html =~ ~s(data-role="github-resolve")
    end

    test "groups open conflicts by kind with counts + a Resolve button per row", %{conn: conn} do
      edit = seed_conflict("out_of_band_edit", 101)
      det = seed_conflict("detached", 102)

      {:ok, _view, html} = live(conn, "/admin/github")

      refute html =~ ~s(data-role="github-health-empty")

      # both kinds render as groups
      assert html =~ ~s(data-kind="out_of_band_edit")
      assert html =~ ~s(data-kind="detached")

      # the counts panel reflects one of each
      assert html =~ ~s(data-role="github-conflict-counts")

      # each open row carries the issue ref + a Resolve button keyed by id
      assert html =~ "FRIKKern/barkpark#101"
      assert html =~ "FRIKKern/barkpark#102"
      assert html =~ ~s(data-role="github-resolve")
      assert html =~ ~s(phx-value-id="#{edit.id}")
      assert html =~ ~s(phx-value-id="#{det.id}")
    end
  end

  describe "resolve control" do
    test "clicking Resolve clears that conflict and it drops out of the console", %{conn: conn} do
      keep = seed_conflict("out_of_band_edit", 201)
      drop = seed_conflict("detached", 202)

      {:ok, view, _html} = live(conn, "/admin/github")

      html =
        view
        |> element(~s(tr[data-conflict-id="#{drop.id}"] button[data-role="github-resolve"]))
        |> render_click()

      # the resolved row is gone; the other survives
      refute html =~ ~s(data-conflict-id="#{drop.id}")
      assert html =~ ~s(data-conflict-id="#{keep.id}")

      # and it's actually resolved in the side table
      assert Enum.map(Conflicts.list(), & &1.id) == [keep.id]
    end

    test "resolving the last conflict reveals the empty-state", %{conn: conn} do
      only = seed_conflict("dedup_refused", 301)

      {:ok, view, _html} = live(conn, "/admin/github")

      html =
        view
        |> element(~s(tr[data-conflict-id="#{only.id}"] button[data-role="github-resolve"]))
        |> render_click()

      assert html =~ ~s(data-role="github-health-empty")
      assert Conflicts.list() == []
    end
  end

  describe "gating" do
    test "an anonymous (no-token) request never reaches the console" do
      # No :ops on_mount admin gate satisfied → the LiveView must not mount for
      # an anonymous conn (redirect away, never a 200 render).
      assert {:error, {:redirect, _}} = live(build_conn(), "/admin/github")
    end
  end

  # The DB-outage honesty path CANNOT be exercised via a full mount: the
  # in-process test Repo is always up, so `db_ok` is always true under `live/2`.
  # The precedence lives in the pure `health_banner/1` helper, unit-tested here
  # over synthetic snapshot maps.
  describe "health_banner/1 (pure)" do
    test ":db_down when the DB is unreachable — regardless of active" do
      # A DB outage drags BOTH db_ok AND active to false through the same safe/2
      # wrapper; the banner must NOT read that as "not provisioned".
      assert OpsLive.health_banner(%{active: false, db_ok: false}) == :db_down
      # even a snapshot that still reports active must surface :db_down when blind.
      assert OpsLive.health_banner(%{active: true, db_ok: false}) == :db_down
    end

    test ":inactive only when the DB is reachable AND the plugin is un-provisioned" do
      assert OpsLive.health_banner(%{active: false, db_ok: true}) == :inactive
    end

    test ":ok when the DB is reachable and the plugin is provisioned" do
      assert OpsLive.health_banner(%{active: true, db_ok: true}) == :ok
    end
  end

  describe "db_status_label/1 (pure)" do
    test "distinguishes reachable from unreachable" do
      assert OpsLive.db_status_label(%{db_ok: true}) == "reachable"
      assert OpsLive.db_status_label(%{db_ok: false}) == "unreachable"
    end
  end

  # The #2402 connected?-mount-gate scar: `mount/3` ran `Health.snapshot/0`
  # (5+ DB round-trips) UNCONDITIONALLY, so the DISCARDED disconnected render
  # fired every probe and then the connected mount re-fired them — 2× per open.
  # It is now gated behind `connected?/1`. These two tests count the `oban_jobs`
  # read — the unique once-per-`Health.snapshot` signature — to prove 2× → 1×.
  describe "disconnected mount elides the Health.snapshot probes" do
    test "the disconnected (dead) render runs ZERO health probes and paints a loading skeleton",
         %{conn: conn} do
      {conn, health_reads} = count_health_queries(fn -> get(conn, "/admin/github") end)

      body = html_response(conn, 200)
      # The dead render shows the loading skeleton, NOT the projected health board.
      assert body =~ ~s(data-role="github-ops-loading")
      assert body =~ "Loading sync health"
      refute body =~ ~s(data-role="github-queue")

      # Health.snapshot's queue_snapshot never ran on the discarded mount.
      assert health_reads == 0,
             "the disconnected mount must issue zero Health.snapshot (oban_jobs) queries, " <>
               "got #{health_reads}"
    end

    test "the connected mount runs Health.snapshot exactly once (2x -> 1x)", %{conn: conn} do
      # `live/2` does the disconnected render THEN connects. The disconnected leg
      # now contributes 0 health probes (the fix), so the ONE oban_jobs read across
      # the whole flow proves the snapshot runs a single time — on connect.
      {{:ok, _view, html}, health_reads} =
        count_health_queries(fn -> live(conn, "/admin/github") end)

      # Behavior parity: the connected view paints the real health panels.
      assert html =~ ~s(data-role="github-queue")
      assert html =~ "github_mirror"

      assert health_reads == 1,
             "Health.snapshot must run exactly once (on connect), got #{health_reads} oban_jobs queries"
    end
  end

  describe "db-reachability indicator + lag/pending caption" do
    test "renders the db-status indicator (reachable under the live test Repo)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/github")

      # distinct from the provisioning banner — always shown, not conditional
      assert html =~ ~s(data-role="github-db-status")
      assert html =~ ~s(data-db-ok="true")
      assert html =~ "reachable"
      # a healthy test Repo is never blind
      refute html =~ ~s(data-role="github-health-db-down")
    end

    test "captions lag vs pending so a high-lag/zero-pending reading is not misread", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, "/admin/github")

      assert html =~ ~s(data-role="github-lag-caption")
      assert html =~ "mutation_events"
      assert html =~ "task subset"
    end
  end

  # Count Repo queries against `oban_jobs` within `fun` — the unique signature of
  # `Health.snapshot/0`'s `queue_snapshot`.
  #
  # LINEAGE-SCOPED, via the shared `Barkpark.QueryCounter`. The connected mount
  # runs in a spawned LiveView process, so a `self()` filter would drop the very
  # leg being measured — but an unscoped handler is NODE-global and counts the
  # application's own background processes too, which `async: false` does not
  # fence (it fences sibling TEST processes, not the supervision tree). The
  # counter therefore reports from any process and decides ownership afterwards:
  # this test process, the LiveView pid named below, and their
  # `$callers`/`$ancestors` lineage. See `Barkpark.QueryCounterTest`.
  defp count_health_queries(fun) do
    QueryCounter.count_source(
      fn ->
        result = fun.()

        case result do
          {:ok, %Phoenix.LiveViewTest.View{pid: pid}, _html} -> QueryCounter.own(pid)
          _ -> :ok
        end

        result
      end,
      "oban_jobs"
    )
  end
end
