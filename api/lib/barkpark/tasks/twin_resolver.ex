defmodule Barkpark.Tasks.TwinResolver do
  @moduledoc """
  THE ONE RULE for resolving a task doc_id to a row (task-49eef068420df918 +
  task-baf9b74a0ffc83f4, main's ruling 2026-09-06: one fix answers both axes).

  ## The rule

  > A task doc_id resolves to **exactly one physical row per read**: the
  > PUBLISHED row in the caller's dataset scope.
  >
  > 1. A `drafts.<id>` twin is **never** the answer — for lifecycle, for a claim,
  >    for anything — while a published `<id>` row exists in scope.
  > 2. `asc: dataset` is **never** a tiebreak. A dataset the caller did not name
  >    may not decide which row they get.
  > 3. When the caller names **no** dataset and more than one row survives at the
  >    winning tier, the task door **REFUSES** — 409, naming every dataset that
  >    holds the id — rather than picking one.
  > 4. No task verb (claim, pulse, stamp, stage, close, release) and no
  >    `Tasks.TtlSweeper` write ever lands on a `drafts.<id>` twin while a
  >    published row exists (enforced at the sweeper's candidate SELECT and, for
  >    every verb, by rule 1 — every verb is claim-fenced and every claim
  >    resolves through this module).

  ## The two axes it collapses, and why one rule had to answer both

  **DATASET axis** (task-49eef068420df918). `documents` is unique on
  `(doc_id, type, dataset_id)`, not `(doc_id, type)` (migration
  20260527134000), so one task doc_id may live in two datasets of one
  workspace/project — measured live: `akbr-feedback-2026-08-epic` in both
  `production` and `aker-brygge`, 11 such pairs on guerrilla. `bp task get`
  carries no dataset discriminator, and both by-id readers
  (`TasksController.fetch_task_exact/3`, `Tasks.Claim.fetch_task_exact/3`) broke
  the tie with `asc: d.dataset` under a `limit: 1`. That order was added to stop
  an `Ecto.MultipleResultsError` 500 (task-0c30e7b99ad87cec / task-ca05dd6a02a0b55f)
  and it did — by converting a loud 500 into a SILENT WRONG-ROW read: "aker-brygge"
  sorts before "production", so `bp task get` answered from the empty copy while
  `bp doc patch` (dataset-addressed, `/v1/data/mutate/:dataset`) wrote the real
  one. Two doors, one id, two rows.

  **DRAFT axis** (task-baf9b74a0ffc83f4). The same shape one prefix over:
  `task-49b5c183f10ad0fc`'s published row read `done`, closed 09:56:20Z, while
  `drafts.task-49b5c183f10ad0fc` read `open` carrying a TtlSweeper reap stamp at
  10:27:00Z — the sweeper reaped a DRAFT twin's claim 31 minutes after the
  published row had been closed by its holder. A reader that lands on the draft
  sees "my claim vanished / the row reopened".

  Fixing one leaves the other live because they are the same defect: a doc_id
  with more than one physical row, and each door picking a side by an accident of
  ordering. So the choice is made ONCE, here, and every door calls it.

  ## Which draft-twin policy won (pds-w29-bl-twin-policy-split)

  That row found four readers with three policies. The winner is the **API/Studio
  board's**: *collapse, published wins* (`Tasks.Board`, `canonical_twin`) —
  because it is the only one of the three that keeps a published row's answer
  stable no matter which door asks, which is the whole content of the rule above.

  Kept, deliberately, from the ready queue's policy: an **unpaired** `drafts.<id>`
  row — no published twin — IS the row of record and resolves as itself. That is
  not a competing policy, it is rule 1 with its premise absent; `Tasks.Dedup`,
  `Tasks.Queue` and `Tasks.DraftTerminalFence` all rest on it, and dropping it
  would make the whole mutate-created population unreadable.

  NOT touched here: the TUI board's no-collapse rendering and
  `bp task next --frontier`'s deliberate `Perspective: "drafts"` (Go, out of this
  fence). Both are DISPLAY/queue-side; neither answers "which row is this id", so
  neither is in this rule's scope. The "no surface labels a row as a draft" half
  of pds-w29 is likewise still open — this module decides which row wins, not how
  a survivor is labelled.

  ## Why REFUSE instead of pick (rule 3)

  A total order (`published, dataset, id`) is deterministic — the same call
  answers the same row every time — but determinism was never the property that
  was missing. The missing property is that the answer be the row the CALLER
  meant, and no ordering can supply it: the tie exists precisely because the
  caller named nothing that distinguishes the rows. A 409 naming both datasets
  hands the caller the one fact they need to disambiguate (`?dataset=`), costs
  the ordinary single-row task nothing (a doc_id with one row in scope reads
  byte-identically), and — unlike the wrong-row read — cannot be mistaken for an
  answer.

  ## Shape

  Callers keep their own tenancy scoping (the controller's fail-open
  `Params.maybe_filter_*` and Claim's fail-closed `Scope.scope_to_workspace` are
  NOT the same semantics, and unifying them is a separate row): this module hands
  out the candidate query, the caller scopes it, and `choose/3` applies the rule
  to the rows that come back.
  """

  import Ecto.Query, warn: false

  alias Barkpark.Content.{DraftId, Document}
  alias Barkpark.Tasks.AmbiguousTwinError

  @doc """
  The candidate query for `doc_id`: every `type == "task"` row that spelling
  could mean, UNSCOPED — the caller applies its own tenancy filters.

  A bare id matches both `<id>` and `drafts.<id>`; an explicit `drafts.` prefix is
  EXACT (the old fallback was never applied in reverse, and still is not). There
  is no `limit` and no ordering that decides anything — `choose/3` does the
  deciding, and it cannot decide from a row the query already dropped.
  """
  @spec candidates_query(String.t()) :: Ecto.Query.t()
  def candidates_query(doc_id) when is_binary(doc_id) do
    ids = spellings(doc_id)

    from(d in Document,
      where: d.doc_id in ^ids and d.type == "task",
      order_by: [asc: d.id]
    )
  end

  @doc """
  Apply the rule to the candidate rows.

  Options:

    * `:dataset` — the dataset the caller named. When given, rows from every
      other dataset are dropped BEFORE the rule runs, so a caller who says where
      they mean can never be refused for a twin they did not ask about.

  Returns `{:ok, doc}` or `{:error, :not_found}`, and RAISES
  `Barkpark.Tasks.AmbiguousTwinError` for rule 3.
  """
  @spec choose([Document.t()], String.t(), keyword()) ::
          {:ok, Document.t()} | {:error, :not_found}
  def choose(rows, doc_id, opts \\ []) when is_list(rows) and is_binary(doc_id) do
    rows =
      case Keyword.get(opts, :dataset) do
        ds when is_binary(ds) and ds != "" -> Enum.filter(rows, &(&1.dataset == ds))
        _ -> rows
      end

    case winning_tier(rows) do
      [] ->
        {:error, :not_found}

      [only] ->
        {:ok, only}

      many ->
        raise AmbiguousTwinError.new(DraftId.published_id(doc_id), Enum.map(many, & &1.dataset))
    end
  end

  @doc """
  `candidates_query/1` |> `scope_fun` |> repo read |> `choose/3` — the whole rule
  in one call, for the doors whose scoping is a single function.
  """
  @spec resolve(
          String.t(),
          (Ecto.Query.t() -> Ecto.Query.t()),
          (Ecto.Query.t() -> [Document.t()]),
          keyword()
        ) ::
          {:ok, Document.t()} | {:error, :not_found}
  def resolve(doc_id, scope_fun, read_fun, opts \\ []) do
    doc_id
    |> candidates_query()
    |> scope_fun.()
    |> read_fun.()
    |> choose(doc_id, opts)
  end

  @doc """
  Rule 3 for the TYPE-AGNOSTIC doors — the graph root resolver
  (`BarkparkWeb.TasksController.resolve_graph_root/2`) and
  `Barkpark.Content.Graph.resolve_doc/3`, the canonical slug resolver for EVERY
  type.

  Those doors are not task doors, so they cannot use `choose/3`: a second copy
  of a NON-task document in another dataset is content replication working as
  designed, and re-tiering their rows would change which row a non-task id
  resolves to. This helper therefore does TWO things and no more:

    * it decides only whether the door may answer at all — the caller's own
      ordering still picks the row, so every non-task read stays byte-identical;
    * it refuses ONLY the task case — the `type == "task"` rows this id names,
      at the winning SPELLING tier (a published bare-id row outranks a
      `drafts.` twin, rule 1), spanning more than one dataset, with no dataset
      named by the caller.

  Returns `:ok`, or RAISES `Barkpark.Tasks.AmbiguousTwinError` (rule 3 — 409
  `ambiguous_dataset`, naming every dataset that holds the id). It raises for
  the same reason the task doors do: each of these doors' callers collapses a
  `nil`/`{:error, _}` into "not found", which is the silent-wrong-answer family
  one level up.
  """
  @spec refuse_ambiguous_task!([Document.t()], String.t(), String.t() | nil) :: :ok
  def refuse_ambiguous_task!(rows, doc_id, dataset \\ nil)

  def refuse_ambiguous_task!(_rows, _doc_id, dataset)
      when is_binary(dataset) and dataset != "",
      do: :ok

  def refuse_ambiguous_task!(rows, doc_id, _dataset) when is_list(rows) do
    datasets =
      rows
      |> Enum.filter(&(&1.type == "task"))
      |> winning_spelling_tier()
      |> Enum.map(& &1.dataset)
      |> Enum.uniq()

    if length(datasets) > 1 do
      raise AmbiguousTwinError.new(DraftId.published_id(doc_id), datasets)
    else
      :ok
    end
  end

  # The winning tier for a door that orders only on spelling (`drafts.` last):
  # bare-id rows when any exist, the `drafts.` twins otherwise. Deliberately
  # coarser than `tier/1` — these doors never split on `status`, and giving them
  # that split here would change a non-task read.
  defp winning_spelling_tier(rows) do
    case Enum.reject(rows, &draft_spelling?/1) do
      [] -> rows
      bare -> bare
    end
  end

  defp draft_spelling?(%Document{doc_id: "drafts." <> _}), do: true
  defp draft_spelling?(%Document{}), do: false

  # A bare id means either spelling; an explicit `drafts.` prefix means itself.
  defp spellings("drafts." <> _ = draft_id), do: [draft_id]
  defp spellings(doc_id), do: [doc_id, DraftId.draft_id(doc_id)]

  # The tiers, best first. Only the BEST non-empty tier can answer, so a draft
  # twin never outranks a published row (rule 1) and the loser is never consulted
  # for a tiebreak.
  #
  #   0 — published spelling, `status == "published"`: the row of record.
  #   1 — published spelling, any other status: an unpublished bare-id row. Ranked
  #       above a draft twin because it is still the id the caller asked for.
  #   2 — the `drafts.<id>` twin: the answer ONLY when no bare-id row exists
  #       (the unpaired-draft carve-out).
  #
  # Every row within one tier shares a doc_id spelling, and `(doc_id, type,
  # dataset_id)` is unique — so a tier with more than one row is exactly the
  # cross-dataset twin, and its members differ by `dataset`. That is what makes
  # naming the datasets in the refusal both possible and complete.
  defp winning_tier([]), do: []

  defp winning_tier(rows) do
    by_tier = Enum.group_by(rows, &tier/1)
    best = by_tier |> Map.keys() |> Enum.min()
    Map.fetch!(by_tier, best)
  end

  defp tier(%Document{doc_id: "drafts." <> _}), do: 2
  defp tier(%Document{status: "published"}), do: 0
  defp tier(%Document{}), do: 1
end
