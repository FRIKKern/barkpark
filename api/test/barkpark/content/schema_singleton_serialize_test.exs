defmodule Barkpark.Content.SchemaSingletonSerializeTest do
  @moduledoc """
  `singleton` must NOT be write-only on the schema API (task-567f0fb2429086df).

  The changeset casts `singleton` (schema_definition.ex), so
  `POST /v1/schemas/:dataset` accepts it — but `serialize_schema_for_sdk/1`
  (the body of BOTH the 201 echo and every `GET /v1/schemas/:dataset` row)
  omitted it, so a consumer could set the flag and never read back what took.
  These tests pin the serializer key so a removal reds RED again.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Schema
  alias Barkpark.Content.SchemaDefinition

  test "serialize_schema_for_sdk/1 emits singleton: true for a singleton schema" do
    schema = %SchemaDefinition{
      name: "siteSettings",
      title: "Site Settings",
      singleton: true,
      fields: [%{"name" => "title", "type" => "string"}]
    }

    serialized = Schema.serialize_schema_for_sdk(schema)

    assert Map.has_key?(serialized, :singleton),
           "serializer dropped the singleton key — the write-only regression is back"

    assert serialized.singleton == true
  end

  test "serialize_schema_for_sdk/1 emits singleton: false for an ordinary schema" do
    schema = %SchemaDefinition{
      name: "post",
      title: "Post",
      singleton: false,
      fields: [%{"name" => "title", "type" => "string"}]
    }

    serialized = Schema.serialize_schema_for_sdk(schema)

    assert Map.has_key?(serialized, :singleton)
    assert serialized.singleton == false
  end
end
