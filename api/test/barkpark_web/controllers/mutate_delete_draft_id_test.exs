defmodule BarkparkWeb.MutateDeleteDraftIdTest do
  @moduledoc """
  task-47f8394f07b97f8b — a `delete` naming a `drafts.` id deletes ONLY that
  draft; the published row survives (Sanity semantics). Before, the id was
  widened to the whole pair, so dropping a draft deleted the published
  document too. A bare id keeps deleting both rows.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  @ds "test"

  setup do
    Barkpark.Auth.create_token(
      "barkpark-dev-token",
      "dev",
      "test",
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    Content.upsert_schema(
      %{"name" => "note", "title" => "Note", "visibility" => "public", "fields" => []},
      @ds
    )

    Content.upsert_schema(
      %{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => [%{"name" => "about", "type" => "reference", "to" => [%{"type" => "note"}]}]
      },
      @ds
    )

    :ok
  end

  # A published note with a draft edit over it.
  defp published_with_draft!(id) do
    {:ok, _} = Content.create_document("note", %{"doc_id" => id, "title" => "published"}, @ds)
    {:ok, _} = Content.publish_document(id, "note", @ds)

    {:ok, draft} =
      Content.create_document("note", %{"doc_id" => id, "title" => "draft edit"}, @ds)

    draft
  end

  defp mutate(deletes) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/mutate/#{@ds}",
      Jason.encode!(%{"mutations" => Enum.map(deletes, &%{"delete" => &1})})
    )
  end

  defp title(id) do
    case Content.get_document(id, "note", @ds) do
      {:ok, doc} -> doc.title
      _ -> nil
    end
  end

  test "drafts.X deletes only the draft; the published X survives" do
    published_with_draft!("n1")

    assert mutate([%{"id" => "drafts.n1", "type" => "note"}]).status == 200
    assert title("drafts.n1") == nil
    assert title("n1") == "published"
  end

  test "control: a bare id still deletes both rows" do
    published_with_draft!("n2")

    assert mutate([%{"id" => "n2", "type" => "note"}]).status == 200
    assert title("drafts.n2") == nil
    assert title("n2") == nil
  end

  test "ifRevisionID still guards a drafts. delete" do
    draft = published_with_draft!("n3")

    stale = mutate([%{"id" => "drafts.n3", "type" => "note", "ifRevisionID" => "not-the-rev"}])
    assert stale.status == 412
    assert Jason.decode!(stale.resp_body)["error"]["code"] == "precondition_failed"
    assert title("drafts.n3") == "draft edit"

    ok = mutate([%{"id" => "drafts.n3", "type" => "note", "ifRevisionID" => draft.rev}])
    assert ok.status == 200
    assert title("drafts.n3") == nil
    assert title("n3") == "published"
  end

  test "a draft-only document deleted by its drafts. id is gone" do
    {:ok, _} =
      Content.create_document("note", %{"doc_id" => "n4", "title" => "only a draft"}, @ds)

    assert mutate([%{"id" => "drafts.n4", "type" => "note"}]).status == 200
    assert title("drafts.n4") == nil
    assert title("n4") == nil
  end

  test "a referenced PUBLISHED doc does not block deleting its draft, alone or in a batch" do
    published_with_draft!("n5")
    published_with_draft!("n6")

    for id <- ["n5", "n6"] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{
            "doc_id" => "p-#{id}",
            "content" => %{"about" => %{"_type" => "reference", "_ref" => id}}
          },
          @ds
        )
    end

    assert mutate([%{"id" => "drafts.n5", "type" => "note"}]).status == 200
    assert title("n5") == "published"

    # Two consecutive deletes take the batched referrer path.
    {:ok, _} = Content.create_document("note", %{"doc_id" => "n5", "title" => "draft again"}, @ds)

    assert mutate([
             %{"id" => "drafts.n5", "type" => "note"},
             %{"id" => "drafts.n6", "type" => "note"}
           ]).status ==
             200

    assert {title("n5"), title("n6")} == {"published", "published"}
    assert {title("drafts.n5"), title("drafts.n6")} == {nil, nil}
  end

  test "a referenced draft-only doc is still refused 409 document_referenced" do
    {:ok, _} =
      Content.create_document("note", %{"doc_id" => "n7", "title" => "only a draft"}, @ds)

    {:ok, _} =
      Content.create_document(
        "post",
        %{
          "doc_id" => "p-n7",
          "content" => %{"about" => %{"_type" => "reference", "_ref" => "n7"}}
        },
        @ds
      )

    resp = mutate([%{"id" => "drafts.n7", "type" => "note"}])
    assert resp.status == 409
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "document_referenced"
    assert title("drafts.n7") == "only a draft"
  end
end
