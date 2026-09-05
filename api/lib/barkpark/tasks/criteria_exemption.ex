defmodule Barkpark.Tasks.CriteriaExemption do
  @moduledoc """
  ONE definition of "this row is a container, not a unit of work", shared by
  every gate in the acceptance-criteria family.

  ## Why this is a module and not a private function

  It was a private `close_artifact_exempt?/1` inside `Tasks.Close`, which was
  correct while exactly one gate consulted it. A second gate now does — the
  claim-time check from task-9554c64bf51a0f81 — and the cheap move would have
  been to write the four predicates out again next to it.

  Two lists that must agree are a divergence waiting to happen. This repo spent
  a night on predicates that had already drifted from their own documentation
  (`stage.ex`'s lock key) and on three verbs answering "is this a merge gate"
  three different ways. A shared definition is not tidiness; it is the only
  thing that makes "the close door and the claim door agree about what a
  container is" a fact rather than a hope.

  ## NOT in `Tasks.Criteria`

  That module's moduledoc says "Pure functions, no DB", and `has_children?/1`
  runs a query. Putting it there would have made that sentence false, which is
  the exact defect class this repo has been paying down.

  ## The four exemptions

    * the row already HAS acceptance criteria — then it is the criteria gate's
      business, never this family's;
    * a non-task `kind`;
    * a `decision` or `goal` label SEGMENT;
    * somebody names this row as their parent.
  """

  import Ecto.Query, warn: false

  alias Barkpark.Content.{Document, DraftId}
  alias Barkpark.Repo

  @doc """
  Is this row exempt from the "state your acceptance criteria" family of gates?

  Exempt when it already HAS criteria, or when it is a container rather than a
  unit of work: a non-task kind, a `decision`/`goal` label segment, or a row
  somebody names as their parent.
  """
  @spec exempt?(Document.t()) :: boolean()
  def exempt?(%Document{content: content} = doc) do
    content = content || %{}

    has_criteria?(content) or not task_kind?(content) or container_label?(content) or
      has_children?(doc)
  end

  defp has_criteria?(content) do
    case Map.get(content, "acceptance_criteria") do
      list when is_list(list) -> list != []
      _ -> false
    end
  end

  # `Validation.kinds/0` is `~w(task)` — "task" is the ONLY kind a validated row
  # can carry, so an ABSENT `kind` is a task ("Everything is a task", schema.ex),
  # not an exemption. Reading a missing key as exempt would make this gate
  # vacuous over every legacy row, which is the population it exists for.
  defp task_kind?(content) do
    case Map.get(content, "kind") do
      nil -> true
      kind when is_binary(kind) -> String.downcase(String.trim(kind)) == "task"
      _ -> false
    end
  end

  # Label matching is SEGMENT-wise on `:`, not substring. TASK-SYSTEM.md §5's own
  # vocabulary is `phase:<goal|design|decision|build|verify>` plus the bare
  # `decision` gate label, so `decision`, `phase:goal` and `kind:decision` all
  # exempt — while `proj:goalkeeper-rewrite` does NOT. A substring rule would
  # hand that row a SILENT permit, and a silent permit is the failure mode this
  # whole family of gates exists to end; a false refusal is loud and recoverable.
  defp container_label?(content) do
    content
    |> Map.get("labels")
    |> List.wrap()
    |> Enum.any?(fn
      label when is_binary(label) ->
        label
        |> String.split(":")
        |> Enum.any?(&(String.downcase(String.trim(&1)) in ~w(decision goal)))

      _ ->
        false
    end)
  end

  # Does anybody name this row as their parent? Same prefix-agnostic predicate
  # `Params.maybe_filter_parent_id/2` and `batch_child_counts/2` match on
  # (`regexp_replace(…, '^drafts\.', '')`), so this agrees with the `child_count`
  # a reader sees on `bp task get <id>`. Scoped to the ROW'S OWN
  # workspace/project/dataset — an unscoped existence check would let another
  # tenant's child hand this row an exemption it did not earn.
  #
  # Deliberately the LAST predicate in `close_artifact_exempt?/1`: it is the only
  # one that touches the DB, and `or` short-circuits, so a row with criteria, a
  # non-task kind, or a container label never pays for it.
  defp has_children?(%Document{doc_id: doc_id} = doc) when is_binary(doc_id) do
    key = DraftId.published_id(doc_id)

    from(d in Document,
      where: d.type == "task",
      where: d.dataset == ^doc.dataset,
      where: fragment("regexp_replace(?->>'parent_id', '^drafts\\.', '')", d.content) == ^key
    )
    |> scope_children(doc)
    |> Repo.exists?()
  end

  defp has_children?(_doc), do: false

  defp scope_children(query, %Document{workspace_id: nil, project_id: nil}), do: query

  defp scope_children(query, %Document{workspace_id: ws, project_id: nil}),
    do: from(d in query, where: d.workspace_id == ^ws)

  defp scope_children(query, %Document{workspace_id: nil, project_id: pr}),
    do: from(d in query, where: d.project_id == ^pr)

  defp scope_children(query, %Document{workspace_id: ws, project_id: pr}),
    do: from(d in query, where: d.workspace_id == ^ws and d.project_id == ^pr)
end
