defmodule Barkpark.SchemaOwnershipTest do
  @moduledoc """
  task-097a1b8ed6d27a8b, criterion 0: every object in the migrated test
  database has exactly one owner in `Barkpark.SchemaOwnership`, and a table
  added without an owner turns this red.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.OwnedTables
  alias Barkpark.SchemaOwnership

  test "every object in the migrated database has an owner" do
    assert SchemaOwnership.audit(Repo) == []
  end

  test "a table created without an owner is reported (control)" do
    Repo.query!("CREATE TABLE schema_ownership_control_097a (id bigint PRIMARY KEY)")

    Repo.query!("""
    CREATE FUNCTION schema_ownership_control_097a_fn() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$
    """)

    audit = SchemaOwnership.audit(Repo)

    assert {:unowned_table, "schema_ownership_control_097a"} in audit
    assert {:unowned_function, "schema_ownership_control_097a_fn()"} in audit
    # Its primary-key index belongs to the table and is not reported on its own.
    refute Enum.any?(audit, fn {_, name} -> name == "schema_ownership_control_097a_pkey" end)
  end

  test "a trigger that outlives its function's owner is reported (control)" do
    # A core-table trigger calling a cycle_fleet function, with no entry in
    # trigger_owners: dropping cycle_fleet would leave it calling nothing.
    Repo.query!("""
    CREATE TRIGGER schema_ownership_control_097a BEFORE DELETE ON datasets
    FOR EACH ROW EXECUTE FUNCTION barkpark_teardown_cycle_ledger()
    """)

    assert {:trigger_outlives_function, "datasets.schema_ownership_control_097a"} in SchemaOwnership.audit(
             Repo
           )
  end

  test "each table, function, type and extension is listed once" do
    for map <- [
          SchemaOwnership.tables(),
          SchemaOwnership.functions(),
          SchemaOwnership.types(),
          SchemaOwnership.extensions()
        ],
        {name, owner} <- map do
      assert valid_owner?(owner), "#{name} has owner #{inspect(owner)}"
    end

    # The lists are maps, so a name cannot appear twice in one; a name in two
    # source lists (core and owned) would have been merged silently.
    owned = Map.keys(SchemaOwnership.owned_tables())
    core = for {t, :core} <- SchemaOwnership.tables(), do: t
    assert length(owned) + length(core) == map_size(SchemaOwnership.tables())
  end

  test "every trigger override is on a listed table and its owner depends on that table's owner" do
    for {{table, trigger}, owner} <- SchemaOwnership.trigger_owners() do
      table_owner = Map.fetch!(SchemaOwnership.tables(), table)

      assert SchemaOwnership.depends_on?(owner, table_owner),
             "#{table}.#{trigger}: #{inspect(owner)} does not depend on #{inspect(table_owner)}"
    end
  end

  test "OwnedTables reads the manifest" do
    for table <- OwnedTables.tables() do
      assert OwnedTables.owner(table) == Map.fetch!(SchemaOwnership.tables(), table)
    end

    for {table, :core} <- SchemaOwnership.tables(), do: assert(OwnedTables.owner(table) == :core)

    assert OwnedTables.core_triggers() == [
             {"projects", "projects_teardown_cycle_ledger"},
             {"workspaces", "workspaces_teardown_cycle_ledger"}
           ]

    assert length(OwnedTables.functions()) == 26
  end

  test "depends_on? follows Barkpark.Capability's requirements" do
    assert SchemaOwnership.depends_on?({:capability, :cycle_fleet}, {:capability, :epic_fleet})
    refute SchemaOwnership.depends_on?({:capability, :epic_fleet}, {:capability, :cycle_fleet})
    assert SchemaOwnership.depends_on?({:plugin, "github"}, :core)
    refute SchemaOwnership.depends_on?(:core, {:plugin, "github"})
    refute SchemaOwnership.depends_on?({:plugin, "github"}, {:capability, :studio_chat})
  end

  # Needs every owner's objects present, so `mix test.core_without_owned_tables`
  # (which drops them) excludes it.
  @tag :owned_tables
  test "every listed object exists in the migrated database" do
    assert SchemaOwnership.missing(Repo) == []
  end

  defp valid_owner?(:core), do: true
  defp valid_owner?({:capability, name}), do: name in Barkpark.Capability.names()
  defp valid_owner?({:plugin, name}), do: name in ["bulldocs", "github"]
end
