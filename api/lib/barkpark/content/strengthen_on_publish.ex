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
      and `_strengthenOnPublish`. Its other keys stay. When the marker names
      a `type`, the published target must be of that type. A marker with
      `weak: true` (the field is declared weak) loses only itself; `_weak`
      stays;
    * when the target has no published version, the object is left exactly
      as it was;
    * an object without `_strengthenOnPublish` is never touched, even when it
      is `_weak: true`: a weak reference the author chose stays weak.

  All targets in one document are looked up in ONE query. A document with no
  waiting reference runs no query at all. Targets are read once at the
  publish door, before the publish transaction.

  ## Whose targets count

  The tenant scope is the one `ReferenceIntegrity` reads with, so the two
  answers about one reference never disagree: a request workspace (and its
  project, when the request names one) scopes the read; `:shared_only` reads
  the shared layer (`workspace_id IS NULL`); a publish whose opts name no
  workspace strengthens nothing. Failing closed leaves the reference weak,
  which is what it was before this module existed.
  """

  import Ecto.Query, only: [from: 2]
  import Barkpark.Content.Scope, only: [scope_to_workspace: 3]

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @marker "_strengthenOnPublish"
  @dropped ["_weak", @marker]

  @doc """
  `draft` with every waiting reference whose target is published made strong.
  `opts` carries the publish's scope (`:workspace_id`, `:project_id`).
  """
  @spec strengthen(Document.t(), String.t(), keyword()) :: Document.t()
  def strengthen(%Document{content: content} = draft, dataset, opts)
      when is_map(content) and is_binary(dataset) do
    case content |> waiting_refs([]) |> Enum.uniq() do
      [] ->
        draft

      refs ->
        published = published_types(refs, dataset, opts)

        if map_size(published) == 0,
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

  defp strong(%{@marker => marker, "_ref" => ref} = node, published) when is_binary(ref) do
    node =
      cond do
        not published?(published, ref, marker) -> node
        declared_weak?(marker) -> Map.delete(node, @marker)
        true -> Map.drop(node, @dropped)
      end

    Map.new(node, fn {key, value} -> {key, strong(value, published)} end)
  end

  defp strong(%{} = node, published),
    do: Map.new(node, fn {key, value} -> {key, strong(value, published)} end)

  defp strong(list, published) when is_list(list), do: Enum.map(list, &strong(&1, published))
  defp strong(leaf, _published), do: leaf

  # A marker that names a type only matches a published target of that type.
  defp published?(published, ref, %{"type" => type}) when is_binary(type),
    do: type in Map.get(published, ref, [])

  defp published?(published, ref, _marker), do: Map.has_key?(published, ref)

  defp declared_weak?(%{"weak" => true}), do: true
  defp declared_weak?(_marker), do: false

  # The published rows among `refs`, in the publish's dataset and tenant, as
  # `%{doc_id => [type]}`. A row whose id has no `drafts.` prefix IS the
  # published version, so a `drafts.` ref is never looked up.
  defp published_types(refs, dataset, opts) do
    ids = Enum.reject(refs, &String.starts_with?(&1, "drafts."))

    case {ids, scope(opts)} do
      {[], _} ->
        %{}

      {_, :none} ->
        %{}

      {ids, {workspace_id, project_id}} ->
        from(d in Document,
          where: d.dataset == ^dataset and d.doc_id in ^ids,
          select: {d.doc_id, d.type}
        )
        |> scope_to_workspace(workspace_id, project_id)
        |> Repo.all()
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    end
  end

  # `ReferenceIntegrity.referrers/3`'s scope: fail closed with no workspace.
  defp scope(opts) do
    project_id = Keyword.get(opts, :project_id)

    case Keyword.get(opts, :workspace_id) do
      ws when is_binary(ws) and is_binary(project_id) -> {ws, project_id}
      ws when is_binary(ws) -> {ws, nil}
      :shared_only -> {:shared_only, nil}
      _ -> :none
    end
  end
end
