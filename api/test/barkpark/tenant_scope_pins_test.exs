defmodule Barkpark.TenantScopePinsTest do
  @moduledoc """
  task-8c44caa670abe015 — the tenant-scoping mutation sweep. 30 workspace /
  project / dataset where-clauses behind /v1 reads and writes were dropped or
  widened one at a time; these tests pin the branches no test caught. Each
  refusal sits next to a control on the same function, and each states the
  precondition that puts the request on the branch it pins (a fallback arm is
  only reached when the authoritative arm cannot resolve), so it cannot pass by
  taking the other road.

    * M2   `Media.upload/3` dedup: the same bytes in another workspace are a new
           file, on the path where neither upload resolves a dataset_id.
    * D2   `WriteScope.scope_to_dataset/3`: with no dataset_id resolvable, the
           dataset STRING still narrows the read.
    * MR3  a media text search scoped to a workspace (no project) never
           matches an own blob through a foreign workspace's asset metadata.
    * MR2  with no dataset_id resolvable, a media text match never uses
           metadata from another dataset of the same workspace.
    * MS1/MS2  result facets (tags) are joined only from the requested
           dataset's asset docs, with and without a resolved dataset_id.
    * SH2  `Sheets.fetch_embedded_sheets/2` with a workspace and no dataset_id
           never returns another workspace's same-named sheet.
    * E2   `EventLog.head_event_id/3` for a workspace never reports a later
           event from another workspace as its resume point.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Content, Media, Repo}
  alias Barkpark.Content.{Document, EventLog, MutationEvent, Sheets, WriteScope}
  alias Barkpark.Media.Storage.MediaFile

  defp insert_doc!(attrs, workspace_id) do
    suffix = System.unique_integer([:positive])

    {:ok, doc} =
      %Document{}
      |> Document.changeset(
        Map.merge(
          %{
            doc_id: "pin-#{suffix}",
            title: "pin #{suffix}",
            status: "published",
            rev: "r#{suffix}",
            content: %{}
          },
          attrs
        )
      )
      |> Repo.insert()

    {1, _} =
      Repo.update_all(from(d in Document, where: d.id == ^doc.id),
        set: [workspace_id: workspace_id]
      )

    Repo.get!(Document, doc.id)
  end

  defp text_upload(bytes) do
    path = Path.join(System.tmp_dir!(), "pin-dedup-#{System.unique_integer([:positive])}.txt")
    File.write!(path, bytes)
    %Plug.Upload{path: path, filename: "note.txt", content_type: "text/plain"}
  end

  @dataset "pin-media-ws-scope"
  @marker "zqpinmediawsscope"
  defp asset_doc!(file, workspace_id, title) do
    insert_doc!(
      %{
        type: "mediaAsset",
        dataset: @dataset,
        title: title,
        content: %{"mediaFileId" => file.id}
      },
      workspace_id
    )
  end

  defp project_less_blob!(ws, dataset) do
    proj = create_project!(ws)
    {:ok, file} = create_media_file_in!(ws, proj, %{}, dataset)

    {1, _} =
      Repo.update_all(from(m in MediaFile, where: m.id == ^file.id),
        set: [project_id: nil, dataset_id: nil]
      )

    # Drop the project so the workspace resolves no default project.
    Repo.delete!(proj)
    Repo.get!(MediaFile, file.id)
  end

  defp asset_doc_in!(file, workspace_id, dataset, title) do
    insert_doc!(
      %{type: "mediaAsset", dataset: dataset, title: title, content: %{"mediaFileId" => file.id}},
      workspace_id
    )
  end

  defp tagged_doc_in!(file, workspace_id, dataset, dataset_id, tag) do
    doc =
      insert_doc!(
        %{
          type: "mediaAsset",
          dataset: dataset,
          content: %{"mediaFileId" => file.id, "tags" => [tag]}
        },
        workspace_id
      )

    {1, _} =
      Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: [dataset_id: dataset_id])

    doc
  end

  defp ensure_dataset!(proj, slug) do
    case Barkpark.Tenancy.get_dataset(proj, slug) do
      nil ->
        {:ok, _} = Barkpark.Tenancy.create_dataset(proj, %{slug: slug, name: slug})
        Barkpark.Tenancy.get_dataset(proj, slug)

      ds ->
        ds
    end
  end

  defp tag_ids(dataset, scope, tag) do
    {files, _total, _facets, _meta} = Media.search_files(dataset, [tags: tag] ++ scope)
    files |> Enum.map(& &1.id) |> MapSet.new()
  end

  defp search_ids(scope) do
    {files, _total, _facets, _meta} = Media.search_files(@dataset, [q: @marker] ++ scope)
    files |> Enum.map(& &1.id) |> MapSet.new()
  end

  defp event!(dataset, ws) do
    suffix = System.unique_integer([:positive])

    {:ok, ev} =
      Repo.insert(%MutationEvent{
        dataset: dataset,
        type: "post",
        doc_id: "pin-ev-#{suffix}",
        mutation: "create",
        rev: "r#{suffix}",
        document: %{},
        workspace_id: ws.id,
        inserted_at: DateTime.utc_now()
      })

    ev
  end

  describe "M2 — media dedup never crosses a workspace when no dataset_id resolves" do
    test "the same bytes in workspace B are B's own file; a repeat in A finds A's" do
      # Two workspaces with NO project: `scope_project_id/1` resolves nothing,
      # so neither upload gets a dataset_id and only the workspace filter can
      # tell their rows apart.
      ws_a = create_workspace!()
      ws_b = create_workspace!()
      bytes = "pin dedup #{System.unique_integer([:positive])} #{:rand.uniform()}"

      {:ok, in_a} =
        Media.upload(text_upload(bytes), "production", dedupe: true, workspace_id: ws_a.id)

      assert is_nil(in_a.dataset_id), "precondition: the upload resolved a dataset_id"

      result = Media.upload(text_upload(bytes), "production", dedupe: true, workspace_id: ws_b.id)

      assert match?({:ok, %MediaFile{}}, result),
             "B's upload was answered with A's file: #{inspect(result)}"

      {:ok, in_b} = result

      assert in_b.workspace_id == ws_b.id
      refute in_b.id == in_a.id

      # Control: within A the dedup still works.
      assert {:existing, %MediaFile{id: id}} =
               Media.upload(text_upload(bytes), "production", dedupe: true, workspace_id: ws_a.id)

      assert id == in_a.id
    end
  end

  describe "D2 — WriteScope.scope_to_dataset narrows by the dataset STRING when no id resolves" do
    test "a read of dataset A never returns dataset B's rows" do
      suffix = System.unique_integer([:positive])
      ds_a = "pin-ds-a-#{suffix}"
      ds_b = "pin-ds-b-#{suffix}"
      a = insert_doc!(%{type: "post", dataset: ds_a}, nil)
      b = insert_doc!(%{type: "post", dataset: ds_b}, nil)

      assert is_nil(Content.resolve_read_dataset_id(ds_a, [])),
             "precondition: dataset A resolved an id, so the fallback arm is not reached"

      ids =
        from(d in Document, where: d.id in ^[a.id, b.id])
        |> WriteScope.scope_to_dataset(ds_a, [])
        |> Repo.all()
        |> Enum.map(& &1.id)

      assert ids == [a.id], "dataset #{ds_a}'s read returned #{inspect(ids)}"
    end
  end

  describe "MR3 — media search scoped to a workspace attaches only that workspace's metadata" do
    test "an own blob whose only matching metadata is a foreign workspace's asset doc is not matched" do
      own_ws = create_workspace!()
      own_proj = create_project!(own_ws)
      foreign_ws = create_workspace!()

      # Both blobs live in own_ws, so the door's blob clamp admits both: only
      # the text-match join (`Retriever.join_scope_workspace/3`, workspace
      # with no project) decides which metadata may match.
      {:ok, crossed} = create_media_file_in!(own_ws, own_proj, %{}, @dataset)
      asset_doc!(crossed, foreign_ws.id, "#{@marker} foreign metadata")

      {:ok, own} = create_media_file_in!(own_ws, own_proj, %{}, @dataset)
      asset_doc!(own, own_ws.id, "#{@marker} own metadata")

      ids = search_ids(workspace_id: own_ws.id)

      # Control: own-workspace metadata matches.
      assert MapSet.member?(ids, own.id)
      refute MapSet.member?(ids, crossed.id), "a foreign asset doc's title matched for own_ws"

      # Non-vacuity: the explicit global read matches the crossed row.
      assert MapSet.member?(search_ids([]), crossed.id)
    end
  end

  describe "MR2 — with no dataset_id, the text match stays in the requested dataset" do
    test "a blob's metadata from ANOTHER dataset of the same workspace does not match" do
      # A workspace with NO project resolves no dataset_id, so the retriever's
      # join falls back to the dataset STRING (`join_scope_dataset/3`).
      ws = create_workspace!()
      other_ds = "#{@dataset}-other"

      blob = project_less_blob!(ws, @dataset)
      asset_doc_in!(blob, ws.id, other_ds, "#{@marker} other dataset metadata")

      control = project_less_blob!(ws, @dataset)
      asset_doc_in!(control, ws.id, @dataset, "#{@marker} same dataset metadata")

      assert is_nil(Content.resolve_read_dataset_id(@dataset, workspace_id: ws.id)),
             "precondition: a dataset_id resolved, so the string fallback is not reached"

      ids = search_ids(workspace_id: ws.id)
      assert MapSet.member?(ids, control.id)
      refute MapSet.member?(ids, blob.id), "metadata from #{other_ds} matched a #{@dataset} blob"
    end
  end

  describe "MS1 / MS2 — result facets (tags) come only from the requested dataset's asset docs" do
    test "MS2: with no dataset_id, another dataset's asset doc lends a blob no tags" do
      ws = create_workspace!()
      tag = "pintagms2#{System.unique_integer([:positive])}"

      blob = project_less_blob!(ws, @dataset)
      tagged_doc_in!(blob, ws.id, "#{@dataset}-other", nil, tag)

      control = project_less_blob!(ws, @dataset)
      tagged_doc_in!(control, ws.id, @dataset, nil, tag)

      assert is_nil(Content.resolve_read_dataset_id(@dataset, workspace_id: ws.id)),
             "precondition: a dataset_id resolved, so the string fallback is not reached"

      ids = tag_ids(@dataset, [workspace_id: ws.id], tag)
      assert MapSet.member?(ids, control.id)
      refute MapSet.member?(ids, blob.id), "another dataset's asset doc tagged a #{@dataset} blob"
    end

    test "MS1: with a resolved dataset_id, another dataset's asset doc lends a blob no tags" do
      ws = create_workspace!()
      proj = create_project!(ws)
      tag = "pintagms1#{System.unique_integer([:positive])}"
      other_ds = "#{@dataset}-other"

      ds = ensure_dataset!(proj, @dataset)
      other = ensure_dataset!(proj, other_ds)

      {:ok, blob} = create_media_file_in!(ws, proj, %{dataset_id: ds.id}, @dataset)
      assert blob.dataset_id == ds.id, "precondition: the blob carries no dataset_id"
      tagged_doc_in!(blob, ws.id, other_ds, other.id, tag)

      {:ok, control} = create_media_file_in!(ws, proj, %{dataset_id: ds.id}, @dataset)
      tagged_doc_in!(control, ws.id, @dataset, ds.id, tag)

      ids = tag_ids(@dataset, [workspace_id: ws.id, project_id: proj.id], tag)
      assert MapSet.member?(ids, control.id)
      refute MapSet.member?(ids, blob.id), "#{other_ds}'s asset doc tagged a #{@dataset} blob"
    end
  end

  describe "SH2 — embedded sheets resolve within the embedding workspace" do
    test "a workspace-scoped fetch never returns another workspace's same-named sheet" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()
      dataset = "pin-sheets-#{System.unique_integer([:positive])}"
      sheet = insert_doc!(%{type: "sheet", dataset: dataset, content: %{"cells" => %{}}}, ws_a.id)

      assert sheet.dataset_id == nil, "precondition: the sheet carries a dataset_id"

      in_a =
        Sheets.fetch_embedded_sheets([sheet.doc_id], %{
          "dataset" => dataset,
          "workspace_id" => ws_a.id
        })

      assert Map.has_key?(in_a, sheet.doc_id), "control: workspace A cannot see its own sheet"

      in_b =
        Sheets.fetch_embedded_sheets([sheet.doc_id], %{
          "dataset" => dataset,
          "workspace_id" => ws_b.id
        })

      assert in_b == %{}, "workspace B received workspace A's sheet: #{inspect(Map.keys(in_b))}"
    end
  end

  describe "E2 — a workspace's listen resume point is its own head" do
    test "head_event_id for workspace A ignores a later event in workspace B" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()
      dataset = "pin-events-#{System.unique_integer([:positive])}"

      a = event!(dataset, ws_a)
      b = event!(dataset, ws_b)
      assert b.id > a.id, "precondition: B's event is the later one"

      assert EventLog.head_event_id(dataset, ws_a.id) == a.id
      # Control: B's own head is B's event.
      assert EventLog.head_event_id(dataset, ws_b.id) == b.id
    end
  end
end
