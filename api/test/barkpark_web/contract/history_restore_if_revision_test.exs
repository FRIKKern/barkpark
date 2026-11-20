defmodule BarkparkWeb.Contract.HistoryRestoreIfRevisionTest do
  @moduledoc """
  A history restore that names the state it was asked against is refused when
  the document has moved on, and writes nothing (task-e89ff0279fb83fc6). The
  state is `ifRevisionID` ("I saw this rev", the same fence a `/v1` mutate patch
  takes) or `ifAbsent: true` ("I saw no document"); naming both is a 400. A
  restore that names no state restores as before. Studio's row "a late restore after newer edits is
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

  # A document written once, then deleted: the state the restore was asked against
  # is gone.
  defp deleted_draft(doc_id) do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts.#{doc_id}", "title" => "Words A"},
        "test"
      )

    seen = rev_of("drafts.#{doc_id}")
    revision = revision_titled(doc_id, "Words A")
    {:ok, _} = Content.delete_document("drafts.#{doc_id}", "post", "test")
    %{seen: seen, revision: revision}
  end

  test "a deleted document: a restore naming the state before the delete is refused, and no draft is born",
       %{conn: conn} do
    %{seen: seen, revision: revision} = deleted_draft("gone")

    resp = restore(conn, revision.id, %{"ifRevisionID" => seen})

    assert resp.status == 412
    assert Jason.decode!(resp.resp_body)["error"]["details"]["actual"] == nil

    assert match?({:error, :not_found}, Content.get_document("drafts.gone", "post", "test")),
           "no draft was born"

    assert match?({:error, :not_found}, Content.get_document("gone", "post", "test")),
           "no published row was written"
  end

  test "a deleted document: a restore naming no state brings it back, as before", %{conn: conn} do
    %{revision: revision} = deleted_draft("back")

    resp = restore(conn, revision.id, %{})

    assert resp.status == 200
    assert title_of("drafts.back") == "Words A"
  end

  test "ifAbsent on a document still deleted: the restore lands", %{conn: conn} do
    %{revision: revision} = deleted_draft("absent")

    resp = restore(conn, revision.id, %{"ifAbsent" => true})

    assert resp.status == 200
    assert title_of("drafts.absent") == "Words A"
  end

  test "ifAbsent on a document made again since: refused, and the new document stays",
       %{conn: conn} do
    %{revision: revision} = deleted_draft("again")

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "drafts.again", "title" => "Words N"}, "test")

    current = rev_of("drafts.again")

    resp = restore(conn, revision.id, %{"ifAbsent" => true})

    assert resp.status == 412
    details = Jason.decode!(resp.resp_body)["error"]["details"]
    assert details["expected"] == nil
    assert details["actual"] == current
    assert title_of("drafts.again") == "Words N"
    assert rev_of("drafts.again") == current
  end

  test "the late order in Studio's shape: a late restore after a restore and newer edits is refused and keeps them",
       %{conn: conn} do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts.studio", "title" => "Words A"},
        "test"
      )

    {:ok, _} =
      Content.upsert_document(
        "post",
        %{"doc_id" => "drafts.studio", "title" => "Words B"},
        "test"
      )

    first = revision_titled("studio", "Words A")
    second = revision_titled("studio", "Words B")
    {:ok, _} = Content.delete_document("drafts.studio", "post", "test")

    assert restore(conn, second.id, %{"ifAbsent" => true}).status == 200

    {:ok, _} =
      Content.upsert_document(
        "post",
        %{"doc_id" => "drafts.studio", "title" => "Words C"},
        "test"
      )

    edited = rev_of("drafts.studio")

    late = restore(conn, first.id, %{"ifAbsent" => true})

    assert late.status == 412
    assert Jason.decode!(late.resp_body)["error"]["details"]["actual"] == edited
    assert title_of("drafts.studio") == "Words C"
    assert rev_of("drafts.studio") == edited
  end

  test "naming both ifRevisionID and ifAbsent is a 400, and nothing is written", %{conn: conn} do
    %{current: current, revision: revision} = edited_draft("both")

    resp = restore(conn, revision.id, %{"ifRevisionID" => current, "ifAbsent" => true})

    assert resp.status == 400
    assert Jason.decode!(resp.resp_body)["error"]["code"] == "malformed"
    assert title_of("drafts.both") == "Words B"
    assert rev_of("drafts.both") == current
  end

  # Two ifAbsent restores of one deleted document, driven by order: the second
  # (over HTTP) has passed its compare when the first (`Content.restore_revision`
  # with `if_absent: true`) runs and lands, at the named seam of the second's
  # write (`Content.InsertOnly`). Whichever step the first lands before, the
  # second is refused 412 and the first one's words stay.
  defp race_at(conn, doc_id, site) do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts.#{doc_id}", "title" => "Words A"},
        "test"
      )

    {:ok, _} =
      Content.upsert_document(
        "post",
        %{"doc_id" => "drafts.#{doc_id}", "title" => "Words B"},
        "test"
      )

    first = revision_titled(doc_id, "Words B")
    second = revision_titled(doc_id, "Words A")
    {:ok, _} = Content.delete_document("drafts.#{doc_id}", "post", "test")

    on_exit(fn -> Application.delete_env(:barkpark, :writer_fault) end)

    Application.put_env(
      :barkpark,
      :writer_fault,
      {site,
       fn ->
         Application.delete_env(:barkpark, :writer_fault)

         Process.put(
           :first_restore,
           Content.restore_revision(first.id, "post", "test", if_absent: true)
         )
       end}
    )

    resp = restore(conn, second.id, %{"ifAbsent" => true})
    assert {:ok, _} = Process.get(:first_restore)
    {resp, rev_of("drafts.#{doc_id}")}
  end

  defp assert_second_refused({resp, landed}, doc_id) do
    assert resp.status == 412
    details = Jason.decode!(resp.resp_body)["error"]["details"]
    assert details["expected"] == nil
    assert details["actual"] == landed
    assert title_of("drafts.#{doc_id}") == "Words B"
    assert rev_of("drafts.#{doc_id}") == landed
  end

  test "two ifAbsent restores: the first lands after the second's compare, before its writer reads",
       %{conn: conn} do
    race_at(conn, "race-read", :restore_after_state_check) |> assert_second_refused("race-read")
  end

  test "two ifAbsent restores: the first lands after the second's writer read, before its insert",
       %{conn: conn} do
    race_at(conn, "race-lock", :insert_only_before_lock) |> assert_second_refused("race-lock")
  end

  test "two ifAbsent restores: the first lands after the second's last read, so its insert hits the unique id",
       %{conn: conn} do
    result = race_at(conn, "race-unique", :insert_only_before_insert)
    {:ok, row} = Content.get_document("drafts.race-unique", "post", "test")
    assert is_binary(row.dataset_id), "the unique index needs a dataset_id to fire"
    assert_second_refused(result, "race-unique")
  end
end
