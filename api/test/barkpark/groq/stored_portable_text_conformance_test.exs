defmodule Barkpark.Groq.StoredPortableTextConformanceTest do
  @moduledoc """
  GROQ on Portable Text stored in a richText field answers as groq-js does.

  The documents in groq_conformance_docs.json are made up. Each case in
  groq_conformance_cases.json is a query and the answer groq-js gives on the
  same documents; groq_conformance_gen.mjs writes that file. The documents are
  stored and published through Content, then queried through Groq.query, and
  the same query runs on the in-memory source.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Groq, TenancyFixtures}
  alias Barkpark.Groq.{Evaluator, MemorySource, Parser}

  @ds "pt-groq-conformance"
  @docs_path "test/fixtures/portable_text/groq_conformance_docs.json"
  @cases_path "test/fixtures/portable_text/groq_conformance_cases.json"
  @external_resource @docs_path
  @external_resource @cases_path

  @docs @docs_path |> File.read!() |> Jason.decode!() |> Map.fetch!("documents")
  @cases @cases_path |> File.read!() |> Jason.decode!() |> Map.fetch!("cases")

  @schemas [
    {"ptpage", [%{"name" => "title", "type" => "string"}]},
    {"ptarticle",
     [
       %{"name" => "title", "type" => "string"},
       %{"name" => "body", "type" => "richText"}
     ]}
  ]

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for {name, fields} <- @schemas do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
          @ds,
          scope
        )
    end

    for %{"_id" => id, "_type" => type} = doc <- @docs do
      content = Map.drop(doc, ["_id", "_type"])

      {:ok, _} =
        Content.create_document(type, %{"doc_id" => id, "content" => content}, @ds, scope)

      {:ok, _} = Content.publish_document(id, type, @ds, scope)
    end

    %{scope: scope}
  end

  defp stored(q, scope) do
    {:ok, %{result_json: json}} =
      Groq.query(q, %{}, dataset: @ds, perspective: :published, scope_opts: scope)

    json |> IO.iodata_to_binary() |> Jason.decode!() |> drop_system_fields()
  end

  # A stored document carries _createdAt, _updatedAt and _rev, as a Sanity
  # document does. The groq-js dataset has none, so a dereferenced document
  # is compared without them.
  defp drop_system_fields(%{"_id" => _} = doc),
    do:
      doc
      |> Map.drop(["_createdAt", "_updatedAt", "_rev"])
      |> Map.new(fn {k, v} -> {k, drop_system_fields(v)} end)

  defp drop_system_fields(%{} = map),
    do: Map.new(map, fn {k, v} -> {k, drop_system_fields(v)} end)

  defp drop_system_fields(list) when is_list(list), do: Enum.map(list, &drop_system_fields/1)
  defp drop_system_fields(other), do: other

  defp in_memory(q) do
    {:ok, tree} = Parser.parse(q, %{})
    {:ok, value} = Evaluator.evaluate(tree, source: MemorySource.new(@docs))
    value
  end

  test "the body is stored as the Portable Text array it was given", %{scope: scope} do
    [article] = Enum.filter(@docs, &(&1["_id"] == "article-1"))
    assert stored(~s'*[_id == "article-1"][0].body', scope) == article["body"]
  end

  for %{"name" => name, "query" => query, "expected" => expected} <- @cases do
    @query query
    @expected expected

    test "#{name}: #{query}", %{scope: scope} do
      assert stored(@query, scope) == @expected
      assert in_memory(@query) == @expected
    end
  end

  describe "body[].markDefs[] on a body with blocks that have no markDefs" do
    # groq-js flattens with `[]` by spreading arrays and keeping any other
    # value. A custom block and a block with no markDefs key read markDefs as
    # null, so each one adds a null to the flattened list. Sanity's query API
    # answers the same on 2026-10-28, and so does Barkpark. Filtering to blocks
    # with markDefs drops the nulls.
    test "keeps a null for each block whose markDefs is missing", %{scope: scope} do
      keys = stored(~s'*[_id == "article-1"][0].body[].markDefs[]._key', scope)
      assert keys == ["m1", "m2", nil, "m3", nil]
    end

    test "defined(markDefs) drops them", %{scope: scope} do
      keys = stored(~s'*[_id == "article-1"][0].body[defined(markDefs)].markDefs[]._key', scope)
      assert keys == ["m1", "m2", "m3"]
    end
  end

  # groq-js 2.0.1 keeps every null in array::unique. The GROQ test suite
  # (function/array-unique.yml, "Mix of types" and "Non-existent attribute")
  # keeps one, as do Sanity's query API and Barkpark. This case follows the
  # suite, not groq-js.
  test "array::unique keeps one null, as the GROQ test suite does", %{scope: scope} do
    q = ~s'array::unique(*[_id == "article-1"][0].body[].children[].marks[])'
    expected = ["strong", "em", "m1", "m2", nil, "m3"]

    assert stored(q, scope) == expected
    assert in_memory(q) == expected
  end
end
