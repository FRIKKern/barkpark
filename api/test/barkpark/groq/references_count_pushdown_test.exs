defmodule Barkpark.Groq.ReferencesCountPushdownTest do
  @moduledoc """
  task-2094ccab724a05b2: `count(*[_type == T && references($id)])` is counted
  in SQL, without loading the matches, and gives the evaluator's answer: the
  same perspective (a draft-only match, a draft that drops the link), the same
  readers (a type the caller may not read, a field it may not see), and the
  same link shapes (`_ref`, a bare declared reference, a wikilink by `docId`,
  else `target`). A shape SQL cannot judge (a reference inside a reference)
  is counted by the evaluator.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.{Content, Groq, TenancyFixtures}
  alias Barkpark.Content.CallerContext

  @ds "refs-count"
  @id "author-1"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    token = scope ++ [caller_context: %CallerContext{principal_type: :api_token, token_id: "t"}]

    schema!(scope, "post", "public", [
      %{"name" => "title", "type" => "string"},
      %{"name" => "author", "type" => "reference", "refType" => "author"},
      %{"name" => "body", "type" => "json"},
      %{"name" => "note", "type" => "string"}
    ])

    schema!(scope, "memo", "private", [%{"name" => "author", "type" => "reference"}])

    schema!(scope, "hush", "public", [
      %{"name" => "title", "type" => "string"},
      %{"name" => "secret", "type" => "json", "visibility" => "owner_only"}
    ])

    link = fn fields ->
      %{
        "blocks" => [%{"type" => "paragraph", "content" => [Map.put(fields, "type", "wikilink")]}]
      }
    end

    published!(scope, "post", "p-ref", %{"author" => %{"_type" => "reference", "_ref" => @id}})
    published!(scope, "post", "p-bare", %{"author" => @id})
    published!(scope, "post", "p-docid", %{"body" => link.(%{"docId" => @id, "target" => "x"})})
    published!(scope, "post", "p-target", %{"body" => link.(%{"target" => @id})})

    published!(scope, "post", "p-other-docid", %{
      "body" => link.(%{"docId" => "x", "target" => @id})
    })

    published!(scope, "post", "p-undeclared", %{"note" => @id})
    published!(scope, "post", "p-none", %{"title" => "no link"})
    # Published with the link; its draft drops it.
    published!(scope, "post", "p-dropped", %{"author" => @id})
    draft!(scope, "post", "p-dropped", %{"title" => "unlinked"})
    # A draft only.
    draft!(scope, "post", "p-draft", %{"author" => %{"_ref" => @id}})

    published!(scope, "memo", "m-1", %{"author" => @id})
    published!(scope, "hush", "h-1", %{"secret" => %{"_ref" => @id}})

    %{scope: scope, token: token}
  end

  defp schema!(scope, name, visibility, fields) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => name, "title" => name, "visibility" => visibility, "fields" => fields},
        @ds,
        scope
      )
  end

  defp draft!(scope, type, id, content) do
    {:ok, _} = Content.create_document(type, %{"doc_id" => id, "content" => content}, @ds, scope)
  end

  defp published!(scope, type, id, content) do
    draft!(scope, type, id, content)
    {:ok, _} = Content.publish_document(id, type, @ds, scope)
  end

  defp groq(query, perspective, scope_opts) do
    {:ok, %{result_json: json}} =
      Groq.query(query, %{"id" => @id},
        dataset: @ds,
        perspective: perspective,
        scope_opts: scope_opts
      )

    json |> IO.iodata_to_binary() |> Jason.decode!()
  end

  # The SQL each query ran, from the repo's telemetry.
  defp sql(fun) do
    me = self()
    ref = make_ref()

    :telemetry.attach(
      {__MODULE__, ref},
      [:barkpark, :repo, :query],
      fn _event, _m, meta, _ -> send(me, {ref, meta.query}) end,
      nil
    )

    result = fun.()
    :telemetry.detach({__MODULE__, ref})
    {result, collect(ref, [])}
  end

  defp collect(ref, acc) do
    receive do
      {^ref, q} -> collect(ref, [q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp loads_documents?(queries), do: Enum.any?(queries, &(&1 =~ ~s(SELECT d0."id", d0."doc_id")))

  defp count_and_list(type, perspective, scope_opts) do
    {count, queries} =
      sql(fn ->
        groq(~s|count(*[_type == "#{type}" && references($id)])|, perspective, scope_opts)
      end)

    ids = groq(~s|*[_type == "#{type}" && references($id)]._id|, perspective, scope_opts)
    {count, Enum.sort(ids), queries}
  end

  test "SQL counts what the evaluator keeps, in every perspective", %{token: token} do
    expected = %{
      published: ~w(p-bare p-docid p-dropped p-ref p-target),
      drafts: ~w(p-bare p-docid p-draft p-ref p-target),
      raw: ~w(drafts.p-draft p-bare p-docid p-dropped p-ref p-target)
    }

    for {perspective, ids} <- expected do
      {count, listed, queries} = count_and_list("post", perspective, token)
      assert listed == ids, "#{perspective}: #{inspect(listed)}"
      assert count == length(ids), "#{perspective}: count #{count}, evaluator #{length(listed)}"
      refute loads_documents?(queries), "#{perspective}: the count loaded documents"
    end
  end

  test "a type or field the caller may not read is left out as the evaluator leaves it", %{
    scope: anonymous,
    token: token
  } do
    assert {1, ["m-1"], _} = count_and_list("memo", :published, token)
    assert {0, [], _} = count_and_list("memo", :published, anonymous)

    # A field only its owner sees: SQL would see the link, so the evaluator counts.
    {count, listed, queries} = count_and_list("hush", :published, token)
    assert count == length(listed)
    assert loads_documents?(queries)
  end

  test "a reference inside a reference is left to the evaluator", %{scope: scope, token: token} do
    published!(scope, "post", "p-nested", %{
      "author" => %{"_ref" => "someone-else", "meta" => %{"_ref" => @id}}
    })

    {count, listed, queries} = count_and_list("post", :published, token)
    refute "p-nested" in listed
    assert count == length(listed)
    assert loads_documents?(queries)
  end
end
