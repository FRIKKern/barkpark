defmodule Barkpark.Tasks.TerminalCriteriaFence do
  @moduledoc """
  THE TERMINAL-CRITERIA FENCE (task-3c3094aa8f5f3847).

  ## THE RULING (written before the code, which is why it is first)

  **A document-door write may not change `content.acceptance_criteria` on a
  task row that is CLOSED-TERMINAL (`done` / `cancelled`) and that the same
  write leaves closed-terminal. It is REFUSED — not accepted-with-a-trace.**

  Three reasons the verdict is refusal and not "accept and record a
  withdrawal-shaped trace":

    * **D745 already owns lowering a lock.** `bp task stamp --withdraw`
      (`Barkpark.Tasks.Stamp`, `@terminal_statuses`) is the sanctioned way to
      take a met criterion back on a closed row, and it is the only writer that
      appends to the criterion's `withdrawals` list — who, why, when, and
      `post_close: true`. A second door that minted a withdrawal record would
      be a second implementation of D745's ledger, keyed on a caller who never
      said the word "withdraw".
    * **A publish carries no authorial intent about a field it did not name.**
      This is the standing ruling of the door beside this one
      (`Content.Lifecycle`'s `task_door_field_fence/2`, the six task-door-owned
      fields): publishing copies a draft's content over the published row
      WHOLESALE, so a draft that merely predates the close is indistinguishable
      from an author asking to rewrite the proof. That door refuses rather than
      merges, and names the verb. So does this one.
    * **No legitimate publisher needs it.** Measured, not assumed: every task
      verb that moves a closed row — `Tasks.Close`, `Tasks.Stamp` (including
      `--withdraw`), `Tasks.Stage`, `Tasks.Landed`, `Tasks.Discharge`,
      `Tasks.Compactor` — writes the published row through
      `Tasks.Internal.fenced_content_write/4`, a bare rev-fenced
      `Repo.update_all` that never passes through `Content.Writer` and never
      through `Content.Lifecycle.publish_document/4`. None of them can reach
      this fence, so refusing here takes nothing away from any of them. (The
      filing said those verbs "publish". They do not — see the controls in
      `terminal_criteria_fence_test.exs`.)

  ## The witness

  `task-2b7cbaf8265f6b4e` closed `done` on 2026-08-24T21:52Z carrying ZERO
  acceptance criteria (D289 vacuously satisfied). `bp doc history` shows the
  PUBLISHED doc untouched until 2026-09-04T06:09:15/37/39Z, where a
  `discardDraft` -> `create draft` -> `publish` triple wrote a 7-entry criteria
  list — 6 met, c6 (`"MERGE GATE (lead): PR #14072 is merged to main..."`)
  UNMET — onto the already-`done` published row. The row has ZERO
  `task.criterion` events in its entire life: no stamp, no withdrawal, no
  attribution. It is false-done, and nothing in the chain refused it.

  `Content.Lifecycle`'s `criteria_fence/2` cannot see this shape. It is a
  REGRESSION fence: it walks the PUBLISHED row's proof-bearing criteria (`met:
  true` or non-blank `evidence`) and refuses a draft that drops or unproves
  one. A published row carrying NO criteria has no proof to regress, so a draft
  adding seven — one of them unmet — passes it untouched. The same hole is open
  one notch narrower on a row that closed 1/1: adding an unmet criterion at
  index 1 regresses nothing at index 0 and lands `done 1/2`.
  `DraftTerminalFence` cannot see it either, and says so
  (`draft_terminal_fence.ex`, "A row with a published twin. Untouched — the
  publish door owns it").

  ## Where it is enforced, and the residue it does NOT cover

  Called from `Content.Writer`'s two task chains (`do_create_document/6` and
  `do_upsert_document/6`) exactly like `DraftTerminalFence.check/6` beside it.
  That covers the two doors the criteria list can ENTER the system through:

    * the `create draft` of the witness triple (`drafts.<id>` whose published
      twin is closed-terminal), and
    * a direct `createOrReplace`/patch-merge on the PUBLISHED id — which is the
      live shape for tasks since `Content.Mutations.get_patch_base/4` became
      published-first (task-b9c618482e688500).

  **RESIDUE, stated rather than hidden:** a draft minted BEFORE the close, with
  criteria already divergent, and published AFTER it, never passes through this
  fence — the publish write itself happens in
  `Content.Lifecycle.publish_after_gate/5` (`Document.changeset |> Repo.update`
  inside its own transaction), not through `Content.Writer`. Closing that last
  notch means a terminal arm on `gate_task_publish/2` +
  `assert_no_criteria_regression!/3` in `content/lifecycle.ex`, which is
  outside this row's granted fence. It is the natural follow-up and it is
  small: the predicate below is public (`changes_terminal_criteria?/2`) so the
  lifecycle gate can call it without restating the rule.

  ## What is DELIBERATELY not fenced, and why each one

    * **A REOPEN.** When the same write moves the row OUT of a closed terminal
      (`lifecycle_status` becomes `open`/`in_progress`/`blocked`/…), the
      criteria change is allowed. A row that is no longer `done` is not
      false-done: unmet criteria on an open row are an honest statement of
      remaining work. The harm this fence names is a row that STAYS closed
      while its proof changes underneath it. The transition itself is gated
      elsewhere (`Transitions.legal?/2`), which is the right owner for whether
      the reopen may happen at all.
    * **`blocked`.** Same set as `DraftTerminalFence` and for the same reason:
      `bp task ready` serves blocked rows, so `blocked` is not a CLOSE. The set
      here is `done` and `cancelled`.
    * **A write that does not NAME `acceptance_criteria`.** Head-matched before
      any read: a patch that moves `priority` or `description` on a done row is
      ordinary work and costs this fence nothing (no query at all).
    * **A BIRTH.** `prev_doc == nil` and no published twin — the exemption
      every sibling guard takes. An importer filing an already-`done` row with
      its criteria list is the shape `MutateControllerTest` and
      `PublishDoorLifecycleGuardTest` pin; this fence is about the CHANGE, not
      the filing.
    * **Byte-identical criteria.** The pass path for every draft derived from
      the current published content: the patch-then-publish idiom, Studio
      autosave, the brief re-mirror (`Tasks.BriefMirror` derives the brief FROM
      the criteria, never the reverse).
    * **`source != :api`.** Replication mirrors an upstream close verbatim; the
      same exemption every sibling takes. `:source` is server-set
      (MutateController prepends `source: :api`), so a request body cannot
      reach it.
    * **DELETE and DISCARD-DRAFT.** Create/upsert guard only, like every
      sibling — `Content.delete_document/4` and the discard-draft path never
      consult it, so the orphan-draft disposition is untouched.
  """

  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId}

  # The CLOSED terminals. Deliberately NARROWER than
  # `Writer.@terminal_lifecycle_statuses` (`done cancelled blocked`) — see the
  # moduledoc on `blocked`. Same set `DraftTerminalFence` uses.
  @closed_terminal_statuses ~w(done cancelled)

  @doc """
  Refuse a document-door write that changes `acceptance_criteria` on a task row
  that is, and stays, closed-terminal.

  Returns `:ok` or `{:error, {:invalid_task_content, details}}` — the family
  `Content.Errors` renders as a 422 `validation_failed`.
  """
  @spec check(
          String.t() | nil,
          map(),
          String.t(),
          String.t() | nil,
          Document.t() | nil,
          keyword()
        ) :: :ok | {:error, {:invalid_task_content, map()}}
  def check(type, attrs, dataset, doc_id, prev_doc, opts)

  def check("task", attrs, dataset, doc_id, prev_doc, opts) when is_binary(doc_id) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}

    cond do
      # Replication mirrors an upstream row verbatim.
      Keyword.get(opts, :source, :api) != :api ->
        :ok

      # The write does not NAME the criteria list. No read, no opinion.
      is_nil(criteria(content)) ->
        :ok

      true ->
        case incumbent(doc_id, dataset, prev_doc, opts) do
          nil -> :ok
          incumbent_content -> verdict(incumbent_content, content)
        end
    end
  end

  def check(_type, _attrs, _dataset, _doc_id, _prev_doc, _opts), do: :ok

  @doc """
  The rule as a predicate, so a second seam (the publish door in
  `Content.Lifecycle`) can enforce the SAME rule without restating it.

  True when `incumbent_content` is closed-terminal, `new_content` leaves it
  closed-terminal, and the two disagree on `acceptance_criteria`.
  """
  @spec changes_terminal_criteria?(map(), map()) :: boolean()
  def changes_terminal_criteria?(incumbent_content, new_content)
      when is_map(incumbent_content) and is_map(new_content) do
    was = incumbent_content["lifecycle_status"]
    now = new_content["lifecycle_status"] || was

    was in @closed_terminal_statuses and
      now in @closed_terminal_statuses and
      normalize(criteria(new_content)) != normalize(incumbent_content["acceptance_criteria"])
  end

  def changes_terminal_criteria?(_incumbent_content, _new_content), do: false

  defp verdict(incumbent_content, content) do
    if changes_terminal_criteria?(incumbent_content, content) do
      {:error,
       {:invalid_task_content,
        terminal_criteria_error(incumbent_content["lifecycle_status"], incumbent_content, content)}}
    else
      :ok
    end
  end

  # The row this write lands ON, as it stands today:
  #
  #   * a PUBLISHED id → `prev_doc` is that row (nil = a birth, exempt);
  #   * a `drafts.<id>` → the PUBLISHED TWIN, because that is the row a publish
  #     of this draft will overwrite and the row every task reader serves.
  #     A draft with no twin is `DraftTerminalFence`'s business, not this one's.
  #
  # LAST in the cond above, because the twin lookup is the only clause that
  # costs a read — and only a task write that already names its criteria list
  # ever reaches it.
  defp incumbent(doc_id, dataset, prev_doc, opts) do
    if DraftId.draft?(doc_id) do
      with pid when is_binary(pid) and pid != "" and pid != doc_id <- DraftId.published_id(doc_id),
           {:ok, %Document{content: content}} when is_map(content) <-
             Content.get_document(pid, "task", dataset, opts) do
        content
      else
        _ -> nil
      end
    else
      case prev_doc do
        %Document{content: content} when is_map(content) -> content
        _ -> nil
      end
    end
  end

  defp criteria(content) when is_map(content) do
    case Map.get(content, "acceptance_criteria") || Map.get(content, :acceptance_criteria) do
      list when is_list(list) -> list
      _ -> nil
    end
  end

  defp criteria(_content), do: nil

  # Content arrives string-keyed from `/v1/data/mutate` and atom-keyed from some
  # in-process callers, so a term comparison alone would call an identical list
  # "changed". Stringify keys one level into each criterion map before comparing.
  defp normalize(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp normalize(_list), do: []

  defp stringify(%{} = row),
    do: Map.new(row, fn {k, v} -> {to_string(k), v} end)

  defp stringify(other), do: other

  # The refusal TEACHES: it names the terminal state, the count it is being
  # asked to change, and D745's verb.
  defp terminal_criteria_error(status, incumbent_content, content) do
    was = normalize(incumbent_content["acceptance_criteria"])
    now = normalize(criteria(content))

    %{
      "acceptance_criteria" => [
        "this task row is #{inspect(status)} — a CLOSED terminal — and this write would " <>
          "change its acceptance_criteria (#{met_count(was)}/#{length(was)} met → " <>
          "#{met_count(now)}/#{length(now)} met) while leaving it closed. A document-door " <>
          "write (`bp doc create` / `patch` / `createOrReplace`, and the draft a publish " <>
          "copies wholesale) carries no authorial intent about a field it did not name, so " <>
          "it may not rewrite the proof a close was granted on: the result is a row that " <>
          "reads `done` with unmet criteria and no record of who lowered it. Lowering a " <>
          "criterion on a closed row is `bp task stamp <id> <index> --withdraw --reason " <>
          "<why>` (D745), which appends who, why and when to that criterion's `withdrawals` " <>
          "list. Reopening the row first (`bp task stage <id> <state>`) also lifts this " <>
          "refusal — an open row with unmet criteria is honest. Otherwise rebase this write " <>
          "on the current published row and carry the criteria list verbatim."
      ]
    }
  end

  defp met_count(list), do: Enum.count(list, &(is_map(&1) and &1["met"] == true))
end
