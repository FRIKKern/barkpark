defmodule Barkpark.OwnedTablesTest do
  @moduledoc """
  task-d3ecc509d4ea227d: `Barkpark.OwnedTables` answers from the two existing
  instance-level switches (plugin registry, `Barkpark.Capability`) and from
  the live catalog only when an owner is off.

  `async: false`: the capability config is node-global.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Capability
  alias Barkpark.OwnedTables

  setup do
    previous = Application.fetch_env(:barkpark, Capability)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:barkpark, Capability, value)
        :error -> Application.delete_env(:barkpark, Capability)
      end
    end)

    :ok
  end

  test "a table no plugin or capability owns is core and always enabled" do
    assert OwnedTables.owner("documents") == :core
    assert OwnedTables.enabled?("documents")
    assert OwnedTables.present?("documents")
  end

  test "a capability's table follows Barkpark.Capability.enabled?/1" do
    assert OwnedTables.owner("cycle_waves") == {:capability, :cycle_fleet}

    Application.put_env(:barkpark, Capability, cycle_fleet: true)
    assert OwnedTables.enabled?("cycle_waves")

    Application.put_env(:barkpark, Capability, cycle_fleet: false)
    refute OwnedTables.enabled?("cycle_waves")

    # epic_fleet off turns cycle_fleet off too (Capability's @requires).
    Application.put_env(:barkpark, Capability, epic_fleet: false)
    refute OwnedTables.enabled?("cycle_waves")
    refute OwnedTables.enabled?("epic_assignments")
  end

  test "a plugin's table follows the plugin registry" do
    assert OwnedTables.owner("github_sync_conflicts") == {:plugin, "github"}

    registered? = Enum.any?(Barkpark.Plugins.Registry.all(), &(&1.name == "github"))
    assert OwnedTables.enabled?("github_sync_conflicts") == registered?
  end

  test "the ruled core tables are not owned (a core route, fence or module reads them)" do
    for table <-
          ~w(task_edges paper_access_log paper_events pulse_counters pulse_events pulse_meters) do
      assert OwnedTables.owner(table) == :core, "#{table} must be core under the 16:35Z rule"
    end
  end

  test "an off owner's table is present only while the relation exists" do
    Application.put_env(:barkpark, Capability, cycle_fleet: false)

    exists? =
      Repo.query!("SELECT to_regclass('public.cycle_waves') IS NOT NULL").rows == [[true]]

    assert OwnedTables.present?("cycle_waves") == exists?
  end

  test "function_exists?/1 reads the live catalog" do
    refute OwnedTables.function_exists?("no_such_function_d3ecc509(uuid)")
    assert OwnedTables.function_exists?("barkpark_revision_immutable()")
  end

  test "every fleet function signature resolves while the migrations are in place" do
    for signature <- OwnedTables.functions() do
      assert OwnedTables.function_exists?(signature), "#{signature} does not resolve"
    end
  end

  test "every owned table is named by a migration" do
    sources =
      Path.wildcard(Path.join(Application.app_dir(:barkpark, "priv/repo/migrations"), "*.exs"))
      |> Enum.map_join("\n", &File.read!/1)

    for table <- OwnedTables.tables() do
      assert sources =~ table, "#{table} is owned but no migration names it"
    end
  end
end
