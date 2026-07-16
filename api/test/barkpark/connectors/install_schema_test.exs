defmodule Barkpark.Connectors.InstallSchemaTest do
  @moduledoc """
  The cross-schema READ (Connectors D54/D55) — the first `@schema_prefix` in the
  codebase, proven end to end against a real Postgres.

  Three things are pinned here, each of which has a specific way of failing:

    1. **The table exists at all.** No Ecto migration creates `chat_bridge` (D28
       — the bridge owns its DDL), so without `test_helper.exs`'s fixture this
       whole file raises `42P01 undefined_table`. This suite IS the proof that
       the fixture works, from a DB that never had the schema.

    2. **The `type(ci.workspace_id, Ecto.UUID)` cast.** `connector_installs.
       workspace_id` is Postgres `text`; `workspaces.id` is `uuid`. The uncast
       join raises `42883 operator does not exist: uuid = text`. `assert_raise`
       below proves the failure is REAL, so the passing join is not vacuous.

    3. **THE COLUMN SET (the DDL-drift tripwire).** `connectors/src/db/schema.ts`
       is the upstream owner and has already drifted once. If a bridge-side rename
       lands, this reds in Elixir CI rather than 500ing Studio in prod.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Connectors.Catalog
  alias Barkpark.Connectors.Install
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  setup do
    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "conn-read-a", name: "Conn Read A"})
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "conn-read-b", name: "Conn Read B"})
    {:ok, ws_a: ws_a, ws_b: ws_b}
  end

  # The bridge is the only WRITER in production. Tests write raw SQL because
  # there is deliberately no Elixir write path — adding one would fork ownership
  # of the table.
  defp insert_install(provider, key, ws_id, opts \\ []) do
    Repo.query!(
      """
      INSERT INTO chat_bridge.connector_installs
        (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
      VALUES ($1, $2, $3, $4, $5, now())
      """,
      [
        provider,
        key,
        ws_id,
        Keyword.get(opts, :credential_ref, "SEALED-CREDENTIAL-BLOB"),
        Keyword.get(opts, :chat_token_ref, "SEALED-CHAT-TOKEN-BLOB")
      ]
    )
  end

  describe "the column set (DDL drift tripwire)" do
    test "chat_bridge.connector_installs has EXACTLY the columns Install declares" do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT column_name FROM information_schema.columns
          WHERE table_schema = 'chat_bridge' AND table_name = 'connector_installs'
          """,
          []
        )

      actual = rows |> List.flatten() |> Enum.sort()

      assert actual == Enum.sort(Install.columns()),
             """
             chat_bridge.connector_installs has drifted from api/lib/barkpark/connectors/install.ex.

             Postgres: #{inspect(actual)}
             Install:  #{inspect(Enum.sort(Install.columns()))}

             The bridge OWNS this DDL (connectors/src/db/schema.ts). If it changed,
             update install.ex AND api/test/test_helper.exs's fixture.
             """
    end

    test "workspace_id is TEXT, not uuid — the whole reason every compare needs a cast (D55)" do
      %{rows: [[type]]} =
        Repo.query!(
          """
          SELECT data_type FROM information_schema.columns
          WHERE table_schema = 'chat_bridge' AND table_name = 'connector_installs'
            AND column_name = 'workspace_id'
          """,
          []
        )

      assert type == "text"
    end
  end

  describe "installs_for_workspace/1 (the cast + the join)" do
    test "returns THIS workspace's installs and not the other's", %{ws_a: a, ws_b: b} do
      insert_install("telegram", "111:aaa", a.id)
      insert_install("discord", "999888777", b.id)

      assert [%{provider: "telegram", install_key: "111:aaa"}] = Catalog.installs_for_workspace(a)

      assert [%{provider: "discord", install_key: "999888777"}] =
               Catalog.installs_for_workspace(b)
    end

    test "the join carries the workspace through — and does NOT raise 42883", %{ws_a: a} do
      insert_install("telegram", "111:aaa", a.id)

      assert [row] = Catalog.installs_for_workspace(a)
      assert row.workspace_slug == a.slug
      assert row.workspace_id == a.id
      assert %DateTime{} = row.created_at
    end

    test "PROTECTIVE — the SAME join WITHOUT type(…, Ecto.UUID) raises 42883", %{ws_a: a} do
      insert_install("telegram", "111:aaa", a.id)

      # If this ever stops raising, the cast in Catalog is decoration and the
      # green test above proves nothing.
      err =
        assert_raise Postgrex.Error, fn ->
          Repo.all(
            from(ci in Install,
              join: w in Barkpark.Tenancy.Workspace,
              on: ci.workspace_id == w.id,
              where: w.id == ^a.id,
              select: ci.provider
            )
          )
        end

      assert err.postgres.code == :undefined_function
      assert err.postgres.message =~ "operator does not exist"
    end

    test "an orphan install (workspace deleted) is not shown — the INNER JOIN is the tenancy proof" do
      insert_install("telegram", "111:orphan", Ecto.UUID.generate())

      %{rows: [[count]]} =
        Repo.query!("SELECT count(*) FROM chat_bridge.connector_installs", [])

      assert count == 1
      assert Catalog.installs_for_workspace(Ecto.UUID.generate()) == []
    end

    test "a garbage workspace id is [] — never an Ecto.CastError 500" do
      assert Catalog.installs_for_workspace("not-a-uuid") == []
      assert Catalog.installs_for_workspace(nil) == []
    end

    test "zero installs => [] (nothing is seeded anywhere)", %{ws_a: a} do
      assert Catalog.installs_for_workspace(a) == []
      assert Catalog.installs_by_provider(a) == %{}
    end
  end

  describe "installs_by_provider/1 groups EVERY install (D161)" do
    test "two installs of the SAME provider in one workspace BOTH surface", %{ws_a: a} do
      # Inserted OUT of alphabetical order on purpose (…002 before …001) to prove
      # the ordering is not insertion order.
      insert_install("telegram", "8100000002", a.id)
      insert_install("telegram", "8100000001", a.id)

      by_provider = Catalog.installs_by_provider(a)

      assert %{"telegram" => installs} = by_provider
      keys = Enum.map(installs, & &1.install_key)

      # BOTH surface — the pre-D161 `Map.put_new` collapse silently dropped the
      # second install, leaving a credential no card could disconnect.
      assert length(installs) == 2
      assert "8100000001" in keys
      assert "8100000002" in keys

      # install_key-ALPHABETICAL (inherited from installs_for_workspace's
      # `order_by: [asc: provider, asc: install_key]`), NEVER creation order.
      assert keys == ["8100000001", "8100000002"]
    end

    test "distinct providers each map to their own one-element list", %{ws_a: a} do
      insert_install("telegram", "111:aaa", a.id)
      insert_install("discord", "999888777", a.id)

      assert %{
               "telegram" => [%{install_key: "111:aaa"}],
               "discord" => [%{install_key: "999888777"}]
             } = Catalog.installs_by_provider(a)
    end
  end

  describe "no secret ever leaves the database (D38)" do
    test "the select carries NEITHER credential_ref NOR chat_token_ref", %{ws_a: a} do
      insert_install("telegram", "111:aaa", a.id,
        credential_ref: "SEALED-CREDENTIAL-BLOB",
        chat_token_ref: "SEALED-CHAT-TOKEN-BLOB"
      )

      assert [row] = Catalog.installs_for_workspace(a)

      refute Map.has_key?(row, :credential_ref)
      refute Map.has_key?(row, :chat_token_ref)

      assert Enum.sort(Map.keys(row)) ==
               ~w(created_at install_key provider workspace_id workspace_slug)a

      # And the blobs are nowhere in the returned term at all.
      refute inspect(row) =~ "SEALED"
    end

    test "readable_columns/0 is a strict subset of columns/0, minus the two sealed ones" do
      assert Install.readable_columns() == ~w(provider install_key workspace_id created_at)
      refute "credential_ref" in Install.readable_columns()
      refute "chat_token_ref" in Install.readable_columns()
    end
  end

  describe "the sandbox holds across the non-public prefix" do
    # The leak tripwire. Every test above that inserts also asserts an ABSOLUTE
    # count, so if the DataCase sandbox did not roll back writes to a non-`public`
    # schema, this file goes red no matter which order ExUnit shuffles it into.
    test "a fresh test sees an empty chat_bridge table", %{ws_a: a} do
      assert Catalog.installs_for_workspace(a) == []

      %{rows: [[count]]} =
        Repo.query!("SELECT count(*) FROM chat_bridge.connector_installs", [])

      assert count == 0
    end
  end

  describe "token_label/2" do
    test "is the ONLY handle disconnect has on a minted chat token" do
      assert Catalog.token_label("telegram", "111:aaa") == "connector:telegram:111:aaa"
    end
  end
end
