defmodule BarkparkWeb.GroqPerspectiveStackTest do
  # task-acbe59f8b19baaf2: a perspective stack (`perspective=rX,drafts`, what @sanity/client
  # sends for ['rX', 'drafts']) reads as Sanity reads an unknown release: it adds nothing.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "persp_ds"
  @path "/w/persp-ws/p/site/v2025-02-19/data/query/#{@dataset}"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "persp-ws", name: "Perspectives"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    for id <- ["p1", "p2"] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => id, "content" => %{"title" => id}},
          @dataset,
          scope
        )

      {:ok, _} = Content.publish_document(id, "post", @dataset, scope)
    end

    # A draft-only post: drafts counts 3, published 2.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "p3", "content" => %{"title" => "p3"}},
        @dataset,
        scope
      )

    token = "persp-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "persp", @dataset, ["read", "write"], ws.id)
    %{token: token}
  end

  defp count(token, perspective) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get(@path, %{"query" => ~s|count(*[_type == "post"])|, "perspective" => perspective})
  end

  test "a stack reads as its drafts or published base; release ids add nothing", %{token: token} do
    assert json_response(count(token, "drafts"), 200)["result"] == 3
    assert json_response(count(token, "published"), 200)["result"] == 2

    for {stack, expected} <- [
          {"rNoSuch,drafts", 3},
          {"rA,rB,drafts", 3},
          {"drafts,rNoSuch", 3},
          {"rNoSuch,previewDrafts", 3},
          {"rNoSuch,published", 2},
          {["rNoSuch", "drafts"], 3}
        ] do
      assert json_response(count(token, stack), 200)["result"] == expected, inspect(stack)
    end
  end

  # A lone unknown value stays refused (Sanity would read it as a release): it is
  # how a typo like `drafst` is caught instead of silently reading published.
  test "raw cannot be stacked; a malformed member or a lone unknown value is refused", %{
    token: token
  } do
    for stack <- ["rNoSuch,raw", "rNoSuch,,drafts", "r x,drafts", "rNoSuch", "drafst"] do
      body = json_response(count(token, stack), 400)
      assert body["error"]["details"]["parameter"] == "perspective", stack
    end
  end
end
