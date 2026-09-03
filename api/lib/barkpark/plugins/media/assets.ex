defmodule Barkpark.Plugins.Media.Assets do
  @moduledoc """
  Creates and maintains `mediaAsset` documents for uploaded blobs.

  Each row in `media_files` gets a companion draft document so metadata
  (alt text, collection, rights) lives in Barkpark's native document store.
  """

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  @asset_type "mediaAsset"

  @doc """
  Ensures a `mediaAsset` draft exists for `media_file`. Idempotent.
  """
  @spec ensure_for_upload(%MediaFile{}) :: {:ok, Document.t()} | {:error, term()}
  def ensure_for_upload(%MediaFile{} = file) do
    case find_by_media_file_id(file.id, file.dataset) do
      %Document{} = doc ->
        {:ok, doc}

      nil ->
        create_draft(file)
    end
  end

  @doc """
  Deletes draft/published `mediaAsset` documents linked to a blob id.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); when present
  the lookup is scoped to that tenant so a delete in workspace B never resolves
  workspace A's asset doc for the same `mediaFileId` (barkpark-5p3y). An absent
  workspace_id is the deliberate global / legacy single-tenant path.

  ## The result is LOAD-BEARING (task-1116dcb208496fc7)

  This used to discard every `Content.delete_document/4` result with `_ =` and
  return a hard-coded `:ok`. A `rev_mismatch` (the draft was edited between the
  scope read and the delete) or a `before_delete` HALT therefore left the
  document alive while `Barkpark.Media.delete_file/2` — which reached here only
  through the `after_media_delete` plugin hook, itself `:ok`-hardcoded — still
  reported a successful delete. That is the silent half of Gyldendal's 517
  dangling drafts.

  It now answers `{:error, reason}` for the FIRST document that genuinely
  failed, so `delete_file/2` can roll the blob row back with it.
  `{:error, :not_found}` is NOT a failure: a blob with no companion document,
  or a re-issued delete, is success, which is what keeps the delete idempotent.
  """
  @spec delete_for_blob(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete_for_blob(media_file_id, dataset, opts \\ [])
      when is_binary(media_file_id) and is_binary(dataset) and is_list(opts) do
    Document
    |> asset_doc_scope(media_file_id, dataset, opts)
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn doc, :ok ->
      case Content.delete_document(doc.doc_id, @asset_type, dataset, opts) do
        {:ok, _deleted} ->
          {:cont, :ok}

        # Already gone (or never there) — the postcondition this function
        # promises already holds.
        {:error, :not_found} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Linked `mediaAsset` document for a blob id, if any.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); see
  `delete_for_blob/3`.
  """
  @spec find_by_media_file_id(String.t(), String.t(), keyword()) :: Document.t() | nil
  def find_by_media_file_id(media_file_id, dataset, opts \\ [])
      when is_binary(media_file_id) and is_binary(dataset) and is_list(opts) do
    Document
    |> asset_doc_scope(media_file_id, dataset, opts)
    |> order_by([d], desc: d.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Batch lookup of asset documents by blob id.

  `opts` may carry tenancy scope (`:workspace_id` / `:project_id`); see
  `delete_for_blob/3`.
  """
  @spec find_by_media_file_ids([String.t()], String.t(), keyword()) :: %{
          String.t() => Document.t()
        }
  def find_by_media_file_ids(ids, dataset, opts \\ [])

  def find_by_media_file_ids([], _dataset, _opts), do: %{}

  def find_by_media_file_ids(ids, dataset, opts)
      when is_list(ids) and is_binary(dataset) and is_list(opts) do
    Document
    |> where([d], d.type == ^@asset_type)
    |> scope_asset_dataset(dataset, opts)
    |> scope_asset_workspace(Keyword.get(opts, :workspace_id), Keyword.get(opts, :project_id))
    |> where([d], fragment("?->>? ", d.content, "mediaFileId") in ^ids)
    |> Repo.all()
    |> Map.new(fn doc -> {Map.get(doc.content, "mediaFileId"), doc} end)
  end

  # Shared scope for a single-blob asset-doc lookup: type + tenant-resolved
  # dataset (dataset_id authoritative, dataset STRING fallback) + the
  # workspace/project envelope + the mediaFileId match. The workspace envelope
  # is what closes the cross-tenant leak — two workspaces sharing the dataset
  # STRING no longer resolve each other's asset doc for the same mediaFileId.
  defp asset_doc_scope(query, media_file_id, dataset, opts) do
    query
    |> where([d], d.type == ^@asset_type)
    |> scope_asset_dataset(dataset, opts)
    |> scope_asset_workspace(Keyword.get(opts, :workspace_id), Keyword.get(opts, :project_id))
    |> where([d], fragment("?->>? = ?", d.content, "mediaFileId", ^media_file_id))
  end

  @doc """
  NULL-tolerant workspace envelope for an asset-doc read, binding against the
  FIRST named binding (`[d]`) so it composes with any `Document` query.

  Public so the relation graph (`Barkpark.Media.Storage.Relations`) reuses the EXACT
  same envelope on its back-link query instead of hand-rolling (and silently
  diverging from) the scope clause that closes the cross-tenant leak.

  `Content.Scope.scope_to_workspace_or_global/3` is STRICT on a non-nil
  workspace_id (`d.workspace_id == ^id`, no is_nil fallback). Asset docs
  written before the write-scope fix (barkpark-x56q) carry workspace_id=NULL,
  so a strict envelope scoped to a real workspace would make EVERY legacy
  asset doc vanish from its own tenant's media listing (never-worse
  violation). This envelope keeps legacy NULL-workspace docs visible
  (`is_nil(d.workspace_id)`) WHILE isolating newly-scoped docs: a doc stamped
  to workspace A (workspace_id=A) is excluded from a read scoped to B because
  A != B and A is not NULL. The dataset envelope (scope_asset_dataset) already
  bounds the result to one dataset, so the NULL-tolerant OR cannot widen
  across datasets. A nil workspace_id (unscoped / legacy single-tenant path)
  leaves the query untouched — the deliberate global read (barkpark-vmv1).

  The `:shared_only` sentinel is NOT that read: a REQUEST that resolved no
  workspace sees `workspace_id IS NULL` alone. Only an internal caller (or a
  socket-borne read, which `ScopeHelpers.scope_opts/1` gives `:legacy` mode)
  can still reach the nil arm.
  """
  @spec scope_asset_workspace(
          Ecto.Queryable.t(),
          binary() | :shared_only | nil,
          binary() | nil
        ) :: Ecto.Queryable.t()
  def scope_asset_workspace(query, nil, _project_id), do: query

  # `:shared_only` — the request-side empty-scope sentinel
  # (task-3e2a70930c6df723). This envelope is a RAW consumer of
  # `Keyword.get(opts, :workspace_id)`: `Media.asset_docs_for_files/3` is called
  # with `scope_opts(conn)` verbatim at `v1/media_controller.ex:34`,
  # `v1/media_collections_controller.ex:57,123` and
  # `federated_search_controller.ex:143`, so a request that resolved no
  # workspace delivers the atom straight into these clauses. Untranslated it
  # matched none of them — FunctionClauseError, a 500 on each of those doors.
  #
  # SHARED LAYER, never every tenant, and never a collapse to `nil`: the nil
  # clause above is the deliberate global read that returns the query
  # UNTOUCHED, so mapping the sentinel onto it would trade the crash for the
  # cross-tenant asset-metadata leak this envelope exists to close. Placed
  # ABOVE the `is_binary/1` clauses, matching the corrected sibling at
  # `Media.Delivery.Search.join_scope_workspace/3`.
  #
  # No NULL-tolerant OR here, deliberately: the other clauses widen to
  # `is_nil(d.workspace_id)` so legacy unstamped docs stay visible inside their
  # own tenant, and that IS this clause's entire result set already.
  def scope_asset_workspace(query, :shared_only, _project_id),
    do: where(query, [d], is_nil(d.workspace_id))

  def scope_asset_workspace(query, workspace_id, nil) when is_binary(workspace_id) do
    where(query, [d], d.workspace_id == ^workspace_id or is_nil(d.workspace_id))
  end

  def scope_asset_workspace(query, workspace_id, project_id)
      when is_binary(workspace_id) and is_binary(project_id) do
    where(
      query,
      [d],
      is_nil(d.workspace_id) or
        (d.workspace_id == ^workspace_id and
           (is_nil(d.project_id) or d.project_id == ^project_id))
    )
  end

  @doc """
  NULL-tolerant dataset envelope for an asset-doc read, binding against the
  FIRST named binding (`[d]`). Public for the same reason as
  `scope_asset_workspace/3` — `Barkpark.Media.Storage.Relations` reuses it verbatim.

  Resolves the dataset STRING → dataset_id within the read's project scope
  (opts :project_id, else the seeded Default project) and filters by
  d.dataset_id — NULL-tolerant: also matches legacy asset docs that media.ex
  wrote WITHOUT scope (dataset_id NULL, dataset STRING stamped), so the
  default/untenanted read+delete path still resolves them (never-worse).
  The dataset STRING ↔ dataset_id is 1:1 within a project, so the OR never
  crosses datasets. Falls back to the legacy d.dataset STRING filter when no
  dataset row resolves (back-compat / pre-tenancy fixtures). Mirrors
  Barkpark.Content scope_schema_to_dataset/3.
  """
  @spec scope_asset_dataset(Ecto.Queryable.t(), binary(), keyword()) :: Ecto.Queryable.t()
  def scope_asset_dataset(query, dataset, opts) do
    case resolve_dataset_id(dataset, opts) do
      id when is_binary(id) ->
        where(query, [d], d.dataset_id == ^id or (is_nil(d.dataset_id) and d.dataset == ^dataset))

      _ ->
        where(query, [d], d.dataset == ^dataset)
    end
  end

  # Read-only dataset-string → dataset_id resolution. Never creates a dataset on
  # a read/delete path. Returns nil when unresolvable so the caller keeps the
  # legacy STRING filter.
  defp resolve_dataset_id(dataset, opts) when is_binary(dataset) do
    project_id = Barkpark.Tenancy.scope_project_id(opts)

    case project_id && Barkpark.Tenancy.get_dataset(project_id, dataset) do
      %Barkpark.Tenancy.Dataset{id: id} -> id
      _ -> nil
    end
  end

  @spec public_url(%MediaFile{}) :: String.t()
  def public_url(%MediaFile{path: path}), do: "/media/files/#{path}"

  @doc """
  Backfill `mediaAsset` documents for existing blobs without companion docs.

  Returns `{:ok, stats}` with `%{created, skipped, errors}`.
  """
  @spec backfill(String.t(), keyword()) :: {:ok, map()}
  def backfill(dataset, opts \\ []) when is_binary(dataset) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    {created, skipped, errors} =
      dataset
      |> Barkpark.Media.list_files()
      |> Enum.reduce({0, 0, []}, fn file, {c, s, errs} ->
        case find_by_media_file_id(file.id, dataset) do
          %Document{} ->
            {c, s + 1, errs}

          nil ->
            if dry_run? do
              {c + 1, s, errs}
            else
              case ensure_for_upload(file) do
                {:ok, _} -> {c + 1, s, errs}
                {:error, reason} -> {c, s, [{file.id, reason} | errs]}
              end
            end
        end
      end)

    {:ok, %{created: created, skipped: skipped, errors: Enum.reverse(errors)}}
  end

  defp create_draft(%MediaFile{} = file) do
    doc_id = "asset-#{file.id}"

    attrs = %{
      "doc_id" => doc_id,
      "title" => file.original_name || file.filename,
      "status" => "draft",
      "content" => %{
        "mediaFileId" => file.id,
        "bp_asset_kind" => asset_kind(file.mime_type),
        "bp_processing_status" => initial_processing_status(file),
        "fileInfo" => %{
          "url" => public_url(file),
          "path" => file.path,
          "mimeType" => file.mime_type,
          "size" => Integer.to_string(file.size),
          "originalName" => file.original_name,
          "width" => "",
          "height" => ""
        },
        "tags" => []
      }
    }

    Content.create_document(
      @asset_type,
      attrs,
      file.dataset,
      [source: :worker] ++ file_scope_opts(file)
    )
  end

  # Derive the {workspace_id, project_id} write scope from the blob the asset
  # doc belongs to. The %MediaFile{} carries the scope resolved at upload
  # (put_scope_attrs on the blob), so stamping the companion asset DOCUMENT
  # from it keeps the two in the same tenant — closing the gap where the doc
  # landed NULL-workspace while the blob was scoped (barkpark-x56q). Only
  # non-nil scope keys are emitted, so a pre-tenancy blob (nil workspace_id)
  # writes nothing and Content.put_scope_attrs falls back to its Default-scope
  # behaviour — never-worse for legacy uploads.
  @spec file_scope_opts(%MediaFile{}) :: keyword()
  def file_scope_opts(%MediaFile{workspace_id: ws_id, project_id: project_id}) do
    []
    |> maybe_put_scope(:workspace_id, ws_id)
    |> maybe_put_scope(:project_id, project_id)
  end

  defp maybe_put_scope(opts, _key, nil), do: opts
  defp maybe_put_scope(opts, key, value), do: Keyword.put(opts, key, value)

  defp asset_kind(nil), do: "other"

  defp asset_kind(mime) when is_binary(mime) do
    cond do
      String.starts_with?(mime, "image/") -> "image"
      String.starts_with?(mime, "video/") -> "video"
      String.starts_with?(mime, "audio/") -> "audio"
      String.starts_with?(mime, "application/") -> "document"
      true -> "other"
    end
  end

  defp initial_processing_status(%MediaFile{mime_type: mime}) when is_binary(mime) do
    if String.starts_with?(mime, "image/"), do: "processing", else: "ready"
  end

  defp initial_processing_status(_), do: "ready"
end
