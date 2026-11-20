defmodule BarkparkWeb.Contract.HistoryRestoreIfRevisionTest do
  @moduledoc """
  A history restore that names the state it was asked against (`ifRevisionID`,
  the same fence a `/v1` mutate patch takes) is refused when the document has
  moved on, and writes nothing (task-e89ff0279fb83fc6). A restore that names no
  state restores as before. Studio's row "a late restore after newer edits is
  refused and keeps them" (barkpark-studio, test/a012-restore-stuck) holds the
  same order from the browser.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    :ok
  end

  defp restore(conn, revision_id, body) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post(
      "/v1/data/revision/test/#{revision_id}/restore",
      Jason.encode!(Map.put(body, "type", "post"))
    )
  end

  defp rev_of(id) do
    {:ok, doc} = Content.get_document(id, "post", "test")
    doc.rev
  end

  defp title_of(id) do
    {:ok, doc} = Content.get_document(id, "post", "test")
    doc.title
  end

  defp revision_titled(doc_id, title) do
    Content.list_revisions(doc_id, "post", "test") |> Enum.find(&(&1.title == title))
  end

  # A draft written twice: "Words A" (the state the restore was asked against),
  # then "Words B" (the edit that lands first).
  defp edited_draft(doc_id) do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts.#{doc_id}", "title" => "Words A"},
        "test"
      )

    seen = rev_of("drafts.#{doc_id}")

    {:ok, _} =
      Content.upsert_document(
        "post",
        %{"doc_id" => "drafts.#{doc_id}", "title" => "Words B"},
        "test"
      )

    %{
      seen: seen,
      current: rev_of("drafts.#{doc_id}"),
      revision: revision_titled(doc_id, "Words A")
    }
  end

  test "the late order: a restore asked against an older state, after an edit, is refused and the newer words stay",
       %{conn: conn} do
    %{seen: seen, current: current, revision: revision} = edited_draft("late")
    assert revision
    before = length(Content.list_revisions("late", "post", "test"))

    resp = restore(conn, revision.id, %{"ifRevisionID" => seen})

    assert resp.status == 412
    error = Jason.decode!(resp.resp_body)["error"]
    assert error["code"] == "precondition_failed"
    assert error["details"]["expected"] == seen
    assert error["details"]["actual"] == current
    assert title_of("drafts.late") == "Words B"
    assert rev_of("drafts.late") == current
    assert length(Content.list_revisions("late", "post", "test")) == before,
           "no revision was written"
  end

  test "a restore naming the current state restores", %{conn: conn} do
    %{current: current, revision: revision} = edited_draft("current")

    resp = restore(conn, revision.id, %{"ifRevisionID" => current})

    assert resp.status == 200
    assert Jason.decode!(resp.resp_body)["restored"] == true
    assert title_of("drafts.current") == "Words A"
  end

  test "a restore naming no state restores as before", %{conn: conn} do
    %{revision: revision} = edited_draft("unnamed")

    resp = restore(conn, revision.id, %{})

    assert resp.status == 200
    assert title_of("drafts.unnamed") == "Words A"
  end

  test "a published-only document: the named state is the published row's", %{conn: conn} do
    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "drafts.pub", "title" => "Words A"}, "test")

    draft_rev = rev_of("drafts.pub")
    {:ok, _} = Content.publish_document("pub", "post", "test")
    assert {:error, :not_found} = Content.get_document("drafts.pub", "post", "test")
    published = rev_of("pub")
    revision = revision_titled("pub", "Words A")

    stale = restore(conn, revision.id, %{"ifRevisionID" => draft_rev})
    assert stale.status == 412
    assert Jason.decode!(stale.resp_body)["error"]["details"]["actual"] == published
    assert match?({:error, :not_found}, Content.get_document("drafts.pub", "post", "test")),
           "no draft was written"

    fresh = restore(conn, revision.id, %{"ifRevisionID" => published})
    assert fresh.status == 200
    assert title_of("drafts.pub") == "Words A"
  end
end
