defmodule Mix.Tasks.Barkpark.EpicFleetCapabilityTest do
  @moduledoc """
  task-71ea7ca2c8fabce2: `mix barkpark.epic_fleet.export` and `import` refuse
  with a named message when the `epic_fleet` capability is off
  (`Barkpark.Capability`), and run as before when it is on.

  The ON arm is the control: the same call reaches the ledger and fails there
  ("export failed" / "import failed"), so the OFF refusal can only come from
  the capability check.

  `async: false` + `on_exit` restore: the capability config is node-global.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Capability
  alias Mix.Tasks.Barkpark.EpicFleet.Export
  alias Mix.Tasks.Barkpark.EpicFleet.Import

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

  defp put_capabilities(kw), do: Application.put_env(:barkpark, Capability, kw)

  defp missing_experiment, do: ["--experiment", Ecto.UUID.generate()]

  describe "export" do
    test "ON: reaches the ledger (control)" do
      put_capabilities(epic_fleet: true)

      assert_raise Mix.Error, ~r/EpicFleet benchmark export failed/, fn ->
        Export.run(missing_experiment())
      end
    end

    test "OFF: refuses and names the capability" do
      put_capabilities(epic_fleet: false)

      assert_raise Mix.Error,
                   ~r/export refused: the epic_fleet capability is off .*switched off: epic_fleet/,
                   fn -> Export.run(missing_experiment()) end
    end
  end

  describe "import" do
    setup do
      path =
        Path.join(System.tmp_dir!(), "epic-fleet-cap-#{System.unique_integer([:positive])}.json")

      File.write!(path, "{}")
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "ON: reaches the ledger (control)", %{path: path} do
      put_capabilities(epic_fleet: true)

      assert_raise Mix.Error, ~r/EpicFleet benchmark import failed/, fn -> Import.run([path]) end
    end

    test "OFF: refuses and names the capability", %{path: path} do
      put_capabilities(epic_fleet: false)

      assert_raise Mix.Error,
                   ~r/import refused: the epic_fleet capability is off .*switched off: epic_fleet/,
                   fn -> Import.run([path]) end
    end

    test "OFF: refuses before reading its input" do
      put_capabilities(epic_fleet: false)

      assert_raise Mix.Error, ~r/import refused/, fn ->
        Import.run(["/nonexistent/epic-fleet-#{System.unique_integer([:positive])}.json"])
      end
    end
  end

  test "cycle_fleet OFF does not refuse EpicFleet (the dependency runs the other way)" do
    put_capabilities(cycle_fleet: false)

    assert_raise Mix.Error, ~r/EpicFleet benchmark export failed/, fn ->
      Export.run(missing_experiment())
    end
  end
end
