defmodule BarkparkWeb.MediaDeleteRefFieldGapTest do
  @moduledoc """
  task-5f6e7ae324334044 — a media delete must also refuse when a schema
  `image`/`file` FIELD references the blob STRUCTURALLY, not just when a raw
  `/media/files/<path>` URL string is pasted somewhere in a block tree.

  THE GAP: `Barkpark.Media.WhereUsed.referrers/1` is a deliberate `content::text
  LIKE '%/media/files/<path>%'` scan (see its own moduledoc) — it finds a raw
  URL string. But a schema `image`/`file` field never stores that string: its
  value is `{"asset": {"_ref": assetDocId}, ...}` (docs/contracts/schema-v2.md),
  a reference to the blob's companion `mediaAsset` DOCUMENT
  (`Media.asset_doc_for_file/3`), whose own `doc_id` is a DIFFERENT string from
  both `MediaFile.id` and `MediaFile.path`. A document using ONLY the
  schema-managed image/file picker (never pasting a bare URL) is therefore
  completely invisible to the textual scan, even though the SAME reference
  shape is already visible to `Content.Query.list_reference_holders/3` (the
  backlinks query, task-7150f77eb6fbc640/task-94891b81179a0855).

  Confirmed first: an unforced DELETE of a blob referenced ONLY this way
  answers 200 on the pre-fix tree (the bug) — see git history / the PR diff
  for that reproduction. Every test below runs against the FIXED tree: 409,
  naming the referring document, with the blob row surviving — and
  `?force=true` still works, per the same differential
  `media_delete_where_used_test.exs` established (a status-only assertion
  would pass vacuously on this doc_id alone).
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @admin "media-ref-field-gap-admin"
  @ds "mediarefgap"

  # 1x1 transparent PNG, inline — mirrors media_delete_where_used_test.exs.
  # Each upload appends a unique trailer after IEND (still a valid PNG):
  # the v1 upload door answers repeated bytes with the existing asset
  # (task-b6e57c37f6928344), and these tests need distinct assets.
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    {:ok, _} = Auth.create_token(@admin, "ref-field-gap", "test", ["read", "write", "admin"])

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "refgap_post",
          "title" => "Ref Field Gap Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "hero", "type" => "image"},
            %{"name" => "attachment", "type" => "file"}
          ]
        },
        @ds
      )

    :ok
  end

  describe "DELETE /v1/media/:dataset/:id — a document referencing the blob ONLY via a schema image field's {asset: {_ref}}" do
    test "refuses 409, names the referring document, and leaves the blob intact" do
      file = media_file!()
      asset_doc_id = asset_doc_id!(file)

      {:ok, draft} =
        Content.create_document(
          "refgap_post",
          %{
            "title" => "Structural ref only",
            "hero" => %{"asset" => %{"_ref" => asset_doc_id}}
          },
          @ds
        )

      {:ok, _published} = Content.publish_document(draft.doc_id, "refgap_post", @ds)

      # No raw `/media/files/<path>` text anywhere in this document's content —
      # the ONLY link to the blob is the structural `_ref` above. The textual
      # scan alone would see nothing here.
      refute String.contains?(Jason.encode!(draft.content), "/media/files/")

      body =
        admin(scoped_conn())
        |> delete("/v1/media/#{@ds}/#{file.id}")
        |> json_response(409)

      assert Repo.get(MediaFile, file.id),
             "the guard answered 409 but the blob row was deleted anyway"

      assert body["error"]["code"] == "conflict"
      assert body["error"]["details"]["referencedByCount"] == 1

      referrers = Enum.map(body["error"]["details"]["referencedBy"], & &1["doc_id"])

      assert Content.published_id(draft.doc_id) in referrers,
             "the refusal did not NAME the referring document: #{inspect(body["error"]["details"])}"
    end

    test "the same guard covers a `file` field's structural {asset: {_ref}}, not just `image`" do
      file = media_file!()
      asset_doc_id = asset_doc_id!(file)

      {:ok, draft} =
        Content.create_document(
          "refgap_post",
          %{"title" => "File field ref", "attachment" => %{"asset" => %{"_ref" => asset_doc_id}}},
          @ds
        )

      {:ok, _published} = Content.publish_document(draft.doc_id, "refgap_post", @ds)

      admin(scoped_conn())
      |> delete("/v1/media/#{@ds}/#{file.id}")
      |> json_response(409)

      assert Repo.get(MediaFile, file.id)
    end

    test "?force=true is still the honest escape hatch and deletes anyway" do
      file = media_file!()
      asset_doc_id = asset_doc_id!(file)

      {:ok, draft} =
        Content.create_document(
          "refgap_post",
          %{"title" => "Forced", "hero" => %{"asset" => %{"_ref" => asset_doc_id}}},
          @ds
        )

      {:ok, _} = Content.publish_document(draft.doc_id, "refgap_post", @ds)

      body =
        admin(scoped_conn())
        |> delete("/v1/media/#{@ds}/#{file.id}?force=true")
        |> json_response(200)

      assert body["result"]["deleted"] == file.id
      refute Repo.get(MediaFile, file.id)
    end

    test "a DRAFT-only structural reference (never published) STILL refuses — a draft losing its image is the same data loss" do
      file = media_file!()
      asset_doc_id = asset_doc_id!(file)

      {:ok, draft} =
        Content.create_document(
          "refgap_post",
          %{"title" => "Draft only", "hero" => %{"asset" => %{"_ref" => asset_doc_id}}},
          @ds
        )

      body =
        admin(scoped_conn())
        |> delete("/v1/media/#{@ds}/#{file.id}")
        |> json_response(409)

      assert Repo.get(MediaFile, file.id)
      referrers = Enum.map(body["error"]["details"]["referencedBy"], & &1["doc_id"])
      assert draft.doc_id in referrers
    end

    test "a structural reference to an UNRELATED asset does not refuse" do
      file = media_file!()
      other = media_file!()
      other_asset_doc_id = asset_doc_id!(other)

      {:ok, draft} =
        Content.create_document(
          "refgap_post",
          %{"title" => "Unrelated", "hero" => %{"asset" => %{"_ref" => other_asset_doc_id}}},
          @ds
        )

      {:ok, _} = Content.publish_document(draft.doc_id, "refgap_post", @ds)

      body =
        admin(scoped_conn())
        |> delete("/v1/media/#{@ds}/#{file.id}")
        |> json_response(200)

      assert body["result"]["deleted"] == file.id
      refute Repo.get(MediaFile, file.id)
    end

    test "an UNREFERENCED blob still deletes — the guard must not brick the door" do
      file = media_file!()

      body =
        admin(scoped_conn())
        |> delete("/v1/media/#{@ds}/#{file.id}")
        |> json_response(200)

      assert body["result"]["deleted"] == file.id
      refute Repo.get(MediaFile, file.id)
    end

    test "the pre-existing TEXTUAL-scan test suite stays green (negative control: a raw URL embed still guards exactly as before)" do
      file = media_file!()
      doc_id = "refgap-textual-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Repo.insert(%Content.Document{
          doc_id: doc_id,
          type: "paper",
          dataset: @ds,
          title: "Textual fixture",
          status: "published",
          rev: "rev-#{System.unique_integer([:positive])}",
          content: %{
            "blocks" => [
              %{"type" => "image", "src" => "/media/files/#{file.path}", "alt" => "cast"}
            ]
          }
        })

      body =
        admin(scoped_conn())
        |> delete("/v1/media/#{@ds}/#{file.id}")
        |> json_response(409)

      assert body["error"]["details"]["referencedByCount"] == 1
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────────

  defp admin(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @admin)
    |> put_req_header("content-type", "application/json")
  end

  # Uploaded through the SCOPED v1 door (`POST /v1/media/:dataset/upload`), not
  # the legacy `/media/upload`, so the row lands in `@ds` — the dataset this
  # file's schema and the DELETE below both target. The legacy door always
  # uploads into its conn's default dataset, which is NOT `@ds`.
  defp media_file! do
    tmp = Path.join(System.tmp_dir!(), "ref-field-gap-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, Base.decode64!(@png_b64) <> "#{System.unique_integer([:positive])}")
    upload = %Plug.Upload{path: tmp, filename: "cast.png", content_type: "image/png"}

    created =
      admin(scoped_conn())
      |> post("/v1/media/#{@ds}/upload", %{"file" => upload})
      |> json_response(201)
      |> Map.fetch!("result")

    on_exit(fn ->
      File.rm(Path.join(Media.upload_dir(), created["path"]))
    end)

    Repo.get!(MediaFile, created["id"])
  end

  # The upload door's `after_media_upload` hook creates the companion
  # `mediaAsset` draft synchronously (`Assets.ensure_for_upload/1`). Its stored
  # `doc_id` carries the `drafts.` prefix (every create does); a schema
  # image/file field's `_ref` stores the PUBLISHED-normalized id — the same
  # normalization `Content.Query.list_reference_holders/3`'s own predicate
  # applies before matching — so this strips it the same way.
  defp asset_doc_id!(%MediaFile{} = file) do
    doc = Media.asset_doc_for_file(file, file.dataset, MediaFile.scope_opts(file))
    assert doc, "expected the upload door to have created a mediaAsset companion document"
    Content.published_id(doc.doc_id)
  end
end
