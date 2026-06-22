defmodule Barkpark.Media do
  @moduledoc "Context for media file upload, storage, and retrieval."

  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Media.Delivery.{Cdn, Events}
  alias Barkpark.Media.MediaFile
  alias Barkpark.Plugins.Media.Assets

  @upload_dir Application.compile_env!(:barkpark, :media_upload_dir)
  @asset_type "mediaAsset"

  @metadata_fields ~w(title altText caption description tags collection collections assetRole rights focalPoint relatedAssets bp_visibility)

  def upload_dir, do: @upload_dir

  @doc """
  Save an uploaded file to disk and create a DB record.

  `opts` may carry tenancy scope stamped onto the new row on insert (mirrors
  `Barkpark.Content` write scoping):
    * `:workspace_id` — stamp the owning workspace (nil = unscoped / pre-tenancy).
    * `:project_id`   — stamp the owning project (nil = workspace-wide).
  """
  def upload(plug_upload, dataset, opts \\ []) when is_binary(dataset) do
    %Plug.Upload{filename: original_name, path: temp_path, content_type: content_type} =
      plug_upload

    # Generate date-based path: uploads/2026/04/filename
    now = DateTime.utc_now()
    date_dir = "#{now.year}/#{String.pad_leading("#{now.month}", 2, "0")}"
    filename = unique_filename(original_name)
    relative_path = "#{date_dir}/#{filename}"
    full_dir = Path.join(@upload_dir, date_dir)
    full_path = Path.join(@upload_dir, relative_path)

    # Ensure directory exists
    File.mkdir_p!(full_dir)

    # Copy uploaded file to storage
    File.cp!(temp_path, full_path)

    # Get file size
    %{size: size} = File.stat!(full_path)

    # Detect MIME type
    mime_type = content_type || MIME.from_path(original_name)

    # Create DB record. Tenancy scope (workspace_id/project_id) is stamped from
    # `opts` when the caller supplied a resolved scope — mirrors
    # `Barkpark.Content` write scoping so a new blob is owned by the workspace
    # it was uploaded into. Without scope opts the keys are absent and the row
    # keeps its pre-tenancy (nil) shape.
    attrs =
      %{
        filename: filename,
        original_name: original_name,
        path: relative_path,
        mime_type: mime_type,
        size: size,
        dataset: dataset
      }
      |> put_scope_attrs(opts)

    result =
      %MediaFile{}
      |> MediaFile.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, file} = ok ->
        _ =
          Barkpark.Plugins.Registry.run_after_media_upload(%{media_file: file, dataset: dataset})

        ok

      error ->
        error
    end
  end

  @doc "List all media files for a dataset."
  def list_files(dataset, opts \\ []) when is_binary(dataset) do
    {files, _} = query_files(dataset, Keyword.delete(opts, :limit) |> Keyword.put(:limit, 10_000))
    files
  end

  @doc """
  Paginated media query. Returns `{files, total_count}`.

  Options:
    * `:limit`, `:offset`
    * `:mime_type` — MIME prefix (`image/` → `LIKE 'image/%'`)
    * `:kind` — `mediaAsset.bp_asset_kind` (`image`, `video`, …)
    * `:q` — case-insensitive search on filename / original name / asset title
  """
  @spec query_files(String.t(), keyword()) :: {[MediaFile.t()], non_neg_integer()}
  def query_files(dataset, opts \\ []) when is_binary(dataset) do
    search_opts =
      opts
      |> Keyword.take([
        :limit,
        :offset,
        :mime_type,
        :kind,
        :q,
        :status,
        :processing,
        :collection,
        :tags,
        :visibility,
        :sort,
        :workspace_id,
        :project_id
      ])
      |> Keyword.put_new(:limit, 50)
      |> Keyword.put_new(:offset, 0)

    {files, total, _facets, _meta} = Barkpark.Media.Delivery.Search.search(dataset, search_opts)
    {files, total}
  end

  @doc """
  Faceted search. Returns `{files, total, facets, meta}`.
  See `Barkpark.Media.Delivery.Search` for supported options.
  """
  @spec search_files(String.t(), keyword()) ::
          {[MediaFile.t()], non_neg_integer(), map(), map()}
  def search_files(dataset, opts \\ []) when is_binary(dataset) do
    Barkpark.Media.Delivery.Search.search(dataset, opts)
  end

  @doc """
  Batch-load linked `mediaAsset` documents keyed by blob id.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); it is
  threaded into `Assets.find_by_media_file_ids/3` so a listing resolved to
  workspace B never resolves workspace A's asset metadata (title/tags/rights)
  for a blob that shares the dataset STRING — the cross-workspace metadata leak
  (barkpark-vmv1). The asset-doc envelope is NULL-tolerant so legacy
  NULL-workspace docs stay visible in their own tenant.
  """
  @spec asset_docs_for_files([MediaFile.t()], String.t(), keyword()) :: %{
          String.t() => struct()
        }
  def asset_docs_for_files(files, dataset, opts \\ [])
      when is_list(files) and is_binary(dataset) and is_list(opts) do
    ids = Enum.map(files, & &1.id)
    Assets.find_by_media_file_ids(ids, dataset, opts)
  end

  @doc """
  Linked `mediaAsset` document for a blob row, if any.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); threaded
  into `Assets.find_by_media_file_id/3` so a relation-graph read scoped to
  workspace B never resolves workspace A's asset doc for the same blob id
  (barkpark-m21z). An absent workspace_id is the deliberate global / legacy
  single-tenant path — the 2-arity callers stay unchanged via the default.
  """
  @spec asset_doc_for_file(MediaFile.t(), String.t(), keyword()) :: struct() | nil
  def asset_doc_for_file(%MediaFile{} = file, dataset, opts \\ []) do
    Assets.find_by_media_file_id(file.id, dataset, opts)
  end

  @doc """
  Patch metadata on the linked `mediaAsset` document. Creates the asset
  document if missing. Does not mutate blob fields (`fileInfo`, `mediaFileId`).
  """
  @spec patch_asset_metadata(MediaFile.t(), map(), String.t()) ::
          {:ok, struct()} | {:error, term()}
  def patch_asset_metadata(%MediaFile{} = file, params, dataset) when is_map(params) do
    with {:ok, doc} <- ensure_asset_doc(file),
         {:ok, _schema} <- Content.get_schema(@asset_type, dataset) do
      patch = pick_metadata(params)
      title = Map.get(patch, "title", doc.title)
      content_patch = Map.drop(patch, ["title"])

      content =
        (doc.content || %{})
        |> Map.merge(content_patch)
        |> Map.put("mediaFileId", file.id)

      attrs = %{
        "doc_id" => doc.doc_id,
        "title" => title,
        "status" => doc.status,
        "content" => content
      }

      case Content.upsert_document(
             @asset_type,
             attrs,
             dataset,
             [source: :api] ++ Assets.file_scope_opts(file)
           ) do
        {:ok, updated} -> {:ok, updated}
        error -> error
      end
    end
  end

  defp ensure_asset_doc(%MediaFile{} = file) do
    case Assets.ensure_for_upload(file) do
      {:ok, doc} -> {:ok, doc}
      error -> error
    end
  end

  defp pick_metadata(params) do
    params
    |> stringify_keys()
    |> Map.take(@metadata_fields)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  @doc """
  Get a single media file by ID.

  `opts` may carry tenancy scope (mirrors `Barkpark.Content.get_document`):
    * `:workspace_id` — scope the read to a workspace (nil = unscoped).
    * `:project_id`   — further narrow to a project (requires `:workspace_id`).

  The workspace/project filter is applied via
  `Barkpark.Content.Scope.scope_to_workspace/3`, so a get scoped to workspace B
  returns `{:error, :not_found}` for a blob owned by workspace A.
  """
  def get_file(id, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    MediaFile
    |> where([m], m.id == ^id)
    |> Content.Scope.scope_to_workspace_or_global(workspace_id, project_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      file -> {:ok, file}
    end
  end

  @doc """
  Get a media file by its storage-relative path.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); when present
  the path lookup is scoped through `Content.Scope.scope_to_workspace_or_global/3`
  so a serve scoped to workspace B never resolves a blob owned by workspace A
  (barkpark-af50). An unscoped lookup keeps the explicit-global behaviour, so the
  public serve path is unchanged until a workspace is threaded in.
  """
  @spec get_file_by_path(String.t(), keyword()) :: {:ok, MediaFile.t()} | {:error, :not_found}
  def get_file_by_path(relative_path, opts \\ []) when is_binary(relative_path) do
    MediaFile
    |> where([m], m.path == ^relative_path)
    |> Content.Scope.scope_to_workspace_or_global(
      Keyword.get(opts, :workspace_id),
      Keyword.get(opts, :project_id)
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      file -> {:ok, file}
    end
  end

  @doc """
  Delete a media file from disk and DB.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); the
  about-to-delete read is scoped through `get_file/2` so a delete in workspace B
  returns `{:error, :not_found}` for a blob owned by workspace A (barkpark-af50).
  An unscoped delete keeps the explicit-global behaviour for back-compat.
  """
  def delete_file(id, opts \\ []) do
    case get_file(id, opts) do
      {:ok, file} ->
        doc = asset_doc_for_file(file, file.dataset)
        Cdn.invalidate(file)
        Events.dispatch(file.dataset, "media.deleted", file, doc)

        full_path = Path.join(@upload_dir, file.path)
        File.rm(full_path)
        Barkpark.Media.Renditions.delete_for_file(file.id)

        result = Repo.delete(file)

        _ =
          Barkpark.Plugins.Registry.run_after_media_delete(%{
            media_file_id: file.id,
            dataset: file.dataset
          })

        result

      error ->
        error
    end
  end

  @doc "Get the full disk path for serving a file."
  def file_path(relative_path) do
    Path.join(@upload_dir, relative_path)
  end

  # Stamp tenancy scope (:workspace_id / :project_id) onto write attrs when the
  # caller supplied it via opts. Only non-nil keys are added, so an unscoped
  # upload leaves the attr map untouched — mirrors `Barkpark.Content.put_scope_attrs`.
  #
  # W2 dual-write: also resolve the blob's `dataset` STRING → its `dataset_id`
  # (within the resolved project — opts `:project_id` or the seeded Default
  # project) and stamp BOTH. The string stays as a mirror; `dataset_id` is the
  # new authoritative leaf for the (path, dataset_id) uniqueness. Degrades to no
  # dataset_id (string-only) when the project/dataset can't be resolved.
  defp put_scope_attrs(attrs, opts) do
    project_id = Keyword.get(opts, :project_id) || default_project_id()

    attrs
    |> maybe_put_scope_attr(:workspace_id, Keyword.get(opts, :workspace_id))
    |> maybe_put_scope_attr(:project_id, Keyword.get(opts, :project_id))
    |> maybe_put_scope_attr(:dataset_id, resolve_dataset_id(attrs, project_id))
  end

  defp default_project_id do
    case Barkpark.Tenancy.get_default_project() do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp resolve_dataset_id(_attrs, nil), do: nil

  defp resolve_dataset_id(attrs, project_id) do
    case Map.get(attrs, :dataset) || Map.get(attrs, "dataset") do
      dataset when is_binary(dataset) ->
        case Barkpark.Tenancy.get_or_create_dataset(project_id, dataset) do
          {:ok, %Barkpark.Tenancy.Dataset{id: id}} -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_put_scope_attr(attrs, _key, nil), do: attrs
  defp maybe_put_scope_attr(attrs, key, value), do: Map.put(attrs, key, value)

  defp unique_filename(original_name) do
    ext = Path.extname(original_name)
    base = Path.basename(original_name, ext)
    slug = base |> String.downcase() |> String.replace(~r/[^a-z0-9-]/, "-") |> String.trim("-")
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "#{slug}-#{random}#{ext}"
  end
end
