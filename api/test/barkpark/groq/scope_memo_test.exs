defmodule Barkpark.Groq.ScopeMemoTest do
  # With the request memo on (an HTTP request's scope opts carry `memoize: true`), a GROQ
  # query asks for the visible types once, not once per read (run-perf, 26 Oct).
  # A non-admin caller still sees only public types and readable fields, as with it off.
  use Barkpark.DataCase, async: true

  alias Barkpark.{Content, Groq, TenancyFixtures}
  alias Barkpark.Content.{CallerContext, WriteScope}

  @ds "scope-memo"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for {name, visibility, fields} <- [
          {"post", "public",
           [
             %{"name" => "title", "type" => "string"},
             %{"name" => "secret", "type" => "string", "private" => true},
             %{"name" => "author", "type" => "reference", "refType" => "author"}
           ]},
          {"author", "public", [%{"name" => "name", "type" => "string"}]},
          {"memo", "private", [%{"name" => "title", "type" => "string"}]}
        ] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => name, "title" => name, "visibility" => visibility, "fields" => fields},
          @ds,
          scope
        )
    end

    for {type, id, content} <-
          [{"author", "a1", %{"name" => "Ada"}}, {"memo", "m1", %{"title" => "Internal memo"}}] ++
            for(
              i <- 1..4,
              do:
                {"post", "p#{i}",
                 %{"title" => "Post #{i}", "secret" => "s#{i}", "author" => "a1"}}
            ) do
      {:ok, _} =
        Content.create_document(type, %{"doc_id" => id, "content" => content}, @ds, scope)

      {:ok, _} = Content.publish_document(id, type, @ds, scope)
    end

    WriteScope.reset_request_memo()
    on_exit(&WriteScope.reset_request_memo/0)
    %{scope: scope}
  end

  # The query as an anonymous HTTP caller sends it, with the memo on or off.
  defp groq(q, scope, memo?) do
    WriteScope.reset_request_memo()

    opts =
      scope ++
        [caller_context: CallerContext.anonymous()] ++ if(memo?, do: [memoize: true], else: [])

    {:ok, %{result_json: json}} =
      Groq.query(q, %{}, dataset: @ds, perspective: :published, scope_opts: opts)

    json |> IO.iodata_to_binary() |> Jason.decode!()
  end

  @queries [
    ~s'*[]{_type, _id, title, secret} | order(_id)',
    ~s'*[_type == "memo"]',
    ~s'count(*)',
    ~s'*[_type == "post"] | order(_id)[0...3]{title, secret, author->{name}, "same": *[_id == ^._id][0]._id}'
  ]

  test "a non-admin caller sees only public types and readable fields, memo on as off", %{
    scope: scope
  } do
    for q <- @queries, do: assert(groq(q, scope, true) == groq(q, scope, false), q)

    all = groq(hd(@queries), scope, true)
    assert Enum.map(all, & &1["_type"]) |> Enum.uniq() |> Enum.sort() == ["author", "post"]
    assert Enum.all?(all, &is_nil(&1["secret"]))
    assert groq(~s'*[_type == "memo"]', scope, true) == []
  end

  test "the memo reads the visible types once per query", %{scope: scope} do
    q = List.last(@queries)
    off = schema_reads(fn -> groq(q, scope, false) end)
    on = schema_reads(fn -> groq(q, scope, true) end)

    # Measured 26 Oct: 9 reads with the memo off; with it on, 4 while the visible-types
    # list was read again on every read of the query, 1 since.
    assert on < off, "memo on #{on}, off #{off}"
    assert on <= 2, "memo on read schemas/datasets #{on} times"
  end

  defp schema_reads(fun) do
    me = self()
    id = "scope-memo-#{System.unique_integer()}"

    :telemetry.attach(
      id,
      [:barkpark, :repo, :query],
      fn _, _, meta, _ -> send(me, {:sql, meta.query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    count(0)
  end

  defp count(n) do
    receive do
      {:sql, q} -> count(if(q =~ ~r/FROM "(schemas|datasets)"/, do: n + 1, else: n))
    after
      0 -> n
    end
  end
end
