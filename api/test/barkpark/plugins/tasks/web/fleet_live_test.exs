defmodule Barkpark.Plugins.Tasks.Web.FleetLiveTest do
  @moduledoc """
  The Studio Fleet desk tile at `/admin/fleet` — a thin, read-only roster of the
  Personal Dev Fleet's listeners (`worker · status · last-seen`), read through
  `Barkpark.Tasks.Fleet.roster/2` with `global: true` — the ONE explicit
  cross-tenant opt-in, and this tile is its only caller. The 2026-09-01 ruling
  on task-4e2986e8609670d7 scoped the flat `GET /v1/fleet/roster` endpoint to
  `scope_opts(conn)`, so the endpoint no longer shares this shape; the tile
  keeps it because it has no request scope to thread and would otherwise render
  permanently empty (PDF-D19 — NEVER a socket-scoped read that would
  fail-closed empty).

  Covers:

    * mount + render: empty state, and a seeded roster painting worker / status
      pill / last-seen for every row (criterion 0);
    * the status pills cover the COMPLETE PDF-D23 vocabulary —
      `idle · working · blocked · offline · provisioning` (criterion 2);
    * the desk link + top-menu tab are Tasks-plugin contributions that VANISH
      when the plugin is disabled for a workspace (criterion 1 — the
      fresh-install / plugin-gating invariant);
    * `:ops` gating — an anonymous request never reaches the tile;
    * the pure `pill/1` and `relative_age/2` helpers.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures, only: [create_workspace!: 0]

  alias Barkpark.{Auth, Content, Tasks, Tenancy, TenancyFixtures}
  alias Barkpark.Plugins.Registry
  # The desk_items/0-1 and top_menu_entries/0 desk contributions live on the
  # PLUGIN module (Barkpark.Plugins.Tasks), distinct from the Barkpark.Tasks
  # substrate (which owns schema_definitions/1).
  alias Barkpark.Plugins.Tasks, as: TasksPlugin
  alias Barkpark.Plugins.Tasks.Web.FleetLive

  @admin_token "fleet-tile-admin-test-token"
  @dataset "production"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "fleet tile admin", @dataset, ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    # Register the task + listener schemas so `create_document("listener", …)`
    # lands in the right dataset (the fleet_test.exs setup idiom).
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    conn = build_conn() |> init_test_session(%{"api_token" => @admin_token})
    {:ok, conn: conn, scope: scope}
  end

  # Direct listener fixture — bypasses the beat so each row pins its own
  # last_seen/status exactly (the fleet_test.exs `mk_listener!` idiom). This is
  # how a `provisioning` row (cloud-written, never beat-declared) and a stale
  # `offline` row are seeded.
  defp mk_listener!(worker, content_extra, scope) do
    content =
      Map.merge(
        %{"worker" => worker, "status" => "idle", "ttl_s" => 120, "last_seen" => now_iso()},
        content_extra
      )

    {:ok, doc} =
      Content.create_document(
        "listener",
        %{"doc_id" => "listener-" <> worker, "title" => worker, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp iso_ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()

  describe "mount + render" do
    test "paints the header and the empty-state when there are no listeners", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/fleet")

      assert html =~ "Fleet"
      assert html =~ ~s(data-role="fleet-empty")
      assert html =~ "No listeners yet"
      refute html =~ ~s(data-role="fleet-roster")
    end

    test "renders a roster row with worker, a status pill and a last-seen age (criterion 0)",
         %{conn: conn, scope: scope} do
      mk_listener!("mac-mini", %{"status" => "working", "last_seen" => iso_ago(10)}, scope)

      {:ok, _view, html} = live(conn, "/admin/fleet")

      # the flat global-per-dataset read surfaced the row (never an empty
      # socket-scoped read — PDF-D19)
      assert html =~ ~s(data-role="fleet-roster")
      assert html =~ ~s(data-role="fleet-row")
      assert html =~ ~s(data-worker="mac-mini")
      assert html =~ "mac-mini"
      # status column: a pill
      assert html =~ ~s(data-role="fleet-pill")
      assert html =~ ~s(data-status="working")
      assert html =~ "working"
      # last-seen column present and populated (not the em-dash null)
      assert html =~ ~s(data-role="fleet-last-seen")
    end

    test "the status pills cover the full PDF-D23 vocabulary incl. provisioning (criterion 2)",
         %{conn: conn, scope: scope} do
      # one row per live/derived state — fresh rows keep their stored status;
      # the stale row derives offline (300s old vs a 120s budget).
      mk_listener!("w-idle", %{"status" => "idle", "last_seen" => iso_ago(5)}, scope)
      mk_listener!("w-working", %{"status" => "working", "last_seen" => iso_ago(5)}, scope)
      mk_listener!("w-blocked", %{"status" => "blocked", "last_seen" => iso_ago(5)}, scope)
      # provisioning is cloud-written (Wave C, live now), never beat-declared —
      # it renders verbatim while fresh and is NEVER shown as online.
      mk_listener!("w-prov", %{"status" => "provisioning", "last_seen" => iso_ago(5)}, scope)
      # a stale row → the roster derives "offline" at read time.
      mk_listener!("w-off", %{"status" => "working", "last_seen" => iso_ago(300)}, scope)

      {:ok, _view, html} = live(conn, "/admin/fleet")

      for status <- ~w(idle working blocked provisioning offline) do
        assert html =~ ~s(data-status="#{status}"),
               "expected a status pill for #{status} in the roster render"
      end

      # the offline verdict is the server's derivation, painted on the fresh-but-
      # stale row — the tile never re-computes staleness itself.
      assert html =~ ~s(data-worker="w-off")
      assert html =~ ~s(data-status="offline")
    end
  end

  describe "plugin-gating (criterion 1)" do
    test "the Fleet desk link + top-menu tab are present with the Tasks plugin on", %{conn: _conn} do
      desk_labels = Enum.map(TasksPlugin.desk_items(@dataset), &Map.get(&1, :label))
      menu_labels = Enum.map(TasksPlugin.top_menu_entries(), &Map.get(&1, :label))

      assert "Fleet" in desk_labels
      assert "Fleet" in menu_labels

      fleet_desk = Enum.find(TasksPlugin.desk_items(@dataset), &(&1[:label] == "Fleet"))
      assert fleet_desk[:path] == "/admin/fleet"
    end

    test "the Fleet desk link + top-menu tab VANISH when the Tasks plugin is disabled" do
      ws = create_workspace!()
      ctx = %{dataset: @dataset, workspace_id: ws.id}

      # ON (tasks enabled by default) — the highway surfaces Fleet under the ws.
      on_desk =
        Enum.map(Registry.collect_desk_items(baseline: [], ctx: ctx), &Map.get(&1, :label))

      on_menu =
        Enum.map(Registry.collect_top_menu_entries(baseline: [], ctx: ctx), &Map.get(&1, :label))

      assert "Fleet" in on_desk
      assert "Fleet" in on_menu

      # OFF — disable the tasks plugin for this workspace.
      {:ok, _} = Tenancy.set_workspace_plugin_settings(ws.id, %{"tasks" => %{"enabled" => false}})

      off_desk =
        Enum.map(Registry.collect_desk_items(baseline: [], ctx: ctx), &Map.get(&1, :label))

      off_menu =
        Enum.map(Registry.collect_top_menu_entries(baseline: [], ctx: ctx), &Map.get(&1, :label))

      refute "Fleet" in off_desk,
             "the Fleet desk link must disappear when the Tasks plugin is off"

      refute "Fleet" in off_menu,
             "the Fleet top-menu tab must disappear when the Tasks plugin is off"
    end
  end

  describe "gating" do
    test "an anonymous (no-token) request never reaches the tile" do
      assert {:error, {:redirect, _}} = live(build_conn(), "/admin/fleet")
    end
  end

  describe "pill/1 (pure)" do
    test "covers the full PDF-D23 vocabulary" do
      assert {"idle", _} = FleetLive.pill("idle")
      assert {"working", _} = FleetLive.pill("working")
      assert {"blocked", _} = FleetLive.pill("blocked")
      assert {"offline", _} = FleetLive.pill("offline")
      assert {"provisioning", _} = FleetLive.pill("provisioning")
    end

    test "an unknown or nil status falls back to the neutral idle styling (never crashes)" do
      assert FleetLive.pill("wat") == FleetLive.pill("idle")
      assert FleetLive.pill(nil) == FleetLive.pill("idle")
    end
  end

  describe "relative_age/2 (pure)" do
    setup do
      %{now: ~U[2026-07-23 12:00:00Z]}
    end

    test "humanizes recent → distant ages", %{now: now} do
      assert FleetLive.relative_age(DateTime.to_iso8601(DateTime.add(now, -2, :second)), now) ==
               "just now"

      assert FleetLive.relative_age(DateTime.to_iso8601(DateTime.add(now, -30, :second)), now) ==
               "30s"

      assert FleetLive.relative_age(DateTime.to_iso8601(DateTime.add(now, -300, :second)), now) ==
               "5m"

      assert FleetLive.relative_age(DateTime.to_iso8601(DateTime.add(now, -7200, :second)), now) ==
               "2h"

      assert FleetLive.relative_age(
               DateTime.to_iso8601(DateTime.add(now, -172_800, :second)),
               now
             ) == "2d"
    end

    test "a missing or unparsable last_seen reads em-dash, never a crash", %{now: now} do
      assert FleetLive.relative_age(nil, now) == "—"
      assert FleetLive.relative_age("not-a-timestamp", now) == "—"
    end

    test "a future last_seen clamps to just now (never a negative age)", %{now: now} do
      assert FleetLive.relative_age(DateTime.to_iso8601(DateTime.add(now, 60, :second)), now) ==
               "just now"
    end
  end
end
