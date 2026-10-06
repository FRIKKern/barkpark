defmodule BarkparkWeb.MutateUnpublishKeepsDraftTest do
  # Unpublish keeps an existing draft (orchestrator ruling on
  # task-02e8a5799d4f35e8: draft wins, as in Sanity). It used to overwrite
  # `drafts.<id>` with the published content, so unpublishing a document with
  # unpublished draft edits silently destroyed them.
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, TenancyFixtures}

  @dataset "test"
  @token "unpublish-keeps-draft-token"

  setup do
    {ws, proj} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: proj.id]
    Auth.create_token(@token, "w", @dataset, ["read", "write"], ws.id)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "body", "title" => "Body", "type" => "text"}]
        },
        @dataset,
        scope
      )

    {:ok, scope: scope}
  end

  defp published!(scope, body) do
    id = "unpub-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => id, "title" => "Published title", "content" => %{"body" => body}},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(id, "post", @dataset, scope)
    id
  end

  defp unpublish(id) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{"mutations" => [%{"unpublish" => %{"id" => id, "type" => "post"}}]})
    )
  end

  test "an existing draft keeps its edits and only the published row goes", %{scope: scope} do
    id = published!(scope, "published body")

    {:ok, draft} =
      Content.upsert_document(
        "post",
        %{
          "doc_id" => "drafts." <> id,
          "title" => "Draft title",
          "content" => %{"body" => "unpublished edit"}
        },
        @dataset,
        scope
      )

    resp = unpublish(id)
    assert resp.status == 200, resp.resp_body

    assert {:error, :not_found} = Content.get_document(id, "post", @dataset, scope)
    {:ok, kept} = Content.get_document("drafts." <> id, "post", @dataset, scope)
    assert kept.content["body"] == "unpublished edit"
    assert kept.title == "Draft title"
    assert kept.rev == draft.rev

    [result] = Jason.decode!(resp.resp_body)["results"]
    assert result["id"] == "drafts." <> id
    assert result["operation"] == "unpublish"
  end

  test "with no draft, unpublish creates one from the published content", %{scope: scope} do
    id = published!(scope, "published body")
    assert {:error, :not_found} = Content.get_document("drafts." <> id, "post", @dataset, scope)

    resp = unpublish(id)
    assert resp.status == 200, resp.resp_body

    assert {:error, :not_found} = Content.get_document(id, "post", @dataset, scope)
    {:ok, draft} = Content.get_document("drafts." <> id, "post", @dataset, scope)
    assert draft.content["body"] == "published body"
    assert draft.title == "Published title"
  end
end
