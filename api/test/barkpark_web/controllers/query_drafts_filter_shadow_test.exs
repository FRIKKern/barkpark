defmodule BarkparkWeb.QueryDraftsFilterShadowTest do
  @moduledoc """
  `GET /v1/data/query/:dataset/:type?perspective=drafts&filter[...]` judges
  the filter on the document that perspective shows: the draft when there is
  one, else the published row (task-85c4dccf2382c55b).

  Before, a published row whose draft no longer matched came back as the hit
  (`_draft: false`), so a filtered Studio list showed a document under a value
  its draft no longer has. `Barkpark.Content.Query.DraftShadow` drops that row
  in SQL, so the page, `total` and `hasMore` agree.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "production"
  @token "barkpark-test-drafts-filter-shadow"

  setup do
    Barkpark.LabelFixtures.register_tags!(@dataset)
    {:ok, _} = Auth.create_token(@token, "drafts-filter-shadow", @dataset, ["read", "write"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    # Authors unique to this test, so other tests' posts never match.
    n = System.unique_integer([:positive])
    ada = "author-ada-#{n}"
    alan = "author-alan-#{n}"

    put = fn id, author ->
      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => id, "title" => id, "content" => %{"author" => author}},
          @dataset,
          scope
        )
    end

    publish = fn id -> {:ok, _} = Content.publish_document(id, "post", @dataset, scope) end

    # a, c: published as ada, no draft. b: published as ada, its draft says alan.
    [a, b, c] = for k <- ~w(a b c), do: "shadow-#{n}-#{k}"

    for id <- [a, b, c] do
      put.(id, ada)
      publish.(id)
    end

    put.(b, alan)

    %{a: a, b: b, c: c, ada: ada, alan: alan}
  end

  defp list(conn, params) do
    conn
    |> get("/v1/data/query/#{@dataset}/post", Map.put(params, "order", "_id:asc"))
    |> json_response(200)
    |> Map.fetch!("result")
  end

  defp as_editor(conn), do: put_req_header(conn, "authorization", "Bearer " <> @token)

  defp ids(result), do: Enum.map(result["documents"], & &1["_id"])

  test "a published row whose draft no longer matches is not a hit", ctx do
    result =
      ctx.conn
      |> as_editor()
      |> list(%{"perspective" => "drafts", "filter[author][in]" => ctx.ada})

    assert ids(result) == [ctx.a, ctx.c]
  end

  test "a draft that matches is the hit; a document with no draft is judged as published", ctx do
    editor = as_editor(ctx.conn)

    assert [%{"_draft" => true, "author" => alan} = hit] =
             list(editor, %{"perspective" => "drafts", "filter[author]" => ctx.alan})["documents"]

    assert hit["_id"] == "drafts." <> ctx.b
    assert alan == ctx.alan

    # `neq` reads the draft too: b's draft is not ada, a and c are.
    assert ids(list(editor, %{"perspective" => "drafts", "filter[author][neq]" => ctx.ada})) ==
             ["drafts." <> ctx.b]
  end

  test "total and pages count the shadowed row out", ctx do
    editor = as_editor(ctx.conn)
    params = %{"perspective" => "drafts", "filter[author]" => ctx.ada, "count" => "true"}

    first = list(editor, Map.merge(params, %{"limit" => "1"}))
    second = list(editor, Map.merge(params, %{"limit" => "1", "offset" => "1"}))

    assert first["total"] == 2
    assert {ids(first), first["hasMore"]} == {[ctx.a], true}
    assert {ids(second), second["hasMore"]} == {[ctx.c], false}
  end

  test "published reads, and a caller pinned to published, still get the published row", ctx do
    params = %{"filter[author]" => ctx.ada, "count" => "true"}
    all = [ctx.a, ctx.b, ctx.c]

    published = ctx.conn |> as_editor() |> list(Map.put(params, "perspective", "published"))
    assert {ids(published), published["total"]} == {all, 3}

    # No token: pinned to published whatever it asks for, so the draft of b
    # must change nothing it can see.
    anonymous = list(ctx.conn, Map.put(params, "perspective", "drafts"))
    assert {ids(anonymous), anonymous["total"]} == {all, 3}
    assert Enum.all?(anonymous["documents"], &(&1["_draft"] == false))

    assert list(ctx.conn, %{"perspective" => "drafts", "filter[author]" => ctx.alan})["documents"] ==
             []
  end
end
