defmodule Barkpark.Tasks.DraftTerminalFence do
  @moduledoc """
  THE DRAFT-ONLY TERMINAL FENCE (task-e49058a7f2b46a63).

  `Content.Lifecycle.ensure_task_publish_transition_legal/5` is the gate that
  closes the blind-terminal hole for task rows — but it runs AT PUBLISH. A row
  that never publishes never meets it, and for a never-published row the DRAFT
  IS THE ROW OF RECORD: `bp task get` reads it, and `bp task ready` serves
  "published or unpaired draft" (tasks manifest, `ready`). So a draft-only row
  wearing `cancelled` is a task nobody will ever work, closed by nobody.

  ## The run that proved it open (2026-09-06, guerrilla.barkpark.cloud)

  Two doors landed a terminal status on a never-published draft with ZERO
  attribution — no claim, no `closed_by`, no `closed_at`, no `close_reason`:

    * UPDATE — `/v1/data/mutate` `patch` on `drafts.<id>` carrying
      `ifRevisionID`. `Mutations.ensure_task_close_is_cas/5` refuses the BLIND
      patch (proven: the same patch without the precondition 422s) but its
      revision escape is explicitly "NOT proof that a CAS-carrying close is
      attributed" (mutations.ex). `Content.Writer`'s
      `ensure_task_transition_legal/6` then passes it because `open → cancelled`
      is a LEGAL charter-D7 edge — legal for the sanctioned `close` verb, which
      is not what walked through.
    * BIRTH — `bp doc create task` with `lifecycle_status: "cancelled"` on a
      fresh id. Every sibling guard exempts a birth (`was == nil`), by design.

  This is the 2026-07-23 witness shape: `task-77620317484e1185` reached
  `cancelled` with no `claim.closed_by` and no `claim.closed_at`, ~45.8h AFTER
  the publish gate landed — because it was never published.

  ## The rule

  A `type:task` write that lands a CLOSED-terminal `lifecycle_status` on a
  `drafts.<id>` row with NO published twin is refused, unless the same write
  carries close provenance.

  Keyed on provenance, not on a revision precondition, and not on a role — the
  same disjunction the READ side already applies to a forged `done`
  (`Tasks.Queue.ready`'s `ready_done_tasks` CTE, `QueueGate.closed?/1`):
  `claim.closed_by`, `claim.closed_at`, or a non-empty `close_reason`. That is
  what makes `Tasks.Close` — the sanctioned writer, which lands all three —
  pass through untouched while a raw document write does not.

  ## What is DELIBERATELY not fenced, and why each one

    * **`blocked`.** It is in the siblings' `@terminal_lifecycle_statuses` but
      it is not a CLOSE: `bp task ready` serves blocked rows ("blocked is
      claimable by design"), so filing a blocked task is ordinary work with no
      close provenance to carry. Fencing it would refuse a legitimate birth.
      The set here is the CLOSED terminals only: `done`, `cancelled`.
    * **A row with a published twin.** Untouched — the publish door owns it,
      and this fence exists precisely for the rows that door never sees. The
      blast radius is draft-only task rows, nothing else.
    * **Same → same.** An already-`cancelled` draft may still be patched on
      every other field. The tombstone fence paid for this lesson
      (`Writer.ensure_close_reason_lands_with_a_close/6`): `/v1/data/mutate`
      merges patches BEFORE validation, so a content-only rule that ignored the
      prior state would be RETROACTIVE and 422 every future patch to a row that
      already carries the value.
    * **`source != :api`.** Replication mirrors an upstream close verbatim; the
      same exemption every sibling takes. `:source` is server-set
      (MutateController prepends `source: :api`), so a request body cannot
      reach it.
    * **DELETE and DISCARD-DRAFT.** This is a create/upsert guard: it is called
      from `Writer.do_create_document/6` and `Writer.do_upsert_document/6` and
      from nowhere else, so `Content.delete_document/4` and the discard-draft
      path never consult it. That is load-bearing, not incidental — the
      orphan-draft disposition (task-ee33b6f088b35bdb, 31 rows) DELETES drafts,
      and a fence that also blocked deletion would strand every one of them.
      Pinned by a test.
  """

  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId}

  # The CLOSED terminals. Deliberately NARROWER than
  # `Writer.@terminal_lifecycle_statuses` / `Mutations.@terminal_lifecycle_statuses`
  # (`done cancelled blocked`) — see the moduledoc on `blocked`.
  @closed_terminal_statuses ~w(done cancelled)

  @doc """
  Refuse a closed-terminal `lifecycle_status` landing on a never-published
  draft task row without close provenance.

  Returns `:ok` or `{:error, {:invalid_task_content, details}}` — the family
  `Content.Errors` renders as a 422 `validation_failed`, never `{:halted, _}`
  (that shape is reserved for plugin vetoes).
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
    content = Map.get(attrs, "content") || %{}
    now = fetch(content, "lifecycle_status", :lifecycle_status)

    cond do
      # Not a close. Every non-terminal write, and `blocked`, passes.
      now not in @closed_terminal_statuses -> :ok
      # Replication mirrors an upstream close verbatim.
      Keyword.get(opts, :source, :api) != :api -> :ok
      # A published row is the publish door's business, not this fence's.
      not DraftId.draft?(doc_id) -> :ok
      # The sanctioned close verb lands all three of these; a raw write lands none.
      close_provenance?(content) -> :ok
      # Same → same: correcting other fields on an already-closed draft stays legal.
      previous_status(prev_doc) == now -> :ok
      # A published twin exists → the publish gate sees this write. Last, because
      # it is the only clause that costs a read.
      published_twin?(doc_id, dataset, opts) -> :ok
      true -> {:error, {:invalid_task_content, draft_terminal_error(now)}}
    end
  end

  def check(_type, _attrs, _dataset, _doc_id, _prev_doc, _opts), do: :ok

  # The read side's disjunction (`Tasks.Queue.ready`'s `ready_done_tasks` CTE,
  # `QueueGate.closed?/1`), applied at the write seam: a close that records who
  # closed it, when, or why.
  defp close_provenance?(content) do
    claim = fetch(content, "claim", :claim)
    claim = if is_map(claim), do: claim, else: %{}

    present?(fetch(claim, "closed_by", :closed_by)) or present?(fetch(claim, "closed_at", :closed_at)) or
      present?(fetch(content, "close_reason", :close_reason))
  end

  defp previous_status(%Document{content: content}), do: (content || %{})["lifecycle_status"]
  defp previous_status(_), do: nil

  defp published_twin?(doc_id, dataset, opts) do
    with pid when is_binary(pid) and pid != "" and pid != doc_id <- DraftId.published_id(doc_id),
         {:ok, %Document{}} <- Content.get_document(pid, "task", dataset, opts) do
      true
    else
      _ -> false
    end
  end

  # Content arrives string-keyed from `/v1/data/mutate` and atom-keyed from some
  # in-process callers; every sibling guard reads both spellings.
  defp fetch(map, key, atom_key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, atom_key)

  defp fetch(_map, _key, _atom_key), do: nil

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(nil), do: false
  defp present?(_), do: true

  # The refusal TEACHES: it names the draft case and the two honest
  # alternatives (the tasks_controller stage/close precedent).
  defp draft_terminal_error(status) do
    %{
      "lifecycle_status" => [
        "a draft task row cannot be set to a terminal lifecycle_status " <>
          "(#{inspect(status)}) directly: this row has never been published, so the " <>
          "publish transition gate never sees it and the draft IS the row of record " <>
          "(`bp task ready` serves unpaired drafts). A terminal status written here " <>
          "records no claim, no worker and no epoch. Publish it and close it through " <>
          "the close primitive (`bp task close <id> <worker> <epoch>`, " <>
          "POST /v1/tasks/:id/close), which records who closed it, or delete the " <>
          "draft outright (`bp doc delete task drafts.<id>`) — deleting a draft is " <>
          "not fenced here."
      ]
    }
  end
end
