defmodule Barkpark.Plugins.SettingsAuditTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.SettingsAudit

  @valid_attrs %{
    plugin_name: "tasks",
    action: "write",
    user_id: "user-abc",
    occurred_at: ~U[2024-06-01 10:00:00.000000Z]
  }

  describe "changeset/2 valid" do
    test "accepts all required fields with a valid action" do
      cs = SettingsAudit.changeset(%SettingsAudit{}, @valid_attrs)
      assert cs.valid?
    end

    test "user_id is optional — changeset valid without it" do
      attrs = Map.delete(@valid_attrs, :user_id)
      cs = SettingsAudit.changeset(%SettingsAudit{}, attrs)
      assert cs.valid?
    end

    test "all allowed action values are accepted" do
      for action <- ~w(read write delete reveal) do
        cs = SettingsAudit.changeset(%SettingsAudit{}, Map.put(@valid_attrs, :action, action))
        assert cs.valid?, "expected action #{action} to be valid"
      end
    end
  end

  describe "changeset/2 invalid" do
    test "missing plugin_name makes changeset invalid" do
      attrs = Map.delete(@valid_attrs, :plugin_name)
      cs = SettingsAudit.changeset(%SettingsAudit{}, attrs)
      refute cs.valid?
      assert {:plugin_name, _} = List.keyfind(cs.errors, :plugin_name, 0)
    end

    test "missing action makes changeset invalid" do
      attrs = Map.delete(@valid_attrs, :action)
      cs = SettingsAudit.changeset(%SettingsAudit{}, attrs)
      refute cs.valid?
      assert {:action, _} = List.keyfind(cs.errors, :action, 0)
    end

    test "missing occurred_at makes changeset invalid" do
      attrs = Map.delete(@valid_attrs, :occurred_at)
      cs = SettingsAudit.changeset(%SettingsAudit{}, attrs)
      refute cs.valid?
      assert {:occurred_at, _} = List.keyfind(cs.errors, :occurred_at, 0)
    end

    test "unknown action value is rejected" do
      attrs = Map.put(@valid_attrs, :action, "export")
      cs = SettingsAudit.changeset(%SettingsAudit{}, attrs)
      refute cs.valid?
      assert {:action, _} = List.keyfind(cs.errors, :action, 0)
    end
  end
end
