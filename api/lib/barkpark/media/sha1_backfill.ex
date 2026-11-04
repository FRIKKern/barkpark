defmodule Barkpark.Media.Sha1Backfill do
  @moduledoc """
  The HTTP form of `Barkpark.Media.backfill_sha1/1`, for a box nobody has a
  shell on. `POST /v1/admin/media/sha1-backfill` calls it, and Barkpark Cloud
  calls that route for `bp barkparks backfill-media-sha1`.

  `plan/0` is the dry run. It counts the `media_files` rows whose `sha1` is
  NULL, per workspace and dataset, and reads no blob.

  `run/1` hashes one page. It walks the NULL rows by id after the `:after`
  cursor and stops at `:limit` rows or when `:budget_ms` has passed, so one
  request stays inside Cloud's 15 s call timeout. It writes only `sha1`, the
  same write `Barkpark.Media.backfill_sha1/1` makes. A blob that cannot be
  read stays NULL and is listed in `failed` with its reason. The cursor moves
  past it, so a caller that follows `next_after` until it is `nil` visits
  every row once.
  """

  import Ecto.Query

  alias Barkpark.{Media, Repo}
  alias Barkpark.Media.Blobstore
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Tenancy.Workspace

  @default_limit 200
  @max_limit 500
  @default_budget_ms 8_000

  def max_limit, do: @max_limit

  @doc """
  Count the rows with no `sha1`. Returns `%{unhashed: n, datasets: [%{workspace:,
  dataset:, unhashed:}]}`. Reads no blob and writes nothing.
  """
  @spec plan() :: %{unhashed: non_neg_integer(), datasets: [map()]}
  def plan do
    datasets =
      from(m in MediaFile,
        left_join: w in Workspace,
        on: w.id == m.workspace_id,
        where: is_nil(m.sha1),
        group_by: [w.slug, m.dataset],
        order_by: [asc: w.slug, asc: m.dataset],
        select: %{workspace: w.slug, dataset: m.dataset, unhashed: count(m.id)}
      )
      |> Repo.all()

    %{unhashed: Enum.sum(Enum.map(datasets, & &1.unhashed)), datasets: datasets}
  end

  @doc """
  Hash one page of rows with no `sha1`. Options: `:after` (a media file id, the
  cursor), `:limit` (1 to #{@max_limit}, default #{@default_limit}), `:budget_ms`
  (default #{@default_budget_ms}). Returns `%{hashed:, failed:, next_after:,
  unhashed:}`. `next_after` is `nil` when no row with no `sha1` is left after
  this page. `unhashed` counts every row still without `sha1`, failures included.
  """
  @spec run(keyword()) :: %{
          hashed: non_neg_integer(),
          failed: [map()],
          next_after: String.t() | nil,
          unhashed: non_neg_integer()
        }
  def run(opts \\ []) do
    after_id = Keyword.get(opts, :after)
    limit = (Keyword.get(opts, :limit) || @default_limit) |> min(@max_limit) |> max(1)
    budget = Keyword.get(opts, :budget_ms, @default_budget_ms)
    deadline = System.monotonic_time(:millisecond) + budget

    files =
      from(m in MediaFile,
        left_join: w in Workspace,
        on: w.id == m.workspace_id,
        where: is_nil(m.sha1),
        order_by: [asc: m.id],
        limit: ^limit,
        select: {m, w.slug}
      )
      |> after_cursor(after_id)
      |> Repo.all()

    {hashed, failed, last_id} = hash_until(files, deadline, {0, [], after_id})

    %{
      hashed: hashed,
      failed: Enum.reverse(failed),
      next_after: if(more_after?(last_id), do: last_id, else: nil),
      unhashed: Repo.aggregate(from(m in MediaFile, where: is_nil(m.sha1)), :count)
    }
  end

  defp after_cursor(query, nil), do: query
  defp after_cursor(query, id), do: where(query, [m], m.id > ^id)

  # The first row always runs, so a page makes progress even with no budget.
  defp hash_until([], _deadline, acc), do: acc

  defp hash_until([{file, ws} | rest], deadline, {hashed, failed, _last_id} = acc) do
    if hashed + length(failed) > 0 and System.monotonic_time(:millisecond) >= deadline do
      acc
    else
      acc =
        case hash_one(file) do
          :ok ->
            {hashed + 1, failed, file.id}

          {:error, reason} ->
            row = %{id: file.id, workspace: ws, dataset: file.dataset, reason: reason}
            {hashed, [row | failed], file.id}
        end

      hash_until(rest, deadline, acc)
    end
  end

  defp hash_one(%MediaFile{} = file) do
    with {:ok, local} <- read_blob(file),
         {:ok, sha1} <- hash(local) do
      # The NULL guard keeps a row an upload hashed meanwhile as it is.
      Repo.update_all(where(MediaFile, [m], m.id == ^file.id and is_nil(m.sha1)),
        set: [sha1: sha1]
      )

      :ok
    end
  end

  defp read_blob(file) do
    case Blobstore.ensure_local(file) do
      {:ok, local} -> {:ok, local}
      {:error, :not_found} -> {:error, "blob_not_found"}
      {:error, reason} -> {:error, "blob_unreadable: " <> reason_text(reason)}
    end
  rescue
    e -> {:error, "blob_unreadable: " <> Exception.message(e)}
  end

  defp hash(local) do
    case Media.sha1_file(local) do
      {:ok, sha1} -> {:ok, sha1}
      {:error, reason} -> {:error, "hash_failed: " <> reason_text(reason)}
    end
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason, limit: 5, printable_limit: 120)

  defp more_after?(nil), do: false

  defp more_after?(id) do
    Repo.exists?(from(m in MediaFile, where: is_nil(m.sha1) and m.id > ^id))
  end
end
