defmodule Barkpark.Plugins.CycleCapabilitiesTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Capabilities

  test "cycle.open exposes correction inputs without requiring standard-open inputs" do
    command =
      Capabilities.manifest("admin", project: false)["commands"]
      |> Enum.find(&(&1["id"] == "cycle.open"))

    assert command

    required =
      command["args"]
      |> Enum.filter(& &1["required"])
      |> Enum.map(& &1["name"])

    assert required == ["epic_id", "wave_id"]

    optional_args =
      command["args"]
      |> Enum.reject(& &1["required"])
      |> Enum.map(& &1["name"])

    assert optional_args == ["profile", "inventory_json", "scale_contract_json"]

    flags = Map.new(command["flags"], &{&1["name"], &1})
    assert flags["correction_of_json"]["type"] == "string"
    assert flags["correction_of_digest"]["type"] == "string"
  end

  test "cycle.open keeps the standard positional argument order" do
    command =
      Capabilities.manifest("admin", project: false)["commands"]
      |> Enum.find(&(&1["id"] == "cycle.open"))

    assert Enum.map(command["args"], & &1["name"]) == [
             "epic_id",
             "wave_id",
             "profile",
             "inventory_json",
             "scale_contract_json"
           ]
  end
end
