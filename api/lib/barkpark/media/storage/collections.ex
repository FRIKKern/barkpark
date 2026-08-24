defmodule Barkpark.Media.Storage.Collections do
  @moduledoc """
  Folder and virtual media collections — membership queries and member CRUD.
  """

  import Ecto.Query
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.Scope
  alias Barkpark.Media
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @collection_type "mediaCollection"
  @asset_type "mediaAsset"

  # Keys threaded into the tenancy WHERE clause (`Content.Scope`). Membership
  # writes and inner doc reads are dataset-keyed; the scope opts ride the
  # collection list/get reads so a workspace-B caller never sees workspace-A
  # collections (Wave 1.5 media-collections scope, Goal barkpark-qprk).
  #
  # `:grant_scoped` + `:caller_context` are here for task-2b7cbaf8265f6b4e.
  # `Content.Query.get_document/4` DOES call `Scope.maybe_scope_to_grants/2`,
  # but that gate reads its own flag off the opts it is handed: with the flag
  # taken out by `scope_opts/1` it saw `grant_scoped: false` and no-opped, so a
  # grant-derived caller resolved collections across the WHOLE workspace rather
  # than their grant ladder. `Scope`'s "there is no private copy of the gate
  # anywhere" is true and was beside the point — the one gate was being REACHED
  # with the input that disables it. Both keys are absent on every member
  # request (`ScopeHelpers.scope_opts/1` sets `:grant_scoped` only when
  # `ResolveWorkspace` admitted a grantee), so a member's read is unchanged.
  @scope_keys [:workspace_id, :project_id, :grant_scoped, :caller_context]

  @doc "List collection documents for a dataset (workspace-scoped via opts)."
  @spec list(String.t(), keyword()) :: [Document.t()]
  def list(dataset, opts \\ []) when is_binary(dataset) do
    limit = Keyword.get(opts, :limit, 200) |> min(1000)
    offset = Keyword.get(opts, :offset, 0) |> max(0)

    Document
    |> where([d], d.type == ^@collection_type and d.dataset == ^dataset)
    |> Scope.scope_to_workspace_or_global(opts[:workspace_id], opts[:project_id])
    |> order_by([d], asc: d.title)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc "Fetch a collection document by id (workspace-scoped via opts)."
  @spec get(String.t(), String.t(), keyword()) :: {:ok, Document.t()} | {:error, :not_found}
  def get(collection_id, dataset, opts \\ [])
      when is_binary(collection_id) and is_binary(dataset) do
    case Content.get_document(collection_id, @collection_type, dataset, scope_opts(opts)) do
      {:ok, doc} -> {:ok, doc}
      _ -> {:error, :not_found}
    end
  end

  @doc "Search assets belonging to a collection."
  @spec assets(String.t(), String.t(), keyword()) :: {[struct()], non_neg_integer(), map()}
  def assets(collection_id, dataset, opts \\ []) when is_binary(collection_id) do
    with {:ok, collection} <- get(collection_id, dataset, opts) do
      search_opts = collection_search_opts(collection, collection_id, opts)
      {files, total, facets, _meta} = Media.search_files(dataset, search_opts)
      {files, total, facets}
    else
      _ -> {[], 0, %{}}
    end
  end

  @doc "Add an asset blob to a folder collection (workspace-scoped via opts)."
  @spec add_member(String.t(), %MediaFile{}, String.t(), keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  def add_member(collection_id, %MediaFile{} = file, dataset, opts \\ []) do
    with {:ok, _collection} <- get(collection_id, dataset, opts),
         {:ok, doc} <- Media.patch_asset_metadata(file, %{}, dataset) do
      patch_membership(doc, file, dataset, collection_id, :add)
    end
  end

  @doc "Remove an asset blob from a folder collection (workspace-scoped via opts)."
  @spec remove_member(String.t(), %MediaFile{}, String.t(), keyword()) ::
          {:ok, Document.t()} | {:error, term()}
  def remove_member(collection_id, %MediaFile{} = file, dataset, opts \\ []) do
    with {:ok, _collection} <- get(collection_id, dataset, opts),
         %Document{} = doc <- Media.asset_doc_for_file(file, dataset) do
      patch_membership(doc, file, dataset, collection_id, :remove)
    else
      nil -> {:error, :not_found}
    end
  end

  @doc "Render a collection for API responses."
  @spec render(Document.t()) :: map()
  def render(%Document{} = doc) do
    content = doc.content || %{}

    %{
      id: doc.doc_id,
      title: doc.title,
      slug: Map.get(content, "slug"),
      description: Map.get(content, "description"),
      kind: Map.get(content, "kind", "folder"),
      virtualFilter: Map.get(content, "virtualFilter"),
      parent: Map.get(content, "parent"),
      coverAsset: Map.get(content, "coverAsset"),
      sortOrder: Map.get(content, "sortOrder"),
      shareEnabled: share_enabled?(content),
      shareExpiresAt: share_expires_at(content),
      createdAt: doc.inserted_at,
      updatedAt: doc.updated_at
    }
  end

  # Keep only the tenancy keys so the rest of `opts` (limit/offset/sort/…) never
  # leaks into the keyed `Content.get_document` read.
  defp scope_opts(opts), do: Keyword.take(opts, @scope_keys)

  defp collection_search_opts(%Document{content: content}, collection_id, opts) do
    base =
      opts
      |> Keyword.take([:limit, :offset, :sort, :facets, :facet_selections])
      |> Keyword.put_new(:limit, 50)
      |> Keyword.put_new(:offset, 0)
      |> Keyword.put_new(:sort, "created-desc")

    case Map.get(content || %{}, "kind", "folder") do
      "virtual" ->
        virtual_filter = Map.get(content || %{}, "virtualFilter", %{})
        virtual_to_search_opts(base, virtual_filter)

      _ ->
        Keyword.put(base, :collection, collection_id)
    end
  end

  defp virtual_to_search_opts(base, filter) when is_map(filter) do
    base
    |> maybe_put(:kind, blank_to_nil(filter["kind"]))
    |> maybe_put(:tags, blank_to_nil(filter["tags"]))
    |> maybe_put(:q, blank_to_nil(filter["q"]))
    |> maybe_put(:mime_type, blank_to_nil(filter["mimeType"]))
    |> maybe_put(:visibility, blank_to_nil(filter["visibility"]))
  end

  defp virtual_to_search_opts(base, _), do: base

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp patch_membership(doc, file, dataset, collection_id, :add) do
    content = doc.content || %{}
    collections = normalize_ref_list(Map.get(content, "collections", []))

    collections =
      if collection_id in collections do
        collections
      else
        collections ++ [collection_id]
      end

    primary = Map.get(content, "collection") || collection_id

    attrs = %{
      "doc_id" => doc.doc_id,
      "title" => doc.title,
      "status" => doc.status,
      "content" =>
        content
        |> Map.put("collection", primary)
        |> Map.put("collections", collections)
        |> Map.put("mediaFileId", file.id)
    }

    Content.upsert_document(
      @asset_type,
      attrs,
      dataset,
      [source: :api] ++ Barkpark.Plugins.Media.Assets.file_scope_opts(file)
    )
  end

  defp patch_membership(doc, file, dataset, collection_id, :remove) do
    content = doc.content || %{}
    collections = normalize_ref_list(Map.get(content, "collections", [])) -- [collection_id]

    primary =
      if Map.get(content, "collection") == collection_id do
        List.first(collections)
      else
        Map.get(content, "collection")
      end

    attrs = %{
      "doc_id" => doc.doc_id,
      "title" => doc.title,
      "status" => doc.status,
      "content" =>
        content
        |> Map.put("collection", primary)
        |> Map.put("collections", collections)
        |> Map.put("mediaFileId", file.id)
    }

    Content.upsert_document(
      @asset_type,
      attrs,
      dataset,
      [source: :api] ++ Barkpark.Plugins.Media.Assets.file_scope_opts(file)
    )
  end

  defp normalize_ref_list(list) when is_list(list) do
    list
    |> Enum.map(fn
      %{"_ref" => ref} -> ref
      ref when is_binary(ref) -> ref
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_ref_list(_), do: []

  defp share_enabled?(content) do
    link = Map.get(content, "shareLink", %{})
    Map.get(link, "enabled") in [true, "true"]
  end

  defp share_expires_at(content) do
    content
    |> Map.get("shareLink", %{})
    |> Map.get("expiresAt")
  end
end
