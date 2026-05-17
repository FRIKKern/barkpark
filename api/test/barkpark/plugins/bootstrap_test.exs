defmodule Barkpark.Plugins.BootstrapTest do
  @moduledoc """
  Regression test for the `Barkpark.Plugins.Bootstrap` auto-install pipeline.

  Guards against re-introducing the manual `mix run -e ...` workaround that
  prompted Task #5: before this code, plugin-declared schemas (notably the
  OnixEdit `book` schema) never landed in `schema_definitions` on a fresh
  deploy unless an operator opened a remote console and ran the registration
  by hand. The bootstrap closes that gap by:

    1. Installing plugin schemas at app boot via a post-`Supervisor.start_link`
       Task in `Barkpark.Application.start/2`.
    2. Re-installing them on `mix ecto.reset` via `priv/repo/seeds.exs`.

  These tests exercise (1) — the shared `register_all_schemas/0` entrypoint —
  through both DB-level assertions and a Phoenix conn integration that proves
  `GET /v1/schemas/production` surfaces the registered schema to Studio/TUI
  clients.

  Single-file design (vs. splitting DataCase + ConnCase) is deliberate:
  `BarkparkWeb.ConnCase` already runs `Barkpark.DataCase.setup_sandbox/1`, so
  using it once gives us both DB transaction isolation AND a `conn` fixture.
  The Registry GenServer is a singleton across tests, so we keep
  `async: false` and use a unique stub plugin name in the negative path.
  """

  use BarkparkWeb.ConnCase, async: false

  @moduletag :plugin_bootstrap

  import Ecto.Query

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.Bootstrap
  alias Barkpark.Plugins.Registry
  alias Barkpark.Repo

  @admin_token "barkpark-dev-token"

  defmodule RaisingStub do
    @moduledoc false
    # Synthetic plugin that always raises, used by the negative-path test
    # below. Defined at module top level so `Code.ensure_loaded?/1` (called
    # from `Bootstrap.install_for_plugin/1`) returns true.
    def register_schemas(_opts), do: raise("synthetic bootstrap failure")
  end

  defmodule MixedKeyStub do
    @moduledoc false
    # Synthetic plugin that emits a `%SchemaDefinition{}` whose `:fields`
    # value is a list of *string-keyed* maps — mirroring the shape produced
    # by real plugins that load fields from a JSON-decoded manifest (e.g.
    # OnixEdit's `book.json`). Bootstrap must stringify the wrapping struct
    # keys before handing the attrs to `Content.upsert_schema/2`; otherwise
    # `Ecto.Changeset.cast/3` raises with "expected params to be a map with
    # atoms or string keys".
    alias Barkpark.Content.SchemaDefinition

    def schema_name, do: "bootstrap_test_mixed_keys"

    def register_schemas(_opts) do
      [
        %SchemaDefinition{
          name: schema_name(),
          title: "Mixed Keys Stub",
          visibility: "private",
          fields: [%{"name" => "f1", "type" => "string"}],
          dataset: "production"
        }
      ]
    end
  end

  describe "register_all_schemas/0 — DB-level" do
    test "installs the OnixEdit book schema" do
      assert {:ok, count} = Bootstrap.register_all_schemas()
      assert count >= 1

      books =
        SchemaDefinition
        |> where([s], s.name == "book" and s.dataset == "production")
        |> Repo.all()

      assert length(books) == 1
      [book] = books

      # Mirrors the shape produced by Barkpark.Plugins.OnixEdit.register_schemas/1
      # at api/lib/barkpark/plugins/onixedit.ex:65-79 (visibility default
      # "private" per D2; fields = the v2 composite/arrayOf/codelist tree).
      assert book.name == "book"
      assert is_binary(book.title)
      assert book.visibility == "private"
      assert book.dataset == "production"
      assert is_list(book.fields)
      assert book.fields != []
    end

    test "is idempotent — second call does not duplicate the book row" do
      assert {:ok, n1} = Bootstrap.register_all_schemas()
      assert {:ok, n2} = Bootstrap.register_all_schemas()

      # Both invocations should report the same upsert count: the second
      # call routes through Repo.update for the existing row, not insert.
      assert n1 == n2

      count =
        Repo.aggregate(
          from(s in SchemaDefinition, where: s.name == "book" and s.dataset == "production"),
          :count,
          :id
        )

      assert count == 1
    end

    test "register_all_schemas/0 normalizes mixed atom/string keys before upsert" do
      plugin_name = "bootstrap_test_mixed_keys_plugin_#{System.unique_integer([:positive])}"

      assert :ok =
               Registry.register(
                 __MODULE__.MixedKeyStub,
                 %{"plugin_name" => plugin_name, "version" => "0.0.0"}
               )

      cleanup_stub_on_exit(plugin_name)

      # If `stringify_keys/1` is missing or skipped, `Content.upsert_schema/2`
      # raises ArgumentError from `Ecto.Changeset.cast/3` because the struct's
      # atom-keyed top-level collides with the `"dataset"` (string) key the
      # upsert helper force-injects. With the helper applied, the call
      # returns `{:ok, n}` and the row lands.
      assert {:ok, count} = Bootstrap.register_all_schemas()
      assert count >= 1

      schema =
        SchemaDefinition
        |> where(
          [s],
          s.name == ^MixedKeyStub.schema_name() and s.dataset == "production"
        )
        |> Repo.one()

      assert schema, "expected mixed-key stub schema to be persisted"
      assert schema.visibility == "private"
      # The :fields list arrives string-keyed and round-trips through Postgres
      # JSONB unchanged. We assert key shape (string keys preserved) rather
      # than equality on the literal structure to keep this resilient to any
      # future field-shape sanitisation.
      assert is_list(schema.fields)
      assert [%{} = field | _] = schema.fields
      assert Map.has_key?(field, "name")
      assert Map.has_key?(field, "type")
      assert field["name"] == "f1"
      assert field["type"] == "string"
    end

    test "returns error tuple when a registered plugin raises in register_schemas/1" do
      stub_name = "bootstrap_test_raising_#{System.unique_integer([:positive])}"

      assert :ok =
               Registry.register(
                 __MODULE__.RaisingStub,
                 %{"plugin_name" => stub_name, "version" => "0.0.0"}
               )

      cleanup_stub_on_exit(stub_name)

      assert {:error, errors} = Bootstrap.register_all_schemas()
      assert is_list(errors)

      stub_error = Enum.find(errors, fn {name, _} -> name == stub_name end)

      assert match?({^stub_name, {:raised, _msg}}, stub_error),
             "expected an error entry for stub plugin #{stub_name}, got: #{inspect(errors)}"

      {^stub_name, {:raised, msg}} = stub_error
      assert is_binary(msg)
      assert msg =~ "synthetic"

      # Stub never reached upsert_schemas/2, so no schema row should exist
      # under its plugin name (the stub doesn't even declare a schema name —
      # this is just defensive: confirm it didn't accidentally seep in).
      stray =
        SchemaDefinition
        |> where([s], s.name == ^stub_name)
        |> Repo.all()

      assert stray == []
    end
  end

  describe "GET /v1/schemas/production — conn integration" do
    setup do
      # /v1/schemas/* sits behind the :require_admin pipeline
      # (router.ex:136-142). Mirror schema_envelope_test setup style.
      Barkpark.Auth.create_token(
        @admin_token,
        "dev-bootstrap-test",
        "production",
        ["read", "write", "admin"]
      )

      assert {:ok, _count} = Bootstrap.register_all_schemas()
      :ok
    end

    test "returns book schema in the SDK envelope", %{conn: conn} do
      body =
        conn
        |> put_req_header("authorization", "Bearer #{@admin_token}")
        |> get("/v1/schemas/production")
        |> json_response(200)

      assert is_list(body["schemas"])

      book = Enum.find(body["schemas"], &(&1["name"] == "book"))

      assert book,
             "book schema missing from /v1/schemas/production response: #{inspect(Enum.map(body["schemas"], & &1["name"]))}"

      # Shape per Content.serialize_schema_for_sdk/1
      # (api/lib/barkpark/content.ex around line 754) — what real Studio/TUI
      # clients consume.
      assert book["visibility"] == "private"
      assert is_list(book["fields"])
      assert book["fields"] != []
      assert is_binary(book["schemaHash"])
      assert String.length(book["schemaHash"]) == 16

      # Envelope-level invariant from SchemaController.index/2.
      assert is_binary(body["datasetSchemaHash"])
      assert body["_schemaVersion"] == 1
    end
  end

  # ─── Test isolation helpers ────────────────────────────────────────────

  # `Barkpark.Plugins.Registry` is a singleton GenServer whose state lives
  # outside the Ecto sandbox, so `Registry.register/2` calls leak between
  # tests (and between test runs). The Registry currently exposes no public
  # `unregister/1`, so we surgically remove the test stub from its state via
  # `:sys.replace_state/2` — OTP's documented test/debug hook for cases
  # exactly like this. Registered via `on_exit/2` so cleanup runs even when
  # the body's assertions fail.
  #
  # The Registry caches reads in `:persistent_term` (key
  # `{Barkpark.Plugins.Registry, :snapshot}`); a raw `:sys.replace_state`
  # bypasses the GenServer's `handle_call`, so we manually purge the cache
  # too. Once `Registry.unregister/1` lands, both pokes go away.
  #
  # TODO: if more tests start needing this pattern, promote a public
  # `Barkpark.Plugins.Registry.unregister/1` and drop the direct state poke.
  defp cleanup_stub_on_exit(plugin_name) do
    ExUnit.Callbacks.on_exit(fn ->
      :sys.replace_state(Barkpark.Plugins.Registry, fn state ->
        %{state | plugins: Map.delete(state.plugins, plugin_name)}
      end)

      :persistent_term.erase({Barkpark.Plugins.Registry, :snapshot})
    end)
  end
end
