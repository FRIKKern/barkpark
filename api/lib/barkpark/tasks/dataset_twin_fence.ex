defmodule Barkpark.Tasks.DatasetTwinFence do
  @moduledoc """
  THE PRODUCER half of THE ONE RULE (task-49eef068420df918 C2).

  `Barkpark.Tasks.TwinResolver` is the reader's half: one id, one row, and a
  cross-dataset tie is refused rather than picked. This is the writer's: **stop
  making the tie**.

  ## The rule

  A `type:task` BIRTH of a doc_id into dataset D is refused when a row with the
  same `(doc_id, type)` already exists in a DIFFERENT dataset of the same
  workspace + project — unless the write states the intent explicitly with
  `content.dataset_twin_intended: true`.

  ## What made the eleven live twins

  Measured on guerrilla (task-49eef068420df918): ten creates at
  2026-08-07 08:19:35-37 into dataset `aker-brygge` of ids that already existed
  published in `production`, by an operator re-creating a tree by hand after
  `bp -p aker-brygge -d production` had written into the global `production`
  store. Not a race, not a draft fork, not a migration — dataset addressing is
  name-only and unnamespaced by project, and NOTHING on the create path looked at
  a sibling dataset. `bp -d <new-name> doc create task <existing-id>` reproduces
  it on today's main.

  ## Why the unique index cannot do this

  `(doc_id, type, dataset_id)` (migration 20260527134000) makes the pair LEGAL by
  construction — that is the point of the index, and it is UNCHANGED here.
  Narrowing it to `(doc_id, type)` would forbid the legitimate case (one id, one
  copy per dataset, deliberately) and would fail closed on data that already
  exists. The refusal belongs where intent can be stated, not in a constraint that
  cannot hear one.

  ## Scoped to `type:task`, deliberately

  The rule is NOT type-agnostic, because the defect is not. What makes a second
  copy dangerous is that the task doors are dataset-BLIND by design: `bp task
  get`, `bp task claim`, `ready`, the graph root resolver all take a bare id and
  no dataset (`bp task get <id>` names none, and that is the ergonomics the CLI
  wants). Every other type reaches its rows through the dataset-ADDRESSED doc
  doors (`/v1/data/doc/:dataset/:type/:id`, `/v1/data/mutate/:dataset`), where a
  second copy in another dataset is not ambiguous — it is the dataset feature
  working. Content replication across datasets is an ordinary, supported thing;
  a task in two datasets is a claim that can be lost.

  ## Exemptions, each one measured against a sibling guard

    * **Not a birth.** Head-matches `prev_doc == nil`, exactly like
      `Tasks.Dedup.check_new_task/5` and the two birth guards beside it, so every
      UPDATE (autosave, patch merge, publish, revision restore) is structurally
      untouched.
    * **`source != :api`.** Replication mirrors upstream verbatim — the same
      exemption every sibling in `Content.Writer` takes. `:source` is server-set,
      so a request body cannot reach it.
    * **The DRAFT/PUBLISHED pair of one id in ONE dataset.** Not a twin in this
      module's sense and not refused: `drafts.<id>` and `<id>` are the same row's
      two lifecycle spellings, which is why the sibling lookup compares
      `Content.published_id/1` on both sides and only ever fires ACROSS datasets.
    * **The stated intent.** `content.dataset_twin_intended: true` passes. The
      escape is deliberate and follows `content.dedup_bypass`'s precedent: a
      guard with no way to say "yes, I mean it" gets routed around instead of
      answered, and the next producer is a copy of this one with the fence
      disabled.
  """

  import Ecto.Query, warn: false

  alias Barkpark.Content.{Document, DraftId}
  alias Barkpark.Repo

  @doc """
  Refuse a `type:task` birth whose id already lives in a sibling dataset.

  Returns `:ok` or `{:error, {:dataset_twin, details}}` — `Content.Errors` renders
  it as a 409 `dataset_twin` naming every dataset that already holds the id.
  """
  @spec check(
          String.t() | nil,
          map(),
          String.t(),
          String.t() | nil,
          Document.t() | nil,
          keyword()
        ) :: :ok | {:error, {:dataset_twin, map()}}
  def check(type, attrs, dataset, doc_id, prev_doc, opts)

  def check("task", attrs, dataset, doc_id, nil = _prev_doc, opts)
      when is_binary(doc_id) and is_binary(dataset) do
    cond do
      Keyword.get(opts, :source, :api) != :api -> :ok
      intended?(attrs) -> :ok
      true -> refuse_if_sibling(attrs, dataset, doc_id, opts)
    end
  end

  def check(_type, _attrs, _dataset, _doc_id, _prev_doc, _opts), do: :ok

  defp refuse_if_sibling(attrs, dataset, doc_id, opts) do
    pub_id = DraftId.published_id(doc_id)
    workspace_id = Keyword.get(opts, :workspace_id) || Map.get(attrs, "workspace_id")
    project_id = Keyword.get(opts, :project_id) || Map.get(attrs, "project_id")

    case sibling_datasets(pub_id, dataset, workspace_id, project_id) do
      [] ->
        :ok

      datasets ->
        {:error,
         {:dataset_twin,
          %{
            doc_id: pub_id,
            dataset: dataset,
            datasets: datasets,
            message:
              "task #{pub_id} already exists in dataset(s) #{Enum.join(datasets, ", ")} of this " <>
                "workspace/project; a second copy in #{dataset} would make the id ambiguous for " <>
                "every by-id task reader",
            advise:
              "write to the dataset that already holds it, use a different _id, or resend with " <>
                "content.dataset_twin_intended: true"
          }}}
    end
  end

  # Every dataset OTHER than the one being written that holds this id (either
  # spelling) inside the same workspace + project. `nil` scope compares as `nil`
  # — the global store is one tenant here, exactly as the by-id readers see it.
  defp sibling_datasets(pub_id, dataset, workspace_id, project_id) do
    ids = [pub_id, DraftId.draft_id(pub_id)]

    from(d in Document,
      where: d.doc_id in ^ids and d.type == "task" and d.dataset != ^dataset,
      select: d.dataset,
      distinct: true
    )
    |> scope_eq(:workspace_id, workspace_id)
    |> scope_eq(:project_id, project_id)
    |> Repo.all()
    |> Enum.sort()
  end

  defp scope_eq(query, field, nil), do: from(d in query, where: is_nil(field(d, ^field)))
  defp scope_eq(query, field, value), do: from(d in query, where: field(d, ^field) == ^value)

  defp intended?(attrs) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}

    Map.get(content, "dataset_twin_intended") == true or
      Map.get(content, :dataset_twin_intended) == true
  end
end
