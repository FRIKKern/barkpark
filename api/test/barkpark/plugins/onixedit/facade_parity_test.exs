defmodule Barkpark.Plugins.OnixEdit.FacadeParityTest do
  @moduledoc """
  Facade contract test for the OnixEdit god-module decomposition.

  `Barkpark.Plugins.OnixEdit` was split behind a facade: each large
  data-building `@impl Barkpark.Plugin` callback now delegates to a focused
  sub-module under `onixedit/` (PluginSettings, ApiTests, Routes, Menu, Cli,
  CodelistSeeders, SyncEntries) that returns the same shape verbatim.

  This file pins two invariants the split must never break:

    1. **Delegation parity** — each facade callback returns *exactly* what
       its sub-module returns (the facade adds no transformation). This is
       the byte-identical-output contract the host + the wider suite depend
       on, expressed as `facade_callback() == submodule_function()`.

    2. **Behaviour completeness** — the facade still `use`s the
       `Barkpark.Plugin` behaviour and exports every callback the host
       calls, so the plugin loads + registers identically.

  Pure value comparison — no Registry, no Req, no DB. Safe `async: true`.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Plugins.OnixEdit

  alias Barkpark.Plugins.OnixEdit.{
    ApiTests,
    Cli,
    CodelistSeeders,
    Menu,
    PluginSettings,
    Routes,
    SyncEntries
  }

  describe "facade delegates each data-building callback verbatim" do
    test "settings_schema/0 == PluginSettings.schema/0" do
      assert OnixEdit.settings_schema() == PluginSettings.schema()
    end

    test "api_tests/0 == ApiTests.specs/0" do
      assert OnixEdit.api_tests() == ApiTests.specs()
    end

    test "register_routes/1 == Routes.all/0" do
      assert OnixEdit.register_routes(%{}) == Routes.all()
    end

    test "top_menu_entries/0 == Menu.top_menu_entries/0" do
      assert OnixEdit.top_menu_entries() == Menu.top_menu_entries()
    end

    test "desk_items/1 == Menu.desk_items/1" do
      assert OnixEdit.desk_items("production") == Menu.desk_items("production")
    end

    test "cli_commands/0 == Cli.commands/0" do
      assert OnixEdit.cli_commands() == Cli.commands()
    end

    test "external_sync_entries/0 == SyncEntries.entries/0" do
      assert OnixEdit.external_sync_entries() == SyncEntries.entries()
    end

    test "codelist_seeders/0 == CodelistSeeders.seeders/0" do
      assert OnixEdit.codelist_seeders() == CodelistSeeders.seeders()
    end

    test "codelist_requirements/0 == CodelistSeeders.requirements/0" do
      assert OnixEdit.codelist_requirements() == CodelistSeeders.requirements()
    end
  end

  describe "data-building callbacks still return their pinned shapes" do
    test "register_routes/1 mounts the four known routes, paths + auth intact" do
      routes = OnixEdit.register_routes(%{})
      assert length(routes) == 4

      assert {:live, "/onixedit/ping", Barkpark.Plugins.OnixEdit.PingLive, :index} in routes

      assert {:get, "/onixedit/export/:dataset/:id",
              Barkpark.Plugins.OnixEdit.Web.ExportController, :show, [auth: :api]} in routes
    end

    test "settings_schema/0 keeps the five Bokbasen fields" do
      names = Enum.map(OnixEdit.settings_schema(), & &1.name)

      assert names == [
               "bokbasen.api_base",
               "bokbasen.oauth_token_url",
               "bokbasen.client_id",
               "bokbasen.client_secret",
               "bokbasen.client_role"
             ]
    end

    test "external_sync_entries/0 keeps the bokbasen channel + all state badges" do
      entries = OnixEdit.external_sync_entries()
      assert Map.keys(entries) == ["bokbasen"]
      states = entries["bokbasen"].states
      # 9 named states + the nil "Not synced" fallback.
      assert map_size(states) == 10
      assert states[nil] == %{color: "gray", label: "Not synced"}
      assert states["accepted"] == %{color: "green", label: "Accepted"}
    end

    test "codelist_requirements/0 keeps every list, order intact" do
      reqs = OnixEdit.codelist_requirements()
      # 2 critical (contributor_role @17, thema @1.6) + 71 issue-73 lists.
      assert length(reqs) == 73

      assert hd(reqs) == %{
               plugin_name: "onixedit",
               list_id: "onixedit:contributor_role",
               issue: "17"
             }

      assert Enum.at(reqs, 1) == %{
               plugin_name: "onixedit",
               list_id: "onixedit:thema",
               issue: "1.6"
             }

      assert List.last(reqs) == %{
               plugin_name: "onixedit",
               list_id: "onixedit:price_date_role",
               issue: "73"
             }
    end

    test "cli_commands/0 keeps the single onixedit.export verb" do
      [cmd] = OnixEdit.cli_commands()
      assert cmd.id == "onixedit.export"

      assert cmd.http == %{
               method: "GET",
               path_template: "/v1/plugins/onixedit/export/:dataset/:id"
             }

      assert cmd.auth_tier == "admin"
    end
  end

  describe "facade keeps the full Barkpark.Plugin behaviour contract" do
    @callbacks_the_host_calls [
      {:plugin_name, 0},
      {:book_schema!, 0},
      {:action_handlers, 0},
      {:resolve_action_handlers, 2},
      {:test_connection, 1},
      {:content_renderer, 3},
      {:register_workers, 1},
      {:register_routes, 1},
      {:resolve_doc_actions, 2},
      {:lifecycle_hooks, 0},
      {:external_sync_entries, 0},
      {:codelist_seeders, 0},
      {:api_tests, 0},
      {:settings_schema, 0},
      {:top_menu_entries, 0},
      {:desk_items, 1},
      {:cli_commands, 0},
      {:register_schemas, 1},
      {:document_actions, 0},
      {:codelist_requirements, 0}
    ]

    test "OnixEdit uses the Barkpark.Plugin behaviour" do
      behaviours =
        OnixEdit.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Barkpark.Plugin in behaviours
    end

    test "every host-called callback is still exported by the facade" do
      for {fun, arity} <- @callbacks_the_host_calls do
        assert function_exported?(OnixEdit, fun, arity),
               "OnixEdit lost #{fun}/#{arity} after the facade split"
      end
    end
  end
end
