defmodule BarkparkWeb.V1MediaUsageTest do
  @moduledoc """
  task-0e3b9517b55fa3b9 — `GET /v1/media/:dataset/:id/usage` lists the
  documents that use a file, and only the ones the caller could read.

  The delete guard (`Media.WhereUsed`) counts referrers across the file's
  whole workspace and every dataset on purpose. This read must not: a
  document in another workspace, project or dataset, or one whose only use of
  the file sits in a field the caller may not read, is not listed and not
  counted.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @admin "media-usage-admin"
  @editor "media-usage-editor"
  @ds "production"
  @png_b64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="

  setup do
    {:ok, _} = Auth.create_token(@admin, "media-usage", "test", ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@editor, "media-usage-editor", "test", ["read", "write"])
    :ok
  end

  test "lists a referring document in the caller's dataset, none from another workspace, project or dataset" do
    file = media_file!()
    foreign = create_workspace!()
    foreign_project = create_project!(foreign)
    sibling_project = create_project!(file.workspace_id)

    own = paper!(file, "Own page", file.workspace_id, file.project_id)
    draft = paper!(file, "Draft page", file.workspace_id, file.project_id, draft: true)
    paper!(file, "Foreign page", foreign.id, foreign_project.id)
    paper!(file, "Sibling project page", file.workspace_id, sibling_project.id)
    paper!(file, "Staging page", file.workspace_id, file.project_id, dataset: "staging")

    body = admin(scoped_conn()) |> get("/v1/media/#{@ds}/#{file.id}/usage") |> json_response(200)
    result = body["result"]

    assert result["total"] == 2, inspect(result)

    assert Enum.map(result["documents"], &Map.take(&1, ~w(id title draft published))) == [
             %{"id" => Content.published_id(draft.doc_id), "title" => "Draft page"}
             |> both(true, false),
             %{"id" => own.doc_id, "title" => "Own page"} |> both(false, true)
           ]

    refute Jason.encode!(body) =~ "Foreign page"
    refute Jason.encode!(body) =~ "Sibling project page"
    refute Jason.encode!(body) =~ "Staging page"
  end

  test "a schema image field's reference is listed; an unused file says so" do
    file = media_file!()
    unused = media_file!()
    asset = Media.asset_doc_for_file(file, file.dataset, MediaFile.scope_opts(file))
    scope = [workspace_id: file.workspace_id, project_id: file.project_id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "usage_post",
          "title" => "Usage post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "hero", "type" => "image"}
          ]
        },
        @ds,
        scope
      )

    {:ok, post} =
      Content.create_document(
        "usage_post",
        %{
          "title" => "Hero post",
          "hero" => %{"asset" => %{"_ref" => Content.published_id(asset.doc_id)}}
        },
        @ds,
        scope
      )

    result =
      admin(scoped_conn()) |> get("/v1/media/#{@ds}/#{file.id}/usage") |> json_response(200)

    assert [%{"id" => id, "type" => "usage_post", "draft" => true}] =
             result["result"]["documents"]

    assert id == Content.published_id(post.doc_id)

    assert admin(scoped_conn())
           |> get("/v1/media/#{@ds}/#{unused.id}/usage")
           |> json_response(200) ==
             %{"result" => %{"documents" => [], "total" => 0, "truncated" => false}}
  end

  test "a use inside a private field is listed for an admin and hidden from an editor" do
    file = media_file!()
    scope = [workspace_id: file.workspace_id, project_id: file.project_id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "usage_note",
          "title" => "Usage note",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "secret", "type" => "string", "private" => true}
          ]
        },
        @ds,
        scope
      )

    insert!(file, "usage_note", "Private use", file.workspace_id, file.project_id, %{
      "secret" => "/media/files/#{file.path}"
    })

    # The control: the editor reads an open use of the same file.
    paper!(file, "Open use", file.workspace_id, file.project_id)

    path = "/v1/media/#{@ds}/#{file.id}/usage"

    titles = fn conn ->
      conn
      |> get(path)
      |> json_response(200)
      |> get_in(["result", "documents"])
      |> Enum.map(& &1["title"])
    end

    assert titles.(admin(scoped_conn())) == ["Open use", "Private use"]
    assert titles.(editor(scoped_conn())) == ["Open use"]
  end

  test "a file outside the caller's scope or dataset is a 404; no principal is a 401" do
    file = media_file!()
    paper!(file, "Own page", file.workspace_id, file.project_id)

    assert admin(scoped_conn()) |> get("/v1/media/staging/#{file.id}/usage") |> json_response(404)

    foreign = create_workspace!()

    Repo.update_all(from(f in MediaFile, where: f.id == ^file.id),
      set: [workspace_id: foreign.id]
    )

    resp = admin(scoped_conn()) |> get("/v1/media/#{@ds}/#{file.id}/usage")
    assert resp.status == 404
    refute resp.resp_body =~ "Own page"

    resp = scoped_conn() |> get("/v1/media/#{@ds}/#{file.id}/usage")
    assert resp.status == 401
    refute resp.resp_body =~ "Own page"
  end

  test "a hidden document never takes a candidate slot: total and truncated ignore it" do
    file = media_file!()
    sibling_project = create_project!(file.workspace_id)
    cap = Barkpark.Media.WhereUsed.rows_limit()
    now = DateTime.utc_now()
    body = %{"blocks" => [%{"type" => "image", "src" => "/media/files/#{file.path}"}]}

    row = fn doc_id, project_id ->
      %{
        id: Ecto.UUID.generate(),
        doc_id: doc_id,
        type: "paper",
        dataset: @ds,
        title: doc_id,
        status: "published",
        workspace_id: file.workspace_id,
        project_id: project_id,
        rev: "rev-" <> doc_id,
        content: body,
        inserted_at: now,
        updated_at: now
      }
    end

    # The caller's own uses fill the cap exactly; the last one sorts after
    # the hidden document, so a hidden row taking a slot would push it out.
    own =
      for n <- 1..(cap - 1),
          do: row.("a-fill-#{String.pad_leading("#{n}", 4, "0")}", file.project_id)

    Repo.insert_all(Document, own ++ [row.("z-last", file.project_id)])

    usage = fn ->
      admin(scoped_conn()) |> get("/v1/media/#{@ds}/#{file.id}/usage") |> json_response(200)
    end

    without = usage.()

    assert %{"total" => ^cap, "truncated" => false} = without["result"]

    Repo.insert_all(Document, [row.("m-hidden", sibling_project.id)])

    assert usage.() == without

    Repo.insert_all(Document, [row.("b-one-more", file.project_id)])

    assert %{"total" => ^cap, "truncated" => true} = usage.()["result"]
  end

  test "a use only inside a private field never takes a cap slot either" do
    file = media_file!()
    scope = [workspace_id: file.workspace_id, project_id: file.project_id]
    cap = Barkpark.Media.WhereUsed.rows_limit()
    url = "/media/files/#{file.path}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "usage_memo",
          "title" => "Usage memo",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "secret", "type" => "string", "private" => true}
          ]
        },
        @ds,
        scope
      )

    # The editor's own visible uses fill the cap exactly, the last sorting
    # after the memo; the memo is readable but holds the path only in `secret`.
    own =
      for n <- 1..(cap - 1),
          do: raw_row(file, "a-fill-#{String.pad_leading("#{n}", 4, "0")}", "paper", image(url))

    Repo.insert_all(Document, own ++ [raw_row(file, "z-last", "paper", image(url))])

    usage = fn ->
      editor(scoped_conn()) |> get("/v1/media/#{@ds}/#{file.id}/usage") |> json_response(200)
    end

    without = usage.()
    assert %{"total" => ^cap, "truncated" => false} = without["result"]

    Repo.insert_all(Document, [raw_row(file, "m-memo", "usage_memo", %{"secret" => url})])

    assert usage.() == without

    # One more own use lands on the second page and still counts.
    Repo.insert_all(Document, [raw_row(file, "zz-more", "paper", image(url))])

    assert %{"total" => ^cap, "truncated" => true} = usage.()["result"]
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp both(row, draft, published),
    do: Map.merge(row, %{"draft" => draft, "published" => published})

  defp admin(conn), do: put_req_header(conn, "authorization", "Bearer " <> @admin)
  defp editor(conn), do: put_req_header(conn, "authorization", "Bearer " <> @editor)

  defp media_file! do
    tmp = Path.join(System.tmp_dir!(), "media-usage-#{System.unique_integer([:positive])}.png")
    File.write!(tmp, Base.decode64!(@png_b64) <> "#{System.unique_integer([:positive])}")
    upload = %Plug.Upload{path: tmp, filename: "logo.png", content_type: "image/png"}

    created =
      admin(scoped_conn())
      |> post("/v1/media/#{@ds}/upload", %{"file" => upload})
      |> json_response(201)
      |> Map.fetch!("result")

    on_exit(fn -> File.rm(Path.join(Media.upload_dir(), created["path"])) end)
    Repo.get!(MediaFile, created["id"])
  end

  defp image(url), do: %{"blocks" => [%{"type" => "image", "src" => url}]}

  defp raw_row(file, doc_id, type, content) do
    now = DateTime.utc_now()

    %{
      id: Ecto.UUID.generate(),
      doc_id: doc_id,
      type: type,
      dataset: @ds,
      title: doc_id,
      status: "published",
      workspace_id: file.workspace_id,
      project_id: file.project_id,
      rev: "rev-" <> doc_id,
      content: content,
      inserted_at: now,
      updated_at: now
    }
  end

  defp paper!(file, title, workspace_id, project_id, opts \\ []) do
    content = %{"blocks" => [%{"type" => "image", "src" => "/media/files/#{file.path}"}]}
    insert!(file, "paper", title, workspace_id, project_id, content, opts)
  end

  defp insert!(_file, type, title, workspace_id, project_id, content, opts \\ []) do
    id = "usage-#{System.unique_integer([:positive])}"
    draft? = Keyword.get(opts, :draft, false)

    Repo.insert!(%Document{
      doc_id: if(draft?, do: "drafts." <> id, else: id),
      type: type,
      dataset: Keyword.get(opts, :dataset, @ds),
      title: title,
      status: if(draft?, do: "draft", else: "published"),
      workspace_id: workspace_id,
      project_id: project_id,
      rev: "rev-#{System.unique_integer([:positive])}",
      content: content
    })
  end
end
