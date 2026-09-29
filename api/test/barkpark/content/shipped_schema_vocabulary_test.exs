defmodule Barkpark.Content.ShippedSchemaVocabularyTest do
  @moduledoc """
  E3.6 named object types added an apply-time gate: a field type that is
  neither built-in nor a registered object type is refused with 422. That gate
  must never refuse a schema the platform itself ships — plugin schema JSON,
  provisioner templates, the repo-root templates — or boot (`SchemaBootstrap`)
  and workspace import (`astro-search-starter`, `portableDocument`) fail closed.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.Schema

  # The repo-root `templates/` mirror is deliberately NOT read: the provisioner
  # catalog is the source the workspace import journey reads, and the Elixir
  # path-escape ratchet (scripts/elixir-path-escape-check.sh) does not
  # dispatch on the whole mirror.
  @roots [
    "priv/plugins",
    "priv/templates",
    "../internal/provisioner/catalog/templates"
  ]

  defp shipped_schema_files do
    @roots
    |> Enum.map(&Path.expand(&1, File.cwd!()))
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/schemas/*.json")))
    |> Enum.sort()
  end

  test "every shipped schema JSON passes the named-type gate (no type refused)" do
    files = shipped_schema_files()
    assert files != [], "no shipped schema JSON found under #{inspect(@roots)}"

    refused =
      for file <- files,
          {:ok, raw} = File.read(file),
          {:ok, schema} = Jason.decode(raw),
          is_map(schema) and is_list(schema["fields"]),
          {:error, changeset} <- [Schema.validate_schema(schema, "vocab-test")],
          reduce: [] do
        acc ->
          msgs =
            changeset
            |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
            |> Map.get(:fields, [])
            |> List.flatten()
            |> Enum.filter(&String.contains?(&1, "unknown field type"))

          if msgs == [], do: acc, else: [{Path.relative_to_cwd(file), msgs} | acc]
      end

    assert refused == [],
           "the named-type gate refuses shipped schemas:\n" <>
             Enum.map_join(refused, "\n", fn {f, m} -> "  #{f}: #{Enum.join(m, "; ")}" end)
  end

  test "portableDocument (search-starter templates) is a declared built-in type" do
    assert "portableDocument" in Schema.builtin_field_types()
  end
end
