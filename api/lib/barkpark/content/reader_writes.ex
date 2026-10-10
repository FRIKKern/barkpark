defmodule Barkpark.Content.ReaderWrites do
  @moduledoc """
  What a READ seat may write (task-97702b326b8bfd6d, owner decision
  2026-10-10, lead ruling "comments = A, narrowed").

  A read seat writes nothing, except on a type whose schema declares
  `reader_writes` (spelled `readerWrites` on the wire), e.g. a Studio comment
  type:

      "readerWrites": {"create": true, "patchFields": ["state", "resolvedAt", "resolvedBy"]}

  On such a type, and only there, a read seat may:

    * `create` (or `createIfNotExists`) a document, when `create` is true;
    * `patch` the listed `patchFields` on anyone's document (resolve a thread);
    * `patch` ANY field of a document it created itself. "Created" is the
      server's record, the actor on the document's first revision, never a
      field in the content such as `authorEmail`;
    * `publish` a document an allowed create or patch touched EARLIER IN THE
      SAME BATCH (the Studio sends create+publish and patch+publish).

  Everything else is refused before any write: any op on an unflagged type,
  `delete`, `unpublish`, `discardDraft`, `createOrReplace`, `replace`, a
  publish on its own, and a patch on someone else's document that touches a
  field outside `patchFields`.

  The mutate door reaches this only through `RequireWritePermission`'s
  reader arm, which admits a caller that can read the workspace but not
  write it. A caller with write access never comes here.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, DraftId, Revision}

  @create_kinds ~w(create createIfNotExists)
  @patch_value_keys ~w(set setIfMissing append prepend inc dec)
  @patch_meta_keys ~w(id type ifRevisionID)

  @doc """
  `:ok` when every mutation in the batch is a write this read seat may make,
  else `{:error, {:reader_write_refused, message}}` naming the first refusal.
  """
  @spec check_batch([map()], String.t(), keyword()) :: :ok | {:error, term()}
  def check_batch([], _dataset, _opts),
    do: {:error, {:reader_write_refused, "a read seat sends at least one mutation"}}

  def check_batch(mutations, dataset, opts) when is_list(mutations) do
    ctx = Keyword.get(opts, :caller_context)

    mutations
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {mutation, i}, touched ->
      case check_one(mutation, dataset, opts, ctx, touched) do
        {:ok, touched} ->
          {:cont, touched}

        {:error, message} ->
          {:halt, {:error, {:reader_write_refused, "mutation #{i}: " <> message}}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _touched -> :ok
    end
  end

  defp check_one(%{} = mutation, dataset, opts, ctx, touched) when map_size(mutation) == 1 do
    [{kind, body}] = Map.to_list(mutation)
    check_kind(kind, body, dataset, opts, ctx, touched)
  end

  defp check_one(_mutation, _dataset, _opts, _ctx, _touched),
    do: {:error, "a read seat sends one mutation per object"}

  defp check_kind(kind, %{} = body, dataset, opts, _ctx, touched) when kind in @create_kinds do
    type = body["_type"] || body["type"]
    id = body["_id"] || body["id"]

    with {:ok, rw} <- reader_writes(type, dataset, opts),
         true <- rw["create"] == true || {:error, "readerWrites on #{type} does not allow create"},
         true <- is_binary(id) || {:error, "a read seat must name the _id it creates"} do
      {:ok, MapSet.put(touched, {type, DraftId.published_id(id)})}
    end
  end

  defp check_kind("patch", %{"id" => id, "type" => type} = body, dataset, opts, ctx, touched)
       when is_binary(id) do
    with {:ok, rw} <- reader_writes(type, dataset, opts),
         :ok <- patch_allowed(body, rw, id, type, dataset, opts, ctx) do
      {:ok, MapSet.put(touched, {type, DraftId.published_id(id)})}
    end
  end

  defp check_kind("publish", %{"id" => id, "type" => type}, _dataset, _opts, _ctx, touched)
       when is_binary(id) do
    if MapSet.member?(touched, {type, DraftId.published_id(id)}),
      do: {:ok, touched},
      else:
        {:error,
         "a read seat may publish only a document it created or patched in the same batch"}
  end

  defp check_kind(kind, _body, _dataset, _opts, _ctx, _touched),
    do: {:error, "a read seat may not #{kind}"}

  # The type's grant, or a refusal. An unflagged type grants nothing.
  defp reader_writes(type, dataset, opts) when is_binary(type) do
    case Content.resolve_schema(type, dataset, Keyword.take(opts, [:workspace_id, :project_id])) do
      {:ok, %{reader_writes: %{} = rw}} -> {:ok, rw}
      _ -> {:error, "type #{type} does not allow writes from a read seat"}
    end
  end

  defp reader_writes(_type, _dataset, _opts), do: {:error, "the mutation names no type"}

  defp patch_allowed(body, rw, id, type, dataset, opts, ctx) do
    touched = patched_fields(body)
    allowed = rw["patchFields"] || []

    cond do
      touched == :unknown ->
        if creator?(ctx, id, type, dataset, opts),
          do: :ok,
          else:
            {:error, "a read seat may only set, unset or add to fields of someone else's #{type}"}

      touched -- allowed == [] ->
        :ok

      creator?(ctx, id, type, dataset, opts) ->
        :ok

      true ->
        {:error,
         "a read seat may change only #{Enum.join(allowed, ", ")} on someone else's #{type} " <>
           "(this patch touches #{Enum.join(touched -- allowed, ", ")})"}
    end
  end

  # The TOP-LEVEL field names a patch writes, or `:unknown` for an op whose
  # targets this reader cannot name (then only the creator may send it).
  defp patched_fields(body) do
    extra = Map.keys(body) -- (@patch_value_keys ++ @patch_meta_keys ++ ["unset"])

    if extra != [] do
      :unknown
    else
      from_maps =
        @patch_value_keys
        |> Enum.flat_map(fn key ->
          case Map.get(body, key) do
            %{} = m -> Map.keys(m)
            nil -> []
            _ -> [:bad]
          end
        end)

      from_unset =
        case Map.get(body, "unset") do
          nil -> []
          list when is_list(list) -> list
          _ -> [:bad]
        end

      paths = from_maps ++ from_unset

      if Enum.all?(paths, &is_binary/1),
        do: paths |> Enum.map(&top_segment/1) |> Enum.uniq(),
        else: :unknown
    end
  end

  defp top_segment(path), do: path |> String.split([".", "["], parts: 2) |> hd()

  # THE SERVER'S RECORD of who created the document: the actor on its earliest
  # revision, across both the draft and the published id.
  defp creator?(%CallerContext{} = ctx, id, _type, dataset, opts) do
    ids = [DraftId.published_id(id), DraftId.draft_id(id)]

    first =
      from(r in Revision,
        where: r.doc_id in ^ids and r.dataset == ^dataset,
        order_by: [asc: r.inserted_at, asc: r.id],
        limit: 1,
        select: %{kind: r.actor_kind, id: r.actor_id, user_id: r.actor_user_id}
      )
      |> in_workspace(Keyword.get(opts, :workspace_id))
      |> Repo.one()

    stamp = CallerContext.actor_stamp(ctx)

    case first do
      %{kind: kind, id: actor_id} when is_binary(actor_id) and kind != "anonymous" ->
        (kind == stamp.actor_kind and actor_id == stamp.actor_id) or
          same_user?(first, ctx)

      %{} ->
        same_user?(first, ctx)

      nil ->
        false
    end
  end

  defp creator?(_ctx, _id, _type, _dataset, _opts), do: false

  # Fail closed: a write with no resolved workspace matches only shared-layer
  # revisions, never another tenant's.
  defp in_workspace(query, ws) when is_binary(ws),
    do: from(r in query, where: r.workspace_id == ^ws)

  defp in_workspace(query, _ws), do: from(r in query, where: is_nil(r.workspace_id))

  defp same_user?(%{user_id: uid}, %CallerContext{user_id: uid}) when is_binary(uid), do: true
  defp same_user?(_first, _ctx), do: false
end
