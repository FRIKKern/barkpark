defmodule Barkpark.Content.SchemaContentHashTest do
  @moduledoc """
  task-bf1c4f2b2b930088: the same schemas copied to a second instance with
  `bp schema ls` and `bp schema apply` reported a different `schemaHash` on
  every schema. The hash read the stored fields, and the copy stored the
  echoed `required?` key that the read path recomputes. `datasetSchemaHash`
  digests row count and last write time, so it never matches across
  instances either.

  `schemaHash` now digests the served schema, and `datasetSchemaContentHash`
  digests the served schemas of a dataset. Both depend only on content.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition

  @admin_token "barkpark-dev-token-schema-content-hash"

  setup do
    Auth.create_token(@admin_token, "dev", "schema-content-hash-test", ["read", "write", "admin"])
    :ok
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @admin_token)
    |> put_req_header("content-type", "application/json")
  end

  defp schema(attrs) do
    struct(
      SchemaDefinition,
      Map.merge(
        %{
          name: "book",
          title: "Book",
          visibility: "public",
          fields: [
            %{"name" => "title", "type" => "string", "validation" => %{"required" => true}},
            %{"name" => "tags", "type" => "array"}
          ]
        },
        attrs
      )
    )
  end

  describe "schemaHash" do
    test "ignores row metadata" do
      a =
        schema(%{
          id: Ecto.UUID.generate(),
          dataset: "production",
          workspace_id: Ecto.UUID.generate(),
          inserted_at: ~U[2026-01-01 00:00:00Z],
          updated_at: ~U[2026-01-01 00:00:00Z]
        })

      b =
        schema(%{
          id: Ecto.UUID.generate(),
          dataset: "copy",
          workspace_id: Ecto.UUID.generate(),
          inserted_at: ~U[2026-11-06 15:57:00Z],
          updated_at: ~U[2026-11-06 15:57:00Z]
        })

      assert Content.schema_hash_for_schema(a) == Content.schema_hash_for_schema(b)
    end

    test "ignores key order and keys the read path recomputes" do
      original = schema(%{})

      copied =
        schema(%{
          fields: [
            %{
              "validation" => %{"required" => true},
              "type" => "string",
              "required?" => true,
              "name" => "title"
            },
            %{
              "name" => "tags",
              "type" => "array",
              "of" => [%{"type" => "string"}],
              "required?" => false
            }
          ]
        })

      assert Content.schema_hash_for_schema(original) == Content.schema_hash_for_schema(copied)
    end

    test "moves when the content changes" do
      base = Content.schema_hash_for_schema(schema(%{}))
      refute Content.schema_hash_for_schema(schema(%{title: "Bok"})) == base

      reordered =
        schema(%{
          fields: [
            %{"name" => "tags", "type" => "array"},
            %{"name" => "title", "type" => "string", "validation" => %{"required" => true}}
          ]
        })

      refute Content.schema_hash_for_schema(reordered) == base
    end
  end

  test "two equal schema sets give equal hashes over the API", %{conn: conn} do
    sources = [
      %{
        "name" => "hash_book",
        "title" => "Book",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string", "validation" => %{"required" => true}},
          %{"name" => "tags", "type" => "array"}
        ]
      },
      %{
        "name" => "hash_author",
        "title" => "Author",
        "fields" => [%{"name" => "name", "type" => "string"}]
      }
    ]

    for s <- sources do
      assert conn
             |> authed()
             |> post(~p"/v1/schemas/hashsource", Jason.encode!(s))
             |> json_response(201)
    end

    source = conn |> authed() |> get(~p"/v1/schemas/hashsource") |> json_response(200)

    # Copy the listed schemas the way an operator does: apply each listed
    # schema, minus its hash, in reverse order, into another dataset.
    for s <- Enum.reverse(source["schemas"]) do
      body = s |> Map.delete("schemaHash") |> Jason.encode!()
      assert conn |> authed() |> post(~p"/v1/schemas/hashcopy", body) |> json_response(201)
    end

    copy = conn |> authed() |> get(~p"/v1/schemas/hashcopy") |> json_response(200)

    hashes = fn env -> Map.new(env["schemas"], &{&1["name"], &1["schemaHash"]}) end
    assert map_size(hashes.(source)) == 2
    assert hashes.(copy) == hashes.(source)

    assert source["datasetSchemaContentHash"] =~ ~r/^[0-9a-f]{16}$/
    assert copy["datasetSchemaContentHash"] == source["datasetSchemaContentHash"]

    # A change in the copy moves its content hash.
    changed = %{
      "name" => "hash_author",
      "title" => "Forfatter",
      "fields" => [%{"name" => "name", "type" => "string"}]
    }

    assert conn
           |> authed()
           |> post(~p"/v1/schemas/hashcopy", Jason.encode!(changed))
           |> json_response(201)

    moved = conn |> authed() |> get(~p"/v1/schemas/hashcopy") |> json_response(200)
    refute moved["datasetSchemaContentHash"] == source["datasetSchemaContentHash"]
  end
end
