defmodule Barkpark.Tasks.CriteriaRequiredFence do
  @moduledoc """
  THE CRITERIA-REQUIRED BIRTH FENCE, OPT-IN PER PARENT
  (dr-w33-bl-task-create-refuses-criteria-less-rows).

  A task row with no acceptance criteria is not "0/N unfinished" — it is
  UNFALSIFIABLE. Every met-flip is matched on a criterion's stored text
  (`Tasks.Internal.resolve_criterion_index/2`), so a row with an empty list has
  nothing that can ever be stamped, and `0 of 0` reads to every completeness
  audit as vacuously complete. `dr-w32-s4-followup-prove-the-first-run-path-live`
  had to be closed on run ids rather than on its criteria for exactly this
  reason.

  ## Why a WRITE-SIDE refusal and not a fifth backfill

  The disease has been CENSUSED three times in twenty-four hours and BACKFILLED
  three times, and it regressed every time: seven rows on 2026-08-08, all six
  live ones backfilled; six BRAND-NEW rows on 2026-08-09 with ZERO overlap,
  four of them filed within nine hours, one p0. `dr-w19`'s own prose predicted
  it in writing — "the census COUNTS the disease; nothing REFUSES the write. A
  backfill that does not become a gate is a one-time sweep." Nothing in the tree
  refused it: `Barkpark.Plugins.Tasks.warn_if_create_zero/1` emits a
  `Logger.warning` + a `Warnings.put` advisory and SAVES, and
  `Validation.check_acceptance_criteria/2` returns `errors` untouched on `nil`.
  An advisory that has been ignored 163 times in one week on one lane is not a
  gate.

  ## THE SCOPING DECISION (lead-cli, 2026-09-09) — OPT-IN PER PARENT

  A GLOBAL refusal was explicitly refused by the row: "this is a tasks-plugin
  governance change that binds every epic on the server, not just this one …
  probably opt-in per parent rather than global, or the refusal will break other
  epics' filing mid-flight." Measured shape of that risk: 163 of 975 rows
  (16.7%) were born criteria-less in one week on ONE lane — a global switch
  turns every one of those creates into a 422 for lanes that never agreed to it.

  So the flag lives on THE PARENT, and the parent's own author turns it on when
  that epic is ready:

      parent content: {"require_criteria": true}

  A create with NO `parent_id`, or under a parent that does not carry the flag,
  is byte-for-byte unaffected — it does not even pay a read (see the `cond`
  ordering below).

  ## Why `content.require_criteria` and not a nested policy object

  Two nested namespaces exist on a task and NEITHER fits.
  `content.execution_policy` is a STRICT versioned contract whose moduledoc says
  it "deliberately exposes only routing and capacity hints" and whose
  `reject_unknown_fields/1` would 422 the key outright; it is advice to a
  runner, not governance over children. `content.queue_gate` is a strict
  versioned enum describing THIS row's own readiness (`executable`,
  `human_gated`, `parked`, `evidence_stalled`) — it says nothing about, and is
  never read for, the row's children.

  The precedent that DOES fit is `content.dedup_bypass`: a bare top-level
  boolean on the task content that switches ONE birth gate, declared by the
  author of the write, absent from `Tasks.schema.ex` (so it costs no schema
  field, no capabilities-manifest change, and no `docs/openapi.json` churn).
  `require_criteria` is the same shape one level up — the parent declares it,
  the child's birth reads it — and it is spelled as the RULE it turns on rather
  than as its bypass, because the default here is OFF.

  ## The rule

  A `type:task` BIRTH whose `content.parent_id` names a task row carrying
  `content.require_criteria == true`, and whose own `content.acceptance_criteria`
  is absent, `nil`, or `[]`, is REFUSED with a 422 naming
  `acceptance_criteria` and the parent's flag.

  DRAFTS COUNT. A create through `Content.create_document/4` lands as
  `drafts.<id>` and only later publishes, and the rail counts drafts
  (`dr-bl-w6-phantom-draft-twins`) — a fence that only saw published rows would
  see none of the population it exists for. Both the child's birth and the
  parent lookup are draft-aware: the parent is resolved published-first, then by
  its draft id.

  ## What is DELIBERATELY not fenced, and why each one

    * **An UPDATE.** `prev_doc != nil` passes untouched. `/v1/data/mutate`
      merges patches BEFORE it validates (`Content.Writer`, PDS-D393), so a
      content-only rule that ignored the prior row would be RETROACTIVE and
      422 every future patch to an already-criteria-less row — the tombstone
      fence's lesson (`Writer.ensure_close_reason_lands_with_a_close/6`). This
      fence is about the BIRTH, and it is the birth that the three backfills
      kept losing to.
    * **A root row, or a child of an unflagged parent.** The whole point of the
      opt-in. It also means the read below is paid ONLY by a create that is
      already criteria-less AND already parented — never by an ordinary write.
    * **`source != :api`.** Replication mirrors an upstream row verbatim; the
      exemption every sibling birth guard takes (`DraftTerminalFence`,
      `DatasetTwinFence`). `:source` is server-set (MutateController prepends
      `source: :api`), so a request body cannot reach it.
    * **A non-`task` `content.kind`.** `Validation.kinds/0` is `~w(task)`, so an
      ABSENT kind IS a task ("Everything is a task") — the
      `CriteriaExemption.task_kind?/1` reading, not the inverse.
    * **A missing / unreadable parent.** The fence refuses only on a POSITIVE
      read of the flag. A parent that cannot be resolved in this scope hands
      back no permission to refuse; the hierarchy is not this fence's contract
      to enforce.

  ## Blast radius

  Zero rows on the server carry `require_criteria` today, so this fence refuses
  nothing until a parent's author opts in. That is the point of an opt-in and
  also its honest weakness: it makes the class REFUSABLE, it does not make it
  refused. The epic that owns a parent turns it on when it is ready.
  """

  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId}

  @doc """
  Refuses a criteria-less BIRTH under a parent that carries
  `content.require_criteria == true`.

  Returns `:ok` for every other write. Called from `Content.Writer`'s two birth
  chains (`do_create_document/6` and `do_upsert_document/6`) exactly like
  `DraftTerminalFence.check/6` and `DatasetTwinFence.check/6` beside it.
  """
  @spec check(
          String.t(),
          map(),
          String.t(),
          String.t() | nil,
          Document.t() | nil,
          keyword()
        ) :: :ok | {:error, {:invalid_task_content, map()}}
  def check(type, attrs, dataset, doc_id, prev_doc, opts)

  def check("task", attrs, dataset, _doc_id, nil = _prev_doc, opts) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}

    cond do
      # Replication mirrors an upstream row verbatim.
      Keyword.get(opts, :source, :api) != :api ->
        :ok

      # Not a task row.
      not task_kind?(content) ->
        :ok

      # The row states its criteria — nothing to refuse.
      criteria_present?(content) ->
        :ok

      # A root row. No parent, no opt-in, no read.
      is_nil(parent_id(content)) ->
        :ok

      # LAST, because it is the only clause that costs a read — the
      # `CriteriaExemption.has_children?/1` ordering lesson. Only a create that
      # is already parented AND already criteria-less ever reaches it.
      require_criteria?(parent_id(content), dataset, opts) ->
        {:error, {:invalid_task_content, criteria_required_error(parent_id(content))}}

      true ->
        :ok
    end
  end

  def check(_type, _attrs, _dataset, _doc_id, _prev_doc, _opts), do: :ok

  # `Validation.kinds/0` is `~w(task)` — an ABSENT kind is a task, not an
  # exemption. Reading a missing key as exempt would make this fence vacuous
  # over exactly the terse creates it exists for.
  defp task_kind?(content) do
    case fetch(content, "kind", :kind) do
      nil -> true
      kind when is_binary(kind) -> String.downcase(String.trim(kind)) == "task"
      _ -> false
    end
  end

  # Absent, nil and `[]` are ONE population: all three are "no criterion any
  # stamp can ever address". A non-list is `Validation`'s business, not this
  # fence's — it 422s on its own before the row could reach here.
  defp criteria_present?(content) do
    case fetch(content, "acceptance_criteria", :acceptance_criteria) do
      list when is_list(list) -> list != []
      _ -> false
    end
  end

  defp parent_id(content) do
    case fetch(content, "parent_id", :parent_id) do
      id when is_binary(id) -> if String.trim(id) == "", do: nil, else: String.trim(id)
      _ -> nil
    end
  end

  # Published first, then the parent's own draft id — a parent that has never
  # published is still the row of record for its children
  # (`DraftTerminalFence`'s premise). Only a POSITIVE read refuses.
  defp require_criteria?(parent_id, dataset, opts) do
    published = DraftId.published_id(parent_id)
    draft = DraftId.draft_id(published)

    Enum.any?(Enum.uniq([published, draft]), &flagged?(&1, dataset, opts))
  end

  defp flagged?(id, dataset, opts) do
    case Content.get_document(id, "task", dataset, opts) do
      {:ok, %Document{content: content}} -> fetch(content || %{}, "require_criteria", :require_criteria) == true
      _ -> false
    end
  end

  # Content arrives string-keyed from `/v1/data/mutate` and atom-keyed from some
  # in-process callers; every sibling guard reads both spellings.
  defp fetch(map, key, atom_key) when is_map(map), do: Map.get(map, key) || Map.get(map, atom_key)
  defp fetch(_map, _key, _atom_key), do: nil

  # The refusal TEACHES: it names the field, the parent that turned the rule on,
  # and the shape of the fix — the `DraftTerminalFence` message precedent.
  defp criteria_required_error(parent_id) do
    %{
      "acceptance_criteria" => [
        "this task's parent (#{parent_id}) carries `require_criteria: true`, so a " <>
          "child may not be born with no acceptance_criteria. A row with an empty " <>
          "criteria list is unfalsifiable — nothing can be stamped on it, and 0 of 0 " <>
          "reads to every audit as complete. Send at least one entry: " <>
          "\"acceptance_criteria\": [{\"criterion\": \"<what would prove this done>\"}]. " <>
          "This rule is OPT-IN: it applies only under a parent whose own content sets " <>
          "`require_criteria: true`."
      ]
    }
  end
end
