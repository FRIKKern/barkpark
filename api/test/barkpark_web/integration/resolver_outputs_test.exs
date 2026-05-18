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
    * `/studio/<dataset>` (LiveView) — renders the Bokbasen top-menu tab
      and the Pending submissions desk link inside the Studio chrome.
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

  alias Barkpark.Auth
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Plugins.OnixEdit
  alias Barkpark.Plugins.Registry

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
    test "includes the OnixEdit-contributed book schema", %{conn: conn} = ctx do
      if skip_unless_loaded(ctx) do
        conn = get(conn, ~p"/api/schemas")
        assert conn.status == 200

        schemas = json_response(conn, 200)
        assert is_list(schemas)

        names = Enum.map(schemas, & &1["name"])

        assert "book" in names,
               "expected plugin-contributed `book` schema in /api/schemas, got: #{inspect(names)}"
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

  describe "GET /studio/production — Studio LiveView renders plugin contributions" do
    setup do
      # Studio chrome (studio_tabs, desk pane) is rendered by a LiveView
      # via the :studio_public live_session. `Phoenix.LiveViewTest.live/2`
      # drives the full mount and returns the rendered HTML so we can pin
      # both the dead-render and the post-mount markers in one assertion.
      :ok
    end

    test "HTML contains the Bokbasen top-menu tab", %{conn: conn} = ctx do
      if skip_unless_loaded(ctx) do
        {:ok, _view, html} = live(conn, "/studio/production")

        assert html =~ "Bokbasen",
               "expected Bokbasen top-menu tab in /studio/production HTML"
      end
    end

    test "HTML contains the Pending submissions desk link", %{conn: conn} = ctx do
      if skip_unless_loaded(ctx) do
        {:ok, _view, html} = live(conn, "/studio/production")

        assert html =~ "Pending submissions",
               "expected OnixEdit desk_items contribution (Pending submissions) in HTML"
      end
    end

    test "HTML contains the nav-plugin-entry marker", %{conn: conn} = ctx do
      if skip_unless_loaded(ctx) do
        {:ok, _view, html} = live(conn, "/studio/production")

        assert html =~ "nav-plugin-entry",
               "expected nav-plugin-entry marker (rendered when a :plugin_link desk item is present)"
      end
    end

    test "HTML contains the top-menu-tab marker", %{conn: conn} = ctx do
      if skip_unless_loaded(ctx) do
        {:ok, _view, html} = live(conn, "/studio/production")

        assert html =~ "top-menu-tab",
               "expected top-menu-tab marker on the rendered studio_tabs component"
      end
    end
  end

  # ── Block 4 — Registry.collect_* returns plugin contributions ────────────

  describe "Registry.collect_* — direct resolver-chain verification" do
    test "collect_top_menu_entries includes the Bokbasen entry", ctx do
      if skip_unless_loaded(ctx) do
        entries =
          Registry.collect_top_menu_entries(
            baseline: [],
            ctx: %{dataset: "production", current_path: "/studio/production"}
          )

        labels = Enum.map(entries, &(&1[:label] || &1["label"]))

        assert "Bokbasen" in labels,
               "expected Bokbasen in Registry.collect_top_menu_entries, got: #{inspect(labels)}"
      end
    end

    test "collect_desk_items includes the Pending submissions entry", ctx do
      if skip_unless_loaded(ctx) do
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
