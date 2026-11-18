defmodule Barkpark.Content.StrengthenOnPublish do
  @moduledoc """
  Publish turns a waiting weak reference strong (task-3fa8b7a435a9ed83).

  An editor can pick a reference to a document that has no published version
  yet. The draft then stores it weak, marked to be strengthened later:

      {"_ref": "a", "_weak": true, "_strengthenOnPublish": {"type": "author"}}

  Sanity's Content Lake strengthens such a reference on every publish, and so
  does this module, for every publish the server runs
  (`Content.Lifecycle.publish_draft/5`): the mutate `publish` action, the
  direct publish, the bp CLI, Studio's buttons and scheduled publishes.

  The rule:

    * an object holding `_strengthenOnPublish` whose `_ref` names a document
      with a published version, in the same dataset and tenant, loses `_weak`
      and `_strengthenOnPublish`. Its other keys stay;
    * when the target has no published version, the object is left exactly
      as it was;
    * an object without `_strengthenOnPublish` is never touched, even when it
      is `_weak: true`: a weak reference the author chose stays weak.

  All targets in one document are looked up in ONE query. A document with no
  waiting reference runs no query at all.
  """

  import Ecto.Query, only: [from: 2]
  import Barkpark.Content.Scope, only: [scope_to_workspace: 3]

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @marker "_strengthenOnPublish"
  @dropped ["_weak", @marker]

  @doc """
  `draft` with every waiting reference whose target is published made strong.
  `opts` carries the publish's scope (`:workspace_id`, `:project_id`); when it
  names no workspace, the draft's own workspace is used.
  """
  @spec strengthen(Document.t(), String.t(), keyword()) :: Document.t()
  def strengthen(%Document{content: content} = draft, dataset, opts)
      when is_map(content) and is_binary(dataset) do
    case content |> waiting_refs([]) |> Enum.uniq() do
      [] ->
        draft

      refs ->
        published = published_ids(refs, dataset, scope(draft, opts))

        if MapSet.size(published) == 0,
          do: draft,
          else: %{draft | content: strong(content, published)}
    end
  end

  def strengthen(%Document{} = draft, _dataset, _opts), do: draft

  # Every `_ref` of an object that carries the marker, at any depth.
  defp waiting_refs(%{} = node, acc) do
    acc =
      case node do
        %{@marker => _, "_ref" => ref} when is_binary(ref) and ref != "" -> [ref | acc]
        _ -> acc
      end

    Enum.reduce(node, acc, fn {_key, value}, acc -> waiting_refs(value, acc) end)
  end

  defp waiting_refs(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &waiting_refs/2)

  defp waiting_refs(_leaf, acc), do: acc

  defp strong(%{@marker => _, "_ref" => ref} = node, published) when is_binary(ref) do
    node =
      if MapSet.member?(published, ref),
        do: Map.drop(node, @dropped),
        else: node

    Map.new(node, fn {key, value} -> {key, strong(value, published)} end)
  end

  defp strong(%{} = node, published),
    do: Map.new(node, fn {key, value} -> {key, strong(value, published)} end)

  defp strong(list, published) when is_list(list), do: Enum.map(list, &strong(&1, published))
  defp strong(leaf, _published), do: leaf

  # The published rows among `refs`, in the publish's dataset and tenant. A row
  # whose id has no `drafts.` prefix IS the published version, so a `drafts.`
  # ref is never looked up.
  defp published_ids(refs, dataset, {workspace_id, project_id}) do
    ids = Enum.reject(refs, &String.starts_with?(&1, "drafts."))

    if ids == [] do
      MapSet.new()
    else
      from(d in Document,
        where: d.dataset == ^dataset and d.doc_id in ^ids,
        select: d.doc_id
      )
      |> scope_to_workspace(workspace_id, project_id)
      |> Repo.all()
      |> MapSet.new()
    end
  end

  # The tenant the published row lands in. The request scope first; a caller
  # with no workspace (an internal publish) uses the draft's own. A document
  # with neither lives in the shared layer, and so must its targets:
  # `:shared_only` reads `workspace_id IS NULL`, never every tenant.
  defp scope(%Document{workspace_id: draft_ws}, opts) do
    project_id = Keyword.get(opts, :project_id)

    case Keyword.get(opts, :workspace_id) do
      ws when is_binary(ws) and is_binary(project_id) -> {ws, project_id}
      ws when is_binary(ws) -> {ws, nil}
      :shared_only -> {:shared_only, nil}
      _ when is_binary(draft_ws) -> {draft_ws, nil}
      _ -> {:shared_only, nil}
    end
  end
end
