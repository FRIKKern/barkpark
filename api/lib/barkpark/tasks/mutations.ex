defmodule Barkpark.Tasks.Mutations do
  @moduledoc false
  # Single-task content mutations that ride the same advisory-lock + CAS-on-rev
  # pattern: `labels` (relabel) and `papers` (paper-refs). Extracted from the
  # `Barkpark.Tasks` facade, which delegates to these. The two functions are
  # twins — identical CAS shape, differing only in the content key + event kind.

  import Ecto.Query, only: [from: 2]

  import Barkpark.Tasks.Internal,
    only: [generate_rev: 0, insert_mutation_event!: 3, task_broadcast: 4, emit_broadcasts: 1]

  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @event_task_relabeled "task.relabeled"
  @event_task_referenced "task.referenced"

  @doc """
  tt5: add/remove `content.labels` entries on a single task, advisory-lock +
  CAS-on-rev guarded, emitting a `task.relabeled` mutation_event. Union add
  (dedup-preserving) minus the remove set; idempotent. Returns `{:ok, doc}`,
  `{:error, :not_found}`, or `{:error, :stale_claim}`.
  """
  @spec relabel_by_id(binary(), [binary()], [binary()]) ::
          {:ok, Document.t()} | {:error, term()}
  def relabel_by_id(task_id, add, remove)
      when is_binary(task_id) and is_list(add) and is_list(remove) do
    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = doc.rev
            current = labels_of(doc.content)
            add = Enum.filter(add, &is_binary/1)
            remove = MapSet.new(Enum.filter(remove, &is_binary/1))

            next =
              (current ++ add)
              |> Enum.uniq()
              |> Enum.reject(&MapSet.member?(remove, &1))

            new_content = Map.put(doc.content, "labels", next)
            new_rev = generate_rev()

            {rows, _} =
              from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
              |> Repo.update_all(
                set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
              )

            case rows do
              1 ->
                updated = %{doc | content: new_content, rev: new_rev}
                ev = insert_mutation_event!(updated, @event_task_relabeled, observed_rev)

                {:ok, updated, [task_broadcast(updated, @event_task_relabeled, ev, observed_rev)]}

              0 ->
                {:error, :stale_claim}
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Phase A: add/remove `content.papers` entries (paper slugs) on a single task,
  advisory-lock + CAS-on-rev guarded, emitting a `task.referenced`
  mutation_event. Mirrors `relabel_by_id/3` — the only difference is the content
  key (`"papers"`) and the event kind. Returns `{:ok, doc}`,
  `{:error, :not_found}`, or `{:error, :stale_claim}`.
  """
  @spec update_paper_refs_by_id(binary(), [binary()], [binary()]) ::
          {:ok, Document.t()} | {:error, term()}
  def update_paper_refs_by_id(task_id, add_slugs, remove_slugs)
      when is_binary(task_id) and is_list(add_slugs) and is_list(remove_slugs) do
    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:#{task_id}"])

        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            observed_rev = doc.rev
            current = papers_of(doc.content)
            add = Enum.filter(add_slugs, &is_binary/1)
            remove = MapSet.new(Enum.filter(remove_slugs, &is_binary/1))

            next =
              (current ++ add)
              |> Enum.uniq()
              |> Enum.reject(&MapSet.member?(remove, &1))

            new_content = Map.put(doc.content, "papers", next)
            new_rev = generate_rev()

            {rows, _} =
              from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
              |> Repo.update_all(
                set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
              )

            case rows do
              1 ->
                updated = %{doc | content: new_content, rev: new_rev}
                ev = insert_mutation_event!(updated, @event_task_referenced, observed_rev)

                {:ok, updated,
                 [task_broadcast(updated, @event_task_referenced, ev, observed_rev)]}

              0 ->
                {:error, :stale_claim}
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # content.labels is a free-form JSON array; content.papers is a slug array.
  # Defensive: coerce non-list / missing to [].
  defp labels_of(%{"labels" => labels}) when is_list(labels), do: labels
  defp labels_of(_), do: []

  defp papers_of(%{"papers" => papers}) when is_list(papers), do: papers
  defp papers_of(_), do: []
end
