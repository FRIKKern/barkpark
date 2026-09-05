defmodule Barkpark.Content.SchemaDeskBlockTest do
  @moduledoc """
  Gyldendal parity stage E3.1 — the schema-level `desk` block (`orderings`)
  and the map-valued desk node filter.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Structure

  @dataset "desk-block-#{System.unique_integer([:positive])}"

  defp schema(desk) do
    %{
      "name" => "publication",
      "title" => "Utgivelse",
      "visibility" => "public",
      "fields" => [
        %{"name" => "title", "title" => "Tittel", "type" => "string"},
        %{"name" => "year", "title" => "År", "type" => "number"}
      ],
      "desk" => desk
    }
  end

  test "a valid desk.orderings block is stored and read back in the SDK envelope" do
    orderings = [
      %{"field" => "title", "direction" => "asc"},
      %{"field" => "year", "direction" => "desc"}
    ]

    {:ok, saved} = Content.upsert_schema(schema(%{"orderings" => orderings}), @dataset)
    assert saved.desk == %{"orderings" => orderings}
    assert Content.Schema.serialize_schema_for_sdk(saved).desk == %{"orderings" => orderings}
  end

  test "a bad ordering is refused at write, by name" do
    cs =
      SchemaDefinition.changeset(%SchemaDefinition{}, %{
        "name" => "x",
        "title" => "X",
        "desk" => %{"orderings" => [%{"field" => "title", "direction" => "sideways"}]}
      })

    refute cs.valid?
    assert {msg, _} = cs.errors[:desk]
    assert msg =~ "sideways"

    cs2 =
      SchemaDefinition.changeset(%SchemaDefinition{}, %{
        "name" => "x",
        "title" => "X",
        "desk" => %{"orderings" => "title"}
      })

    refute cs2.valid?
  end

  test "an absent desk block is the empty map — no declaration, no change" do
    {:ok, saved} = Content.upsert_schema(Map.delete(schema(%{}), "desk"), @dataset)
    assert saved.desk == %{}
  end

  test "resolve_schema/3 with NO tenant scope reads a tenant-owned schema (the unscoped global read), and with a foreign scope refuses it" do
    {:ok, saved} = Content.upsert_schema(schema(%{}), @dataset)
    assert saved.workspace_id != nil
    assert {:ok, %{id: id}} = Content.resolve_schema("publication", @dataset, [])
    assert id == saved.id

    {:ok, other} =
      Barkpark.Tenancy.create_workspace(%{
        slug: "desk-other-#{System.unique_integer([:positive])}",
        name: "Other"
      })

    assert :error == Content.resolve_schema("publication", @dataset, workspace_id: other.id)
  end

  test "Structure.parse_filter/1 passes a full filter map through untouched and keeps the legacy string form" do
    m = %{"content.cover.assetId" => %{"is" => "null"}}
    assert Structure.parse_filter(m) == m
    assert Structure.parse_filter("status=draft") == %{"status" => "draft"}
    assert Structure.parse_filter(nil) == %{}
  end
end
