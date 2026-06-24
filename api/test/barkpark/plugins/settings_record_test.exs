defmodule Barkpark.Plugins.SettingsRecordTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.SettingsRecord

  @valid_attrs %{
    plugin_name: "my_plugin",
    settings: %{"api_key" => "secret"},
    updated_at: ~U[2024-01-01 12:00:00.000000Z],
    updated_by: "alice"
  }

  describe "changeset/2 valid" do
    test "accepts all required fields" do
      cs = SettingsRecord.changeset(%SettingsRecord{}, @valid_attrs)
      assert cs.valid?
    end

    test "optional updated_by is accepted when present" do
      cs = SettingsRecord.changeset(%SettingsRecord{}, @valid_attrs)
      assert Ecto.Changeset.get_change(cs, :updated_by) == "alice"
    end

    test "updated_by is optional — changeset valid without it" do
      attrs = Map.delete(@valid_attrs, :updated_by)
      cs = SettingsRecord.changeset(%SettingsRecord{}, attrs)
      assert cs.valid?
    end
  end

  describe "changeset/2 invalid" do
    test "missing plugin_name is invalid" do
      attrs = Map.delete(@valid_attrs, :plugin_name)
      cs = SettingsRecord.changeset(%SettingsRecord{}, attrs)
      refute cs.valid?
      assert {:plugin_name, _} = List.keyfind(cs.errors, :plugin_name, 0)
    end

    test "missing settings is invalid" do
      attrs = Map.delete(@valid_attrs, :settings)
      cs = SettingsRecord.changeset(%SettingsRecord{}, attrs)
      refute cs.valid?
      assert {:settings, _} = List.keyfind(cs.errors, :settings, 0)
    end

    test "missing updated_at is invalid" do
      attrs = Map.delete(@valid_attrs, :updated_at)
      cs = SettingsRecord.changeset(%SettingsRecord{}, attrs)
      refute cs.valid?
      assert {:updated_at, _} = List.keyfind(cs.errors, :updated_at, 0)
    end
  end
end
