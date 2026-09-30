defmodule Barkpark.Connectors.CatalogNoBridgeTest do
  @moduledoc """
  An instance that never ran the connectors bridge has no `chat_bridge` schema
  (charter D28: only the bridge creates it). Found on the stranger walk
  (2026-09-30): the Studio Connectors tab crashed to a LiveView server error on a
  fresh `bp setup --target local` instance, because `installs_for_workspace/1`
  raised `42P01 undefined_table`. With no bridge there are no installs.

  The test suite's own `test_helper.exs` CREATES the table for every other
  connectors test, so this one hides it inside a transaction it rolls back —
  async: false, because the rename holds an exclusive lock for its duration.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Connectors.Catalog
  alias Barkpark.Repo

  test "no chat_bridge table reads as no installs, not a crash" do
    ws_id = Ecto.UUID.generate()

    result =
      Repo.transaction(fn ->
        Repo.query!(
          "ALTER TABLE chat_bridge.connector_installs RENAME TO connector_installs_hidden"
        )

        installs = Catalog.installs_by_provider(ws_id)
        Repo.rollback({:read, installs})
      end)

    assert result == {:error, {:read, %{}}}
  end

  test "no chat_bridge SCHEMA reads as no installs too" do
    result =
      Repo.transaction(fn ->
        Repo.query!("ALTER SCHEMA chat_bridge RENAME TO chat_bridge_hidden")
        Repo.rollback({:read, Catalog.installs_for_workspace(Ecto.UUID.generate())})
      end)

    assert result == {:error, {:read, []}}
  end

  test "the table present still reads normally" do
    assert Catalog.installs_for_workspace(Ecto.UUID.generate()) == []
  end
end
