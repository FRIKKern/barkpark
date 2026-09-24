defmodule Barkpark.Tasks.ChangeGuards do
  @moduledoc """
  The two task CHANGE guards the core writer used to own
  (`Barkpark.Content.Writer.ensure_task_transition_legal/6` and
  `ensure_close_reason_lands_with_a_close/6`, task-d91ccf54d43b9800), now
  pre-write fences the Tasks plugin declares
  (`Barkpark.Plugins.Tasks.pre_write_fences/0`) at the exact position they held
  in the writer's `with` chain: FIRST and SECOND, before `DraftTerminalFence`.

  Moved VERBATIM. Each guard keeps its return shapes (`:ok` or
  `{:error, {:invalid_task_content, %{field => [msg]}}}`), its refusal text,
  its `:source == :sync` exemption and its published-fallback resolution of the
  row's current value, byte for byte; the arity was already the uniform fence
  arity, so nothing about a call changed but its module.

  WHY A MODULE OF ITS OWN, NOT `Barkpark.Tasks.BirthGuards`. The two are the
  mirror image of the birth guards: `BirthGuards` acts ONLY when there is no
  prior row, and both guards here EXEMPT a birth and judge a change against the
  row's current value (`lifecycle_status`, `close_reason`), resolved the same
  published-fallback way. Filing them under "birth" would name them for the one
  case they skip.

  The transition guard reads `Barkpark.Tasks.Transitions` — the reason these
  belong to the Tasks side, and the reason `Barkpark.Content.Writer` no longer
  names it.
  """

  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId}
  alias Barkpark.Tasks.Transitions

  # The terminal lifecycle states, for the tombstone fence below. DUPLICATED
  # from `Barkpark.Tasks.Close`'s private `@closed_lifecycle_statuses` because
  # a module attribute cannot be read across modules — and pinned against it by
  # `TombstoneFenceTest`'s "the terminal set matches Close's", which reads
  # close.ex's own bytes and reds if either list moves without the other. A
  # fence keyed on a stale copy of "what closed means" would let a mint through
  # on whichever status the two disagree about.
  @terminal_lifecycle_statuses ~w(done cancelled blocked)

  # ── The Writer-seam transition gate (task-lifecycle-visibility, D7b + D21) ─
  #
  # Every HTTP door that can change a `type:task` row's `lifecycle_status`
  # funnels through do_create_document/do_upsert_document, so the ONE
  # transition-legality table (`Barkpark.Tasks.Transitions`, charter D7) is
  # enforced HERE — immediately after prev-doc resolution, BEFORE
  # `:before_save` fires, so a refusal is side-effect-free.
  #
  # `was` is resolved PUBLISHED-FALLBACK (get_patch_base-style: the Writer's
  # own drafts-exact prev_doc first, then the bare id), NOT drafts-exact.
  # Proven open at L1 (run probe 2026-07-22): with the drafts-exact lookup, a
  # createOrReplace on a PUBLISHED-ONLY open task births a `drafts.<id>` done
  # twin that Queue.ready's done-CTE (which regexp-strips the `drafts.` prefix)
  # counts — flipping a gated dependent to ready with zero attribution. A BIRTH
  # is when NEITHER spelling exists. Both lookups ride the caller's scope opts
  # (the B3 rule), so a same-id row in a foreign workspace never gates a birth.
  #
  # Exemptions — never consult `legal?/2` on a birth (`legal?(nil, x)` is false
  # by design and would refuse every task birth):
  #   * `was == nil` — a birth, or a legacy row with no lifecycle. The importer
  #     shape (migration 20260528100000 seeds already-`done` rows) depends on
  #     the birth being exempt.
  #   * `source == :sync` — `Sync.Applier` mirrors upstream transitions
  #     verbatim; `:source` is server-set (MutateController prepends
  #     `source: :api`), so a request body can never reach the exemption.
  #
  # `bp migrate` arrives `source: :api` via /v1/data/mutate: a fresh target is
  # birth-exempt, a steady re-migrate is same→same legal, and forcing a LIVE
  # target's lifecycle to mirror a since-closed source is REFUSED BY DESIGN —
  # divergence repair is Sync's job.
  #
  # This SUPERSEDES the mutations.ex revision escape for ILLEGAL transitions
  # (D7a): `ensure_task_close_is_cas`'s `ifRevisionID` escape still proves the
  # caller read the row, but a read no longer licenses an illegal transition —
  # this downstream gate wins for e.g. `open → done`. mutations.ex is untouched
  # (its rev-escape ordering is load-bearing for the claim fence), and LEGAL
  # terminal transitions (`open → blocked`, `open → cancelled`) still pass with
  # the rev escape exactly as before.
  @doc "The transition-legality fence. See the header above."
  def transition_legal(type, attrs, dataset, doc_id, prev_doc, opts)

  def transition_legal("task", attrs, dataset, doc_id, prev_doc, opts) do
    content = Map.get(attrs, "content") || %{}
    now = Map.get(content, "lifecycle_status") || Map.get(content, :lifecycle_status)
    was = resolve_lifecycle_was(prev_doc, doc_id, dataset, opts)

    cond do
      # Birth (neither id spelling exists) or a legacy no-lifecycle row.
      is_nil(was) -> :ok
      # Replication mirrors upstream transitions verbatim.
      Keyword.get(opts, :source, :api) == :sync -> :ok
      Transitions.legal?(was, now) -> :ok
      true -> {:error, {:invalid_task_content, illegal_transition_error(was, now)}}
    end
  end

  def transition_legal(_type, _attrs, _dataset, _doc_id, _prev_doc, _opts), do: :ok

  # ── THE TOMBSTONE FENCE (cch-w39-bl) ──────────────────────────────────────
  #
  # A DISPOSAL REASON IS A CLAIM, NOT A MEASUREMENT. `close_reason` is written
  # once and re-read by nobody, so nothing can ever contradict it — the exact
  # property this codebase refuses in a guard ("a guard that can only stay green
  # while the disease stays untreated is not a guard"). Two live specimens, from
  # ONE disposal loop, failing in OPPOSITE directions:
  #
  #   * cch-w36-bl-mecache-unknown-arms-remaining — a cancel aimed at a
  #     `drafts.` twin that HAS NEVER EXISTED (none of the store's 403 `drafts.`
  #     rows carries that slug) landed its reason on the PUBLISHED ROW OF RECORD
  #     and killed it. The tombstone's own words were "The published row is the
  #     one of record and is NOT touched here" — written onto the row it killed.
  #   * cch-w36-s6-invalid-precedence-details-win — the reason landed and the
  #     CLOSE DID NOT: `lifecycle_status` stayed `in_progress` with
  #     `claim.closed_at` nil. A row wearing an epitaph while still alive.
  #
  # THE FENCE: a close_reason may be MINTED only by a write that also lands a
  # terminal `lifecycle_status`. The reason and the close become ONE atomic
  # fact, so a two-step loop (patch the reason, then attempt the close) can no
  # longer leave the first half standing when the second half loses its CAS —
  # and a reason aimed at a row nobody is closing is refused AT THE MOMENT IT IS
  # WRITTEN, rather than discovered by a reader months later.
  #
  # WHAT IT DELIBERATELY DOES NOT DO, and this is the placement lesson the birth
  # fence below already paid for: it is `prev_doc`-AWARE, never a content-only
  # rule. `/v1/data/mutate` merges patches BEFORE validation, so a content-only
  # "close_reason implies terminal" would be RETROACTIVE and 422 every future
  # patch to a row that already carries one. So CORRECTING an existing tombstone
  # stays legal at any status — not a loophole but a REQUIREMENT: cch-w36-bl was
  # reopened and its false tombstone corrected in place, and a fence that
  # forbade that would forbid the repair it exists to enable.
  @doc "The tombstone fence. See the header above."
  def close_reason_lands_with_a_close(type, attrs, dataset, doc_id, prev_doc, opts)

  def close_reason_lands_with_a_close("task", attrs, dataset, doc_id, prev_doc, opts) do
    content = Map.get(attrs, "content") || %{}
    now = present_string(Map.get(content, "close_reason") || Map.get(content, :close_reason))
    was = present_string(resolve_close_reason_was(prev_doc, doc_id, dataset, opts))
    status = Map.get(content, "lifecycle_status") || Map.get(content, :lifecycle_status)

    cond do
      # No tombstone in this write, or an unchanged one carried through a patch.
      is_nil(now) -> :ok
      now == was -> :ok
      # CORRECTING an existing reason — the audit action, always legal.
      not is_nil(was) -> :ok
      # Replication mirrors upstream verbatim (the same exemption its siblings take).
      Keyword.get(opts, :source, :api) == :sync -> :ok
      # MINTING one: the close must land in this same write.
      status in @terminal_lifecycle_statuses -> :ok
      true -> {:error, {:invalid_task_content, orphan_close_reason_error(status)}}
    end
  end

  def close_reason_lands_with_a_close(_t, _a, _d, _i, _p, _o), do: :ok

  # The row's CURRENT close_reason, resolved published-fallback — the same two
  # steps `resolve_lifecycle_was/4` takes, for the same reason: the drafts-exact
  # prev_doc the writer already loaded, then the bare (published) id.
  defp resolve_close_reason_was(%Document{content: content}, _doc_id, _dataset, _opts),
    do: (content || %{})["close_reason"]

  defp resolve_close_reason_was(_prev_doc, doc_id, dataset, opts) do
    with id when is_binary(id) <- doc_id,
         pid when pid != "" and pid != id <- DraftId.published_id(id),
         {:ok, %Document{content: content}} <-
           Content.get_document(pid, "task", dataset, opts) do
      (content || %{})["close_reason"]
    else
      _ -> nil
    end
  end

  # Blank is not a value. `nil`, `""`, whitespace and non-strings are all "no
  # tombstone" — an empty reason must not license a mint, and must not read as a
  # PREVIOUS reason that would make the next write a mere "correction".
  defp present_string(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_), do: nil

  defp orphan_close_reason_error(status) do
    %{
      "close_reason" => [
        "a close_reason may not be minted on a row this write does not close " <>
          "(lifecycle_status #{inspect(status)}): the reason and the close are ONE fact. " <>
          "Close through the close primitive (`bp task close <id> <worker> <epoch> " <>
          "<status> <reason>`, POST /v1/tasks/:id/close), which writes both together and " <>
          "rolls BOTH back when its CAS loses. A reason written beside a close that never " <>
          "landed is an epitaph on a living row."
      ]
    }
  end

  # The row's CURRENT lifecycle_status, resolved published-fallback: the
  # drafts-exact prev_doc the writer already loaded first, then the bare
  # (published) id — mirroring Mutations.get_patch_base/4, and scoped through
  # the same opts as the prev-doc lookup.
  defp resolve_lifecycle_was(%Document{content: content}, _doc_id, _dataset, _opts),
    do: (content || %{})["lifecycle_status"]

  defp resolve_lifecycle_was(_prev_doc, doc_id, dataset, opts) do
    with id when is_binary(id) <- doc_id,
         pid when pid != "" and pid != id <- DraftId.published_id(id),
         {:ok, %Document{content: content}} <-
           Content.get_document(pid, "task", dataset, opts) do
      (content || %{})["lifecycle_status"]
    else
      _ -> nil
    end
  end

  # Renders through the existing `invalid_task_content` family →
  # `Content.Errors` 422 validation_failed envelope, keyed on the field. The
  # message names from, to and the sanctioned verb — the refusal TEACHES
  # (tasks_controller stage/close precedent). Never the `{:halted, _}` shape,
  # which is reserved for plugin vetoes.
  defp illegal_transition_error(from, to) do
    %{
      "lifecycle_status" => [
        "illegal lifecycle transition #{inspect(from)} → #{inspect(to)}: no document " <>
          "write may perform it — " <> sanctioned_verb(to)
      ]
    }
  end

  defp sanctioned_verb("done"),
    do:
      "`done` is reached only through the close primitive (`bp task close <id> <worker> " <>
        "<epoch>`, POST /v1/tasks/:id/close), which records who closed it."

  defp sanctioned_verb("in_progress"),
    do:
      "a live claim is minted only by the claim primitive (`bp task claim <id> <worker>`, " <>
        "POST /v1/tasks/:id/claim), which fences on the claim epoch."

  defp sanctioned_verb(to) when to in ~w(considering researching),
    do:
      "thought states move through the sanctioned stage verb (`bp task stage <id> #{to}`, " <>
        "POST /v1/tasks/:id/stage), which enforces the same legality table."

  defp sanctioned_verb(_to),
    do:
      "move through the sanctioned task lifecycle verbs instead (`bp task stage` for " <>
        "considering|researching|open, `bp task claim`, `bp task close`)."
end
