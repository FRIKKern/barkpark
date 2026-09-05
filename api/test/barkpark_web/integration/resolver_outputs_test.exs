defmodule BarkparkWeb.Integration.ResolverOutputsTest do
  @moduledoc """
  Integration probe for the plugin resolver chain (Goal `barkpark-b1m`,
  Task `barkpark-yhp`). Pins the contract that when a plugin declares
  `top_menu_entries`, `desk_items`, or `register_schemas`, those
  contributions surface end-to-end in the host's rendered output.

  Four describe blocks:

    * `/api/schemas` (legacy, public) — exposes plugin-registered schemas
      via `LegacyController.schemas/2`.
    * `/v1/schemas/<dataset>` (admin) — exposes the same through
      `SchemaController.index/2`; 401 without a token.
    * Scoped Studio (LiveView, `/w/<ws>/p/<proj>/d/<dataset>/studio`) —
      renders the Bokbasen top-menu tab and the Pending submissions desk
      link inside the Studio chrome. (Flat `/studio/<dataset>` 302s to
      the scoped form since the P3 cutover.)
    * `Registry.collect_*` direct — unit-level verification that the
      collectors return the plugin's contributions before any rendering.

  `async: false` because tests share the singleton
  `Barkpark.Plugins.Registry` GenServer and the `:plugins` Application
  env. We register `Barkpark.Plugins.OnixEdit` explicitly in setup so
  the test is deterministic — the boot-time discovery Task in
  `Barkpark.Application.start/2` runs asynchronously and may not have
  completed when a test starts.

  When OnixEdit can't be loaded in the test env (e.g. manifest path
  missing), the relevant assertions log a clear skip message rather
  than fake-pass.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures, only: [create_workspace!: 0]

  alias Barkpark.Auth
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Plugins.OnixEdit
  alias Barkpark.Plugins.Registry
  alias Barkpark.Tenancy

  @plugin_name "onixedit"
  @admin_token "barkpark-dev-token"

  setup do
    Auth.create_token(
      @admin_token,
      "dev",
      "resolver-outputs-integration",
      ["read", "write", "admin"]
    )

    # The Application boot kicks off a `Task.Supervisor.start_child` that
    # walks plugins + runs codelist seeders. Those seeders hammer the DB
    # for a couple of seconds. If a test's LiveView mount lands while the
    # boot Task is still running, the sandbox connection it owns gets
    # ripped out from under the seeder mid-query — flake. Drain the
    # supervisor here before each test so the boot work is fully done.
    drain_task_supervisor()

    # Force-register OnixEdit so the resolver chain has it available
    # regardless of whether the boot discovery Task ran. `Registry.register/2`
    # is idempotent on `plugin_name`.
    onixedit_loaded? = ensure_onixedit_registered()

    # Persist plugin-declared schemas so /api/schemas and /v1/schemas/...
    # see the `book` row. Bootstrap is idempotent on (name, dataset).
    if onixedit_loaded? do
      _ = Bootstrap.register_all_schemas()
    end

    %{onixedit_loaded?: onixedit_loaded?}
  end

  # Wait until the boot Task.Supervisor has no live children, or 5 s
  # elapse — whichever comes first. Polls cheap so the happy path
  # (already drained) returns within one millisecond.
  defp drain_task_supervisor(deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_drain(deadline)
  end

  defp do_drain(deadline) do
    case Task.Supervisor.children(Barkpark.TaskSupervisor) do
      [] ->
        :ok

      _children ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(50)
          do_drain(deadline)
        end
    end
  end

  defp ensure_onixedit_registered do
    if Code.ensure_loaded?(OnixEdit) do
      :ok =
        Registry.register(OnixEdit, %{
          "plugin_name" => @plugin_name,
          "module" => "Barkpark.Plugins.OnixEdit"
        })

      true
    else
      false
    end
  end

  defp skip_unless_loaded(ctx) do
    unless ctx.onixedit_loaded? do
      IO.puts(:stderr, "[resolver_outputs_test] SKIP: OnixEdit not loaded in test env")
    end

    ctx.onixedit_loaded?
  end

  # Walk a (possibly nested) list of plugin items and collect every
  # `:label` / `"label"` string. Registry.collect_desk_items returns a
  # flat list per the current implementation, but `:nested` items carry
  # an inner `items: [...]` list — handle both shapes defensively.
  defp collect_labels(items) when is_list(items) do
    Enum.flat_map(items, &collect_labels/1)
  end

  defp collect_labels(%{} = item) do
    label = item[:label] || item["label"]
    nested = item[:items] || item["items"]

    [label | collect_labels(nested || [])]
  end

  defp collect_labels(_), do: []

  # ── Block 1 — /api/schemas (legacy, public) ──────────────────────────────

  describe "GET /api/schemas — legacy public schema list" do
    test "withholds the private OnixEdit-contributed book schema", %{conn: conn} = ctx do
      if skip_unless_loaded(ctx) do
        conn = get(conn, ~p"/api/schemas")
        assert conn.status == 200

        schemas = json_response(conn, 200)
        assert is_list(schemas)

        names = Enum.map(schemas, & &1["name"])

        # AMENDED (api-read-path-security-sweep w2): this case used to assert
        # `"book" in names` — plugin CONTRIBUTION was the invariant, and the
        # route proved it by serving every schema, private ones included, to an
        # anonymous caller with full `fields`. `priv/plugins/onixedit/schemas/
        # book.json:5` declares `"visibility": "private"`, so the public-schema
        # filter in `LegacyController.schemas/2` correctly withholds it now.
        # The plugin-contribution invariant itself is still enforced — on the
        # ADMIN index (`GET /v1/schemas/production`, Block 2 below), which is
        # where a private schema legitimately appears.
        refute "book" in names,
               "private plugin schema `book` must not reach the anonymous /api/schemas index, got: #{inspect(names)}"

        # Not vacuous: the route still serves a non-empty public list.
        refute names == []
      end
    end
  end

  # ── Block 2 — /v1/schemas/<dataset> (admin) ──────────────────────────────

  describe "GET /v1/schemas/production — admin schema index" do
    test "with valid admin token includes the book schema", %{conn: conn} = ctx do
      if skip_unless_loaded(ctx) do
        conn =
          conn
          |> put_req_header("authorization", "Bearer #{@admin_token}")
          |> get(~p"/v1/schemas/production")

        assert conn.status == 200

        body = json_response(conn, 200)
        # SchemaController.index/2 wraps schemas in an envelope:
        # `%{schemas: [...], datasetSchemaHash: "...", _schemaVersion: 1}`.
        schemas = body["schemas"]
        assert is_list(schemas), "expected envelope with :schemas list, got: #{inspect(body)}"

        names = Enum.map(schemas, & &1["name"])

        assert "book" in names,
               "expected plugin-contributed `book` schema in /v1/schemas/production, got: #{inspect(names)}"
      end
    end

    test "without a token returns 401", %{conn: conn} do
      conn = get(conn, ~p"/v1/schemas/production")
      assert conn.status == 401
    end
  end

  # ── Block 3 — /studio/<dataset> HTML renders plugin contributions ────────

  describe "GET scoped /studio/production — Studio LiveView renders plugin contributions" do
    setup do
      # Studio chrome (studio_tabs, desk pane) is rendered by a LiveView
      # via the scoped live_session — the only Studio mount since the P3
      # cutover (flat /studio/:dataset 302s there). `scoped_studio/1`
      # seeds the Default tenancy and prefixes /w/default/p/default.
      # `Phoenix.LiveViewTest.live/2` drives the full mount and returns
      # the rendered HTML so we can pin both the dead-render and the
      # post-mount markers in one assertion.
      :ok
    end

    test "the Bokbasen top-menu tab follows workspace enablement (off by default)",
         %{conn: conn} = ctx do
      if skip_unless_loaded(ctx) do
        # ssp-w1: onixedit declares default_enabled? false — its contributions
        # only surface for a workspace that enables it. Both directions pinned.
        {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

        refute html =~ "Bokbasen",
               "onixedit is off-by-default — the Bokbasen tab must not surface unrequested"

        {ws, _project} = Barkpark.TenancyFixtures.ensure_default_scope!()

        {:ok, _} =
          Barkpark.Tenancy.set_workspace_plugin_settings(ws.id, %{
            "onixedit" => %{"enabled" => true}
          })

        {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

        assert html =~ "Bokbasen",
               "expected the Bokbasen top-menu tab once the workspace enables onixedit"
      end
    end

    test "the Plugins tier is absent from the desk while nothing is enabled" do
      # ssp-w1 tiering: no :plugins-placement plugin is enabled by default, so
      # the initial desk HTML must not render an empty Plugins tier node. The
      # ENABLED direction (node present, plugin group nested inside) is pinned
      # at the tree level in structure_test.exs ("enabling a :plugins-placement
      # plugin surfaces a Plugins node holding its group"); the enablement→
      # Studio-HTML path is pinned end-to-end by the Bokbasen top-menu test
      # above.
      {:ok, _view, html} = live(scoped_conn(), scoped_studio("/d/production/studio"))

      refute html =~ ~s(pane-item-label">Plugins</span>),
             "no :plugins-placement plugin is enabled by default — the tier node must not render empty"
    end

    test "HTML contains the nav-plugin-entry marker", %{conn: conn} = ctx do
      if skip_unless_loaded(ctx) do
        {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

        assert html =~ "nav-plugin-entry",
               "expected nav-plugin-entry marker (rendered when a :plugin_link desk item is present)"
      end
    end

    test "a plugin-link row wears the same label + hover-reveal chevron vocabulary as sibling nav rows",
         %{conn: conn} = ctx do
      # sup-w4 row-state ladder: the plugin nav row (<a class="pane-item
      # nav-plugin-entry">) must speak the SAME structure-pane vocabulary as
      # phx-click sibling rows — a .pane-item-label AND the .pane-item-chevron
      # drill affordance (hover-revealed via CSS; the span is always in the DOM).
      # Before this wave the plugin link had no chevron, so Projects/Pending
      # looked like a dead-end while its siblings advertised drill-through.
      if skip_unless_loaded(ctx) do
        {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

        [row] = Regex.run(~r{<a[^>]*nav-plugin-entry.*?</a>}s, html) || [nil]
        assert row, "expected a nav-plugin-entry <a> row in the rendered desk"

        assert row =~ ~s(class="pane-item nav-plugin-entry"),
               "plugin link keeps the frozen class pair"

        assert row =~ ~s(class="pane-item-label"), "plugin link carries the shared label span"

        assert row =~ ~s(class="pane-item-chevron"),
               "plugin link now carries the shared drill chevron"
      end
    end

    test "HTML contains the top-menu-tab marker", %{conn: conn} = ctx do
      if skip_unless_loaded(ctx) do
        {:ok, _view, html} = live(conn, scoped_studio("/d/production/studio"))

        assert html =~ "top-menu-tab",
               "expected top-menu-tab marker on the rendered studio_tabs component"
      end
    end
  end

  # ── Block 4 — Registry.collect_* returns plugin contributions ────────────
  #
  # OnixEdit is off by default. The directly-rendered TOP-MENU collector gates
  # an off-by-default plugin on a workspace-less ctx (snav-w1-gating-determinism),
  # so to prove OnixEdit's TAB still reaches the collector end-to-end we thread a
  # workspace_id whose effective enablement turns OnixEdit on — the same axis the
  # render path uses (nav.ex passes `workspace_id` into the collector ctx). The
  # DESK collectors stay unfiltered on a nil workspace (Barkpark.Structure tiers
  # them itself), so those assertions keep the workspace-less ctx.

  # Fresh workspace with OnixEdit explicitly enabled; returns the collector ctx
  # (dataset + workspace_id, plus any extras) that surfaces OnixEdit's tab.
  defp onixedit_enabled_ctx(extra) do
    ws = create_workspace!()

    {:ok, _} =
      Tenancy.set_workspace_plugin_settings(ws.id, %{@plugin_name => %{"enabled" => true}})

    Map.merge(%{dataset: "production", workspace_id: ws.id}, extra)
  end

  describe "Registry.collect_* — direct resolver-chain verification" do
    test "collect_top_menu_entries includes the Bokbasen entry when OnixEdit is enabled", ctx do
      if skip_unless_loaded(ctx) do
        entries =
          Registry.collect_top_menu_entries(
            baseline: [],
            ctx: onixedit_enabled_ctx(%{current_path: "/studio/production"})
          )

        labels = Enum.map(entries, &(&1[:label] || &1["label"]))

        assert "Bokbasen" in labels,
               "expected Bokbasen in Registry.collect_top_menu_entries, got: #{inspect(labels)}"
      end
    end

    test "off by default: the workspace-less top-menu collector gates OnixEdit's Bokbasen tab out",
         ctx do
      if skip_unless_loaded(ctx) do
        # The determinism guarantee: with no workspace_id resolved, OnixEdit
        # (off by default) never leaks its Bokbasen tab into the directly-
        # rendered top menu — the workspace-less collector falls to declaration
        # defaults (snav-w1-gating-determinism) instead of the raw installed list.
        tab_labels =
          Registry.collect_top_menu_entries(baseline: [], ctx: %{dataset: "production"})
          |> Enum.map(&(&1[:label] || &1["label"]))

        refute "Bokbasen" in tab_labels
      end
    end

    test "collect_desk_items includes the Pending submissions entry", ctx do
      if skip_unless_loaded(ctx) do
        # DESK collectors stay unfiltered workspace-less (Structure re-filters),
        # so OnixEdit's desk contribution is reachable here without a workspace.
        items =
          Registry.collect_desk_items(
            baseline: [],
            ctx: %{dataset: "production", current_path: "/studio/production"}
          )

        labels = collect_labels(items)

        assert Enum.any?(labels, fn l ->
                 l && String.contains?(to_string(l), "Pending submissions")
               end),
               "expected Pending submissions desk item, got labels: #{inspect(labels)}"
      end
    end

    test "collect_desk_items (legacy binary form) also includes Pending submissions", ctx do
      if skip_unless_loaded(ctx) do
        # Backwards-compat: `collect_desk_items("production")` is the
        # legacy entry point. Same contract.
        items = Registry.collect_desk_items("production")
        labels = collect_labels(items)

        assert Enum.any?(labels, fn l ->
                 l && String.contains?(to_string(l), "Pending submissions")
               end),
               "expected Pending submissions via legacy collect_desk_items/1, got: #{inspect(labels)}"
      end
    end
  end
end
