defmodule Barkpark.Plugins.SettingsTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Plugins.{Settings, SettingsAudit}

  @plugin "test_plugin"

  describe "put/2 + get/1 round-trip" do
    test "stores and retrieves the original map" do
      settings = %{"client_id" => "abc", "client_secret" => "supersecretvalue123"}

      assert {:ok, _rec} = Settings.put(@plugin, settings, user_id: "alice")
      assert {:ok, ^settings} = Settings.get(@plugin, user_id: "alice")
    end

    test "put/2 overwrites previous value" do
      assert {:ok, _} = Settings.put(@plugin, %{"k" => "v1"}, user_id: "alice")
      assert {:ok, _} = Settings.put(@plugin, %{"k" => "v2"}, user_id: "alice")
      assert {:ok, %{"k" => "v2"}} = Settings.get(@plugin)
    end
  end

  describe "delete/1" do
    test "after delete, get returns :not_found" do
      assert {:ok, _} = Settings.put(@plugin, %{"k" => "v"}, user_id: "alice")
      assert :ok = Settings.delete(@plugin, user_id: "alice")
      assert {:error, :not_found} = Settings.get(@plugin)
    end

    test "delete on missing returns :not_found" do
      assert {:error, :not_found} = Settings.delete("does_not_exist")
    end
  end

  describe "audit log" do
    test "read inserts an audit row with action=read and the user_id" do
      assert {:ok, _} = Settings.put(@plugin, %{"k" => "v"}, user_id: "alice")
      assert {:ok, _} = Settings.get(@plugin, user_id: "abc")

      audit_rows =
        from(a in SettingsAudit,
          where: a.plugin_name == ^@plugin and a.action == "read",
          select: a
        )
        |> Repo.all()

      assert Enum.any?(audit_rows, &(&1.user_id == "abc"))
    end

    test "write and delete each insert audit rows" do
      assert {:ok, _} = Settings.put(@plugin, %{"k" => "v"}, user_id: "bob")
      assert :ok = Settings.delete(@plugin, user_id: "bob")

      actions =
        from(a in SettingsAudit,
          where: a.plugin_name == ^@plugin,
          select: a.action
        )
        |> Repo.all()

      assert "write" in actions
      assert "delete" in actions
    end
  end

  describe "transactional audit (mutation + audit row atomic)" do
    test "put returns {:ok, record} and records a write audit row" do
      assert {:ok, %{plugin_name: @plugin}} =
               Settings.put(@plugin, %{"k" => "v"}, user_id: "carol")

      actions = audit_actions(@plugin)
      assert "write" in actions
    end

    test "delete returns :ok and records a delete audit row" do
      assert {:ok, _} = Settings.put(@plugin, %{"k" => "v"}, user_id: "carol")
      assert :ok = Settings.delete(@plugin, user_id: "carol")

      assert "delete" in audit_actions(@plugin)
    end

    test "reveal returns the unmasked map and records a reveal audit row" do
      settings = %{"client_secret" => "topsecret"}
      assert {:ok, _} = Settings.put(@plugin, settings, user_id: "carol")

      assert {:ok, ^settings} = Settings.reveal(@plugin, user_id: "carol")

      assert "reveal" in audit_actions(@plugin)
    end

    test "reveal on missing plugin returns :not_found and writes no audit row" do
      assert {:error, :not_found} = Settings.reveal("never_existed")
      assert audit_actions("never_existed") == []
    end
  end

  describe "encryption at rest" do
    test "raw column does not contain the plaintext value" do
      secret_marker = "PLAINTEXT_MARKER_DO_NOT_LEAK_3f8a"
      assert {:ok, _} = Settings.put(@plugin, %{"client_secret" => secret_marker})

      %{rows: [[raw]]} =
        Ecto.Adapters.SQL.query!(
          Repo,
          "SELECT settings FROM plugin_settings WHERE plugin_name = $1",
          [@plugin]
        )

      raw_str =
        cond do
          is_binary(raw) -> raw
          is_list(raw) -> IO.iodata_to_binary(raw)
          true -> inspect(raw)
        end

      refute String.contains?(raw_str, secret_marker)
    end
  end

  defp audit_actions(plugin_name) do
    from(a in SettingsAudit,
      where: a.plugin_name == ^plugin_name,
      select: a.action
    )
    |> Repo.all()
  end
end
