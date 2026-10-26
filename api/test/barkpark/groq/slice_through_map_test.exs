defmodule Barkpark.Groq.SliceThroughMapTest do
  # A slice or [n] after a projection (`*[...]{...}[0...3]`) reads only the rows it needs:
  # the source slices first, then the projection maps the kept documents. The answer is the
  # in-memory evaluation's in every case, including the ones the rewrite must leave alone.
  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Groq, TenancyFixtures}
  alias Barkpark.Groq.{Evaluator, MemorySource, Parser}

  @ds "slice-map"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for {name, fields} <- [
          {"author", [%{"name" => "name", "type" => "string"}]},
          {"post",
           [
             %{"name" => "title", "type" => "string"},
             %{"name" => "author", "type" => "reference", "refType" => "author"}
           ]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => name, "title" => name, "visibility" => "public", "fields" => fields},
          @ds,
          scope
        )
    end

    for {type, id, content} <-
          [{"author", "a1", %{"name" => "Ada"}}, {"author", "a2", %{"name" => "Alan"}}] ++
            for(
              i <- 1..9,
              do:
                {"post", "p#{i}",
                 %{
                   "title" => "Post #{rem(i * 7, 10)}",
                   "author" => %{"_type" => "reference", "_ref" => "a#{rem(i, 2) + 1}"}
                 }}
            ) do
      {:ok, _} =
        Content.create_document(type, %{"doc_id" => id, "content" => content}, @ds, scope)

      {:ok, _} = Content.publish_document(id, type, @ds, scope)
    end

    %{scope: scope}
  end

  defp groq(q, scope) do
    {:ok, %{result_json: json}} =
      Groq.query(q, %{}, dataset: @ds, perspective: :published, scope_opts: scope)

    json |> IO.iodata_to_binary() |> Jason.decode!()
  end

  defp in_memory(docs, q) do
    {:ok, tree} = Parser.parse(q, %{})
    {:ok, value} = Evaluator.evaluate(tree, source: MemorySource.new(docs))
    value
  end

  @shapes [
    # rewritten: the source slices, the projection maps what it kept
    ~s'*[_type == "post"]{_id, title}[0...3]',
    ~s'*[_type == "post"]{_id}[4]',
    ~s'*[_type == "post"]{_id}[40]',
    ~s'*[_type == "post"] | order(title desc){_id, title}[1...4]',
    # still element by element inside the map: ^, a spread, a deref
    ~s'*[_type == "post"]{_id, "same": *[_type == "post" && _id == ^._id][0]._id}[0...3]',
    ~s'*[_type == "post"]{..., "n": 1}[0...2]',
    ~s'*[_type == "post"]{_id, "by": author->name}[2...5]',
    # left alone: order() after the projection is not a map, a negative slice needs the length
    ~s'*[_type == "post"]{_id, title} | order(title desc)[0...3]',
    ~s'*[_type == "post"]{_id}[-5..-1]',
    ~s'*[_type == "post"]{_id}[3..-1]',
    ~s'*[_type == "post"]{_id}[-1]'
  ]

  test "every shape equals in-memory evaluation", %{scope: scope} do
    docs = groq(~s'*', scope)

    for q <- @shapes do
      assert groq(q, scope) == in_memory(docs, q), q
    end
  end

  test "a projection before the slice reads only the rows the slice needs", %{scope: scope} do
    me = self()
    id = "slice-map-#{System.unique_integer()}"

    :telemetry.attach(
      id,
      [:barkpark, :repo, :query],
      fn _, _, meta, _ -> send(me, {:sql, meta.query}) end,
      nil
    )

    try do
      assert [_, _] = groq(~s'*[_type == "post"]{_id, title}[0...2]', scope)
    after
      :telemetry.detach(id)
    end

    reads =
      for {:sql, q} <- collect([]), q =~ ~r/FROM "documents"/ and q =~ "pg_column_size", do: q

    assert reads != [] and Enum.all?(reads, &(&1 =~ ~r/LIMIT \$\d+ OFFSET \$\d+/)),
           Enum.join(reads, "\n")
  end

  defp collect(acc) do
    receive do
      msg -> collect([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
