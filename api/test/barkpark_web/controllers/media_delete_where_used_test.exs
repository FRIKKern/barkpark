defmodule BarkparkWeb.MediaDeleteWhereUsedTest do
  @moduledoc """
  A media delete must not answer 200 while blanking a published page
  (pe-w2-bl-media-delete-where-used).

  THE SILENCE: papers embed self-hosted media as a RAW `/media/files/<path>` URL
  STRING inside their block JSON. No reference graph can see that —
  `Media.Storage.Relations.graph/3` (the `bp media relations` where-used API)
  walks `mediaAsset` <-> `mediaAsset` edges only. So both delete doors called
  `Media.delete_file/2` — which removes the row, the blob, the renditions and the
  CDN copy irreversibly — with no usage lookup at all, and handed back a clean
  receipt. The author learns nothing; a reader finds a hole in a live page,
  possibly weeks later.

  Two doors, and a fix that lands on one is exactly the failure this file exists
  to catch:

    * `DELETE /v1/media/:dataset/:id`  V1.MediaController.delete/2
    * `DELETE /media/:id`              MediaController.delete/2

  THE DIFFERENTIAL: each refusal arm asserts the file ROW SURVIVES in the store
  (`Repo.get(MediaFile, id) != nil`), not merely that a status was 409. Restore
  the silent behaviour and the row is gone — a status-only assertion would still
  be satisfiable by an unrelated 409, and a `refute status == 200` would pass
  vacuously on any error at all.

  The NEGATIVE arms are load-bearing in the other direction: an unreferenced blob
  must still delete (or the guard has bricked the feature), and `?force=true`
  must still delete (or an operator with a genuinely dead reference is stuck).
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @admin "media-where-used-admin"
  @dataset "production"

  # 1x1 transparent PNG, inline — no fixture file needed (mirrors media_test.exs).
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    {:ok, _} = Auth.create_token(@admin, "where-used", "test", ["read", "write", "admin"])
    :ok
  end

  describe "DELETE /v1/media/:dataset/:id" do
    test "refuses, names the referring document, and leaves the blob intact" do
      file = media_file!()
      doc = paper_referencing!(file, @dataset)

      body =
        admin(scoped_conn())
        |> delete("/v1/media/#{@dataset}/#{file.id}")
        |> json_response(409)

      assert Repo.get(MediaFile, file.id),
             "the guard answered 409 but the blob row was deleted anyway"

      assert body["error"]["code"] == "conflict"
      assert body["error"]["details"]["referencedByCount"] == 1
      assert body["error"]["details"]["path"] == "/media/files/#{file.path}"

      referrers = Enum.map(body["error"]["details"]["referencedBy"], & &1["doc_id"])

      assert doc.doc_id in referrers,
             "the refusal did not NAME the referring document, so the operator " <>
               "cannot go fix it: #{inspect(body["error"]["details"])}"
    end

    test "?force=true is the honest escape hatch and still deletes" do
      file = media_file!()
      _doc = paper_referencing!(file, @dataset)

      body =
        admin(scoped_conn())
        |> delete("/v1/media/#{@dataset}/#{file.id}?force=true")
        |> json_response(200)

      assert body["result"]["deleted"] == file.id
      refute Repo.get(MediaFile, file.id)
    end

    test "an UNREFERENCED blob still deletes — the guard must not brick the door" do
      file = media_file!()

      body =
        admin(scoped_conn())
        |> delete("/v1/media/#{@dataset}/#{file.id}")
        |> json_response(200)

      assert body["result"]["deleted"] == file.id
      refute Repo.get(MediaFile, file.id)
    end

    test "a DRAFT reference does not refuse — only published documents count" do
      file = media_file!()
      _draft = paper_referencing!(file, @dataset, status: "draft")

      admin(scoped_conn())
      |> delete("/v1/media/#{@dataset}/#{file.id}")
      |> json_response(200)

      refute Repo.get(MediaFile, file.id)
    end

    test "a reference from ANOTHER dataset still refuses — the blob keyspace is flat" do
      file = media_file!()
      doc = paper_referencing!(file, "staging")

      body =
        admin(scoped_conn())
        |> delete("/v1/media/#{@dataset}/#{file.id}")
        |> json_response(409)

      assert Repo.get(MediaFile, file.id)

      referrers = Enum.map(body["error"]["details"]["referencedBy"], & &1["doc_id"])

      assert doc.doc_id in referrers,
             "a cross-dataset referrer was invisible to the guard — `/media/files/<path>` " <>
               "resolves identically from every dataset, so this delete would still have " <>
               "blanked a live page"
    end
  end

  describe "DELETE /media/:id (legacy twin)" do
    test "refuses, names the referring document, and leaves the blob intact" do
      file = media_file!()
      doc = paper_referencing!(file, @dataset)

      body =
        admin(scoped_conn())
        |> delete("/media/#{file.id}")
        |> json_response(409)

      assert Repo.get(MediaFile, file.id),
             "the legacy door answered 409 but the blob row was deleted anyway"

      assert body["error"]["code"] == "conflict"

      referrers = Enum.map(body["error"]["details"]["referencedBy"], & &1["doc_id"])
      assert doc.doc_id in referrers
    end

    test "an UNREFERENCED blob still deletes" do
      file = media_file!()

      body = admin(scoped_conn()) |> delete("/media/#{file.id}") |> json_response(200)

      assert body["deleted"] == file.id
      refute Repo.get(MediaFile, file.id)
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────────

  defp admin(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @admin)
    |> put_req_header("content-type", "application/json")
  end

  # Created through the REAL upload door so the row carries whatever tenant scope
  # `scope_opts/1` will later demand of it — a hand-inserted nil-workspace row is
  # invisible to the fail-closed `scope_to_workspace/3` read and 404s before the
  # guard is ever reached. The generated path carries a unique integer, so every
  # scan in this file is keyed to a string no other agent's rows in the SHARED
  # test database can contain: no assertion here counts over a whole table.
  defp media_file! do
    tmp = Path.join(System.tmp_dir!(), "where-used-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, Base.decode64!(@png_b64))
    upload = %Plug.Upload{path: tmp, filename: "cast.png", content_type: "image/png"}

    created =
      admin(scoped_conn())
      |> post("/media/upload", %{"file" => upload})
      |> json_response(201)

    # The sandbox rolls the row back; the BYTES on disk outlive the test.
    on_exit(fn ->
      File.rm(Path.join(Media.upload_dir(), created["path"]))
    end)

    Repo.get!(MediaFile, created["id"])
  end

  # A paper whose block tree carries the blob as a raw URL string — the shape
  # every reference graph is blind to, nested so a top-level-only scan would
  # miss it.
  defp paper_referencing!(%MediaFile{} = file, dataset, opts \\ []) do
    doc_id = "where-used-paper-#{System.unique_integer([:positive])}"

    Repo.insert!(%Document{
      doc_id: doc_id,
      type: "paper",
      dataset: dataset,
      title: "Where-used fixture",
      status: Keyword.get(opts, :status, "published"),
      rev: "rev-#{System.unique_integer([:positive])}",
      content: %{
        "blocks" => [
          %{"type" => "paragraph", "text" => "before"},
          %{"type" => "image", "src" => "/media/files/#{file.path}", "alt" => "the cast"},
          %{"type" => "paragraph", "text" => "after"}
        ]
      }
    })
  end
end
