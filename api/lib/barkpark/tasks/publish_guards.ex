defmodule Barkpark.Tasks.PublishGuards do
  @moduledoc """
  The task gates at the PUBLISH door, formerly named directly in
  `Barkpark.Content.Lifecycle` (task-8273f2f1b24a6de1, Barkspark phase 1
  slice E) and now declared by the Tasks plugin as its pre-publish fences
  (`Barkpark.Plugins.Tasks.pre_publish_fences/0`), run by the lifecycle
  through `Barkpark.Content.PrePublishFences` at the exact positions they held:

    * `door_gate/4` — phase `:door`, formerly
      `Lifecycle.ensure_task_publish_transition_legal/4`: after the draft read
      and the core render-shape and bound-title gates, BEFORE the authoring
      wall, the `:before_publish` hook chain and the transaction, so a refusal
      is side-effect-free. It carries the lifecycle transition check
      (`Transitions.legal?/2`), the stale-claim check, the claim-time criteria
      contract (`CriteriaContract`), the criteria regression fence, the
      terminal-criteria fence (`TerminalCriteriaFence`) and the task-door field
      fence, in that order.
    * `no_criteria_regression/4` — phase `:in_transaction`, formerly
      `Lifecycle.assert_no_criteria_regression!/4`: inside the publish
      transaction, directly after the incumbent row is locked `FOR UPDATE`
      (`Lifecycle.lock_published_row/2`, which stays in core because it also
      serves papers). It RETURNS its refusal instead of calling
      `Repo.rollback/1` itself; the lifecycle rolls back with that same
      `reason`, so the transaction's `{:error, reason}` is unchanged.

  Both head-match on `type == "task"` and pass every other publish through as
  `:ok`, exactly as the lifecycle clauses they replace did. Every body below
  is the lifecycle's, moved; the comments name the lifecycle functions they
  still sit beside.
  """

  alias Barkpark.Content.Document
  alias Barkpark.Tasks.CriteriaContract
  alias Barkpark.Tasks.TerminalCriteriaFence
  alias Barkpark.Tasks.Transitions

  # ── The publish-door lifecycle gate (task-lifecycle-visibility, D7/D21) ────
  #
  # `publish_document` bypasses `Content.Writer` entirely and copies the ENTIRE
  # draft content — `lifecycle_status`, `claim`, epoch and all — onto the
  # published row. Proven at L1 (run probe 2026-07-22): claim+close a published
  # task through the SANCTIONED verbs, then republish a coexisting stale open
  # draft → the published row silently reverts done→open and content.claim
  # becomes nil, obliterating the attribution record. The Writer-seam gate
  # (D7b, `Tasks.ChangeGuards.transition_legal/6`) cannot see this door.
  #
  # Contract — mirrors the Writer-seam gate, adapted to the publish seam (the
  # collapse target IS the published row, so `was` is simply its current
  # `lifecycle_status`; no draft-fallback resolution is needed):
  #
  #   * FIRST publish (no published row) is a birth — exempt, including the
  #     importer's legitimately-born-`done` draft.
  #   * `source: :sync` mirrors upstream state verbatim — exempt from the
  #     TRANSITION and CLAIM checks only; the CRITERIA FENCE applies to every
  #     source (see below). `:source` is server-set (MutateController prepends
  #     `source: :api`), so a request body can never reach the exemption.
  #   * a published row with no `lifecycle_status` (legacy / non-task-kind
  #     content) exempts the transition check; the claim check still runs.
  #   * an ILLEGAL implied transition (`Transitions.legal?/2`, the ONE D7
  #     table) is refused naming from, to and the sanctioned verb — e.g.
  #     `open → done` forged through the publish door (a done-carrying draft
  #     can exist legally via `source: :sync`; publishing it may not flip the
  #     published row).
  #   * a TABLE-LEGAL transition can still be a stale-draft RESURRECTION
  #     (`done → open` is legal — the false-done reopen recipe). The staleness
  #     signal is the CLAIM: the published row's claim state is written ONLY by
  #     the sanctioned primitives (claim/renew/pulse/release/close, all
  #     rev-CAS'd), so a draft that does not carry it verbatim predates it —
  #     refused. A draft derived from the CURRENT published content
  #     (patch-then-publish: the met-flip republish flow, the reopen recipe,
  #     the github bookkeeping collapse) carries the claim byte-identical and
  #     passes untouched.
  #   * a CLAIM-IDENTICAL draft can STILL erase evidence (PDS wave 26,
  #     PDS-D360/PDS-D362, observed end-to-end): `bp task stamp` writes the
  #     PUBLISHED row directly (`Tasks.Stamp`, `Repo.update_all`) and never
  #     touches the draft twin, and a draft NEVER rebases. So a draft minted
  #     DURING an active claim carries that claim verbatim, sails past
  #     `stale_claim?/2`, and this door then replaces the published content
  #     WHOLESALE — `met: true` becomes `met: false`, evidence becomes `""`,
  #     rc=0, no warning. The second staleness signal is therefore the
  #     ACCEPTANCE CRITERIA themselves: a publish that would clear a
  #     `met: true` flag, blank a non-empty `evidence` string, or drop the row
  #     holding one is refused. Keyed on `acceptance_criteria` ONLY — this is
  #     deliberately NOT a general content diff, so every other field a draft
  #     legitimately rewrites still publishes. Preserving or ADVANCING the
  #     criteria passes; a reopen (`done → open`) that keeps its evidence
  #     passes.
  #
  # Refusals use the `{:invalid_task_content, %{field => [msg]}}` family
  # (→ 422 validation_failed via Content.Errors), NEVER `{:halted, _}` (that
  # shape is reserved for plugin vetoes). EMITTER TWIN:
  # `Writer.illegal_transition_error/2` + `Writer.sanctioned_verb/1` — a
  # contract-shape change must update BOTH seams (the error-emitters-duplicated
  # rule).
  #
  # THE EXACT COVERAGE, re-derived at review rather than assumed (wave 26):
  #
  #   * COVERED — `source: :sync`, for the CRITERIA FENCE only
  #     (pds-bl-sync-source-bypasses-publish-door). The exemption used to be
  #     taken BEFORE any gate ran, so a PULL-applied mirror write could blank a
  #     `met: true` flag or a non-empty evidence string with no guard at all —
  #     strictly worse than the `:api` hole PDS-D362 closed. RULED: the fence
  #     is source-blind, the mirror exemptions are not. Transition + claim
  #     checks stay exempt for `:sync` because a verbatim mirror legitimately
  #     carries upstream's lifecycle (`done → open` reopens, foreign claim
  #     state) — but no LEGITIMATE upstream can need to erase a stamped proof:
  #     every write door upstream (api, github, and now sync itself) refuses
  #     that erasure, so a sync payload that regresses criteria is evidence of
  #     drift or forgery, never of replication. The refusal is safe on the
  #     apply side: `Sync.Applier.error_class/1` classes
  #     `{:invalid_task_content, _}` as :terminal (no retry wedge), and the
  #     Pusher's synthesized publish executes on the REMOTE box through its
  #     MutateController (`source: :api` there), where this same fence already
  #     gates it.
  #   * NOT REACHED by any GitHub caller on main — and an earlier revision of
  #     this note said the opposite. It claimed the GitHub automatic publishers
  #     (`plugins/github/link.ex` via `mirror_job.ex` / `inbound_events.ex`,
  #     and `plugins/github/adopt.ex`) threaded `source: :github` through
  #     `Content.publish_document/4` and so "fell through to this gate". They
  #     did once; since #16479 both are PUBLISHED-FIRST fenced writers
  #     (`Tasks.Internal.fenced_content_write/4` straight onto the published
  #     row — no `drafts.<id>` twin is minted, so there is no collapse and no
  #     publish to refuse), and `grep -rn publish_document
  #     api/lib/barkpark/plugins/github/` matches only the two moduledocs that
  #     recount the old shape. `source: :github` is still stamped — `Link.put/4`
  #     threads it into the never-published arm's DRAFT upsert
  #     (`put_on_draft/5`) and into the fenced write's `mutation_events` row —
  #     but never into this door. So the coverage claim above was true of
  #     NOTHING, and this gate has no live `:github` producer to cover.
  #     The contract a returning GitHub publisher meets is pinned by TEST, not
  #     by this comment: `publish_door_lifecycle_guard_test.exs` section (h)
  #     ("source: :github takes the FULL gate, and the producer picks it",
  #     task-b36741707eabe359 / #17355) — transition + claim checks + the
  #     criteria fence all apply to `:github`, and only `:sync` is exempt from
  #     the first two. `pds-bl-github-linkput-auto-publish-erasure` stays open
  #     for the audit-trail half it does not answer.
  # The incumbent is now READ BY THE CALLER and handed in (see `Content.Lifecycle.read_incumbent/4`
  # at the top of its `do_publish_document/4`) rather than re-read here. Same value,
  # same verdicts — `nil` still means "first publish — a birth", and `legal?/2`
  # is still never consulted for one (`legal?(nil, x)` is false by design and
  # would refuse every birth).
  @doc "Phase `:door` fence (see the moduledoc). `:ok`, or the refusal verbatim."
  @spec door_gate(String.t(), Document.t(), Document.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def door_gate(
        "task",
        %Document{} = draft,
        %Document{} = published,
        opts
      ) do
    pub_content = published.content

    if Keyword.get(opts, :source, :api) == :sync do
      # Mirror-verbatim: transition + claim exempt, criteria fence NOT —
      # see the :sync coverage note above.
      criteria_fence(pub_content || %{}, draft.content || %{})
    else
      gate_task_publish(pub_content || %{}, draft.content || %{}, published.doc_id)
    end
  end

  def door_gate(_type, _draft, _published, _opts), do: :ok

  defp gate_task_publish(pub_content, draft_content, pid) do
    was = pub_content["lifecycle_status"]
    now = draft_content["lifecycle_status"]

    cond do
      not (is_nil(was) or Transitions.legal?(was, now)) ->
        {:error, {:invalid_task_content, publish_transition_error(was, now)}}

      stale_claim?(pub_content, draft_content) ->
        {:error, {:invalid_task_content, stale_claim_error(pub_content, pid)}}

      true ->
        # THE CLAIM-TIME CONTRACT (task-11390a3b900c8a09). `criteria_fence/2`
        # below is keyed on the PUBLISHED row's proof and falls back to the
        # POSITIONAL slot, so a write that replaces every criterion text with a
        # foreign row that also carries met/evidence regresses nothing and
        # sails through — the exact 2026-07-10 cross-epic substitution. This
        # gate asks the other question: do ANY of the criterion texts the live
        # claim was taken against survive this write? See
        # `Barkpark.Tasks.CriteriaContract` for the predicate and its scope.
        with :ok <- CriteriaContract.check_substitution(pub_content, draft_content),
             :ok <- criteria_fence(pub_content, draft_content),
             :ok <- terminal_criteria_fence(pub_content, draft_content) do
          task_door_field_fence(pub_content, draft_content)
        end
    end
  end

  # ── WHICH DOOR IS WRONG: THE DOCUMENT DOOR (task-9b5e1a6a688d27fc) ─────────
  #
  # Two doors write one row. The TASK door (`Barkpark.Tasks.{Claim,Pulse,Renew,
  # Release,Fence,Move,Stamp,Stage,Close,TtlSweeper}`) writes the published row
  # in place, rev-CAS'd, through the sanctioned verbs. The DOCUMENT door (draft
  # patch + `publish_document/4`) copies the draft's content WHOLESALE onto the
  # published row — see `Content.Lifecycle.publish_after_gate/6`'s `"content" => pub_content`.
  #
  # The document door is the one that must yield: a publish that does not NAME
  # a task-door field has no authorial intent about it, so it may not change it.
  # Publish cannot simply MERGE the live values back in — that would invent an
  # edit the author never wrote, and it is the same class of silent repair the
  # title-divergence gate above refuses to make — so, exactly like
  # `stale_claim?/2`, the seam REFUSES and names the verb that owns the field.
  #
  # THE FIELDS, ENUMERATED FROM THE TASK WRITE PATH, not from a brief. Every
  # TOP-LEVEL `content` key `api/lib/barkpark/tasks/*.ex` writes:
  #
  #   * `claim`              — claim/pulse/renew/release/fence/move/close/ttl_sweeper
  #                            (already fenced by `stale_claim?/2`; `closed_by`
  #                            and `closed_at` live INSIDE it, so they ride it)
  #   * `lifecycle_status`   — claim/close/fence/move/stamp/ttl_sweeper
  #                            (already fenced by `Transitions.legal?/2` above)
  #   * `acceptance_criteria` — stamp (already fenced by `criteria_fence/2`)
  #   * `close_reason`       — close.ex (`apply_close_update/8`)
  #   * `close_override`     — close.ex (`merge_override_record/2`)
  #   * `disposition`        — close.ex (`advance_disposition_on_close/2`),
  #                            stage.ex (@disposition_key)
  #   * `reopen_trigger`     — stage.ex (@reopen_trigger_key)
  #   * `engagement`         — stage.ex:717
  #   * `landed`             — internal.ex:493
  #
  # The first three already had a gate. THE LAST SIX HAD NONE: a draft minted
  # DURING or AFTER a close carries the claim byte-identical, so `stale_claim?/2`
  # waves it through; `done -> done` is table-legal; preserved criteria pass the
  # criteria fence — and the publish then lands with `close_reason` gone, the
  # deferral's `reopen_trigger` gone, the `landed` merge record gone. rc=0, no
  # warning. This fence closes exactly that residue, on the SAME keys the api
  # patch door already fences for `disposition`/`reopen_trigger`
  # (`Content.Mutations.ensure_disposition_via_verb/4`) — the publish door was
  # simply never taught them.
  #
  # SCOPE, deliberately narrow:
  #   * only a published value that is PRESENT (non-nil) is protected — a task
  #     that never carried the key is free to gain one through any write;
  #   * `:sync` never reaches here (it takes the mirror-verbatim branch in
  #     `door_gate/4`), matching the transition and
  #     claim checks: a replica must be able to mirror an upstream close;
  #   * a draft carrying the value BYTE-IDENTICAL passes untouched, which is
  #     every draft derived from the current published content — the
  #     patch-then-publish idiom, the met-flip republish, the github collapse.
  #
  # Same `{:invalid_task_content, %{field => [msg]}}` family (422
  # `validation_failed`) the two gates beside it use — no new error code, no new
  # controller branch, and the message names the verb that owns the field.
  @task_door_owned_fields ~w(close_reason close_override disposition reopen_trigger engagement landed)

  @task_door_field_verbs %{
    "close_reason" => "`bp task close <id> <worker> <epoch> --reason <why>`",
    "close_override" => "`bp task close <id> <worker> <epoch> --criteria-override <why>`",
    "disposition" => "`bp task stage <id> <state> --disposition <open|parked|closed>`",
    "reopen_trigger" => "`bp task stage <id> <state> --reopen-trigger <condition>`",
    "engagement" => "`bp task stage <id> <state>`",
    "landed" => "`bp task close <id> <worker> <epoch>` (the landing record)"
  }

  defp task_door_field_fence(pub_content, draft_content) do
    Enum.find_value(@task_door_owned_fields, :ok, fn field ->
      was = Map.get(pub_content, field)
      now = Map.get(draft_content, field)

      if not is_nil(was) and now != was do
        {:error, {:invalid_task_content, task_door_field_error(field, was, now)}}
      end
    end)
  end

  defp task_door_field_error(field, was, now) do
    verb = Map.fetch!(@task_door_field_verbs, field)
    act = if is_nil(now), do: "erase", else: "overwrite"

    %{
      field => [
        "publish refused: this draft would #{act} `content.#{field}`, which the TASK door owns. " <>
          "The published row holds #{inspect(was)}; this draft carries #{inspect(now)}. " <>
          "Publishing copies a draft's content over the published row WHOLESALE, so a draft " <>
          "that simply predates (or never saw) the write is indistinguishable from an author " <>
          "asking to clear the field — and this one names no such intent. Only the sanctioned " <>
          "verb writes it: #{verb}. Rebase this draft on the current published row " <>
          "(`bp doc discard-draft` then re-patch, or carry the value verbatim) and publish again."
      ]
    }
  end

  # The criteria fence as a standalone gate: the ONE check that applies to
  # every publish source, `:sync` included (a stamped proof is erasable by no
  # replication payload).
  # ── THE TERMINAL-CRITERIA FENCE AT THE PUBLISH SEAM (task-b821ec4b2bcf8087)
  #
  # `criteria_fence/2` above is a REGRESSION fence: it walks the PUBLISHED row's
  # PROOF-BEARING criteria and refuses a draft that drops or unproves one. A
  # published row with NO criteria has no proof to regress, and a draft that ADDS
  # an unmet entry BESIDE the met ones regresses nothing at any occupied index —
  # so a draft minted BEFORE a close, carrying already-divergent criteria and
  # published AFTER it, sailed through and landed the row `done 1/2`. That is the
  # residue #17949 stated and deliberately left open: its fence is wired into
  # `Content.Writer`'s two task chains, and THIS write never passes Writer.
  #
  # The rule is already written and public, so this seam DECIDES with
  # `TerminalCriteriaFence.changes_terminal_criteria?/2` and lets that module
  # build the refusal (`refusal/2`) — one spelling of the rule, one spelling of
  # the sentence that teaches it. Everything the fence deliberately exempts
  # (a REOPEN in the same write, `blocked`, a write that does not name
  # `acceptance_criteria`, byte-identical criteria, a birth) is exempt here by
  # construction, because the predicate is the same one.
  #
  # `:sync` never reaches this function — `door_gate/4`
  # routes a mirror write to the bare `criteria_fence/2` — which matches the
  # fence's own `source != :api` exemption.
  defp terminal_criteria_fence(pub_content, draft_content) do
    if TerminalCriteriaFence.changes_terminal_criteria?(pub_content, draft_content) do
      TerminalCriteriaFence.refusal(pub_content, draft_content)
    else
      :ok
    end
  end

  defp criteria_fence(pub_content, draft_content) do
    case criteria_regression(pub_content, draft_content) do
      nil -> :ok
      regression -> {:error, {:invalid_task_content, criteria_regression_error(regression)}}
    end
  end

  defp stale_claim?(pub_content, draft_content) do
    pub_claim = pub_content["claim"]
    is_map(pub_claim) and map_size(pub_claim) > 0 and draft_content["claim"] != pub_claim
  end

  # The criteria fence. Returns the FIRST regression as
  # `%{index:, criterion:, kind: :dropped | :met | :evidence}`, or nil when the
  # draft preserves (or advances) every proof the published row holds.
  #
  # Only PROOF-BEARING published rows are consulted — `met: true`, or a
  # non-blank `evidence` string. An unmet, evidence-less criterion is free to
  # be reworded, reordered, deleted or added by any draft: authoring a task's
  # criteria list stays a plain content edit right up until a stamp lands on it.
  defp criteria_regression(pub_content, draft_content) do
    draft_list = criteria_list(draft_content)

    pub_content
    |> criteria_list()
    |> Enum.with_index()
    |> Enum.find_value(fn {pub_row, index} -> regression_at(pub_row, index, draft_list) end)
  end

  defp criteria_list(content) do
    case content["acceptance_criteria"] do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp regression_at(pub_row, index, draft_list) when is_map(pub_row) do
    met? = pub_row["met"] == true
    evidence = present_string(pub_row["evidence"])

    if met? or evidence do
      case criteria_counterpart(pub_row, index, draft_list) do
        nil ->
          regression(index, pub_row, :dropped)

        draft_row ->
          cond do
            met? and draft_row["met"] != true ->
              regression(index, pub_row, :met)

            evidence && is_nil(present_string(draft_row["evidence"])) ->
              regression(index, pub_row, :evidence)

            true ->
              nil
          end
      end
    end
  end

  defp regression_at(_pub_row, _index, _draft_list), do: nil

  defp regression(index, pub_row, kind),
    do: %{index: index, criterion: present_string(pub_row["criterion"]), kind: kind}

  # Match the draft's counterpart by criterion TEXT first so a legitimate
  # REORDER carries its stamp along, and fall back to the positional slot (the
  # index a stamp is addressed by) so a legitimate REWORD of an already-met
  # criterion is not mistaken for a drop.
  defp criteria_counterpart(pub_row, index, draft_list) do
    text = present_string(pub_row["criterion"])

    by_text =
      text &&
        Enum.find(draft_list, fn row ->
          is_map(row) and present_string(row["criterion"]) == text
        end)

    case by_text || Enum.at(draft_list, index) do
      row when is_map(row) -> row
      _ -> nil
    end
  end

  defp present_string(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp publish_transition_error(was, now) do
    %{
      "lifecycle_status" => [
        "illegal lifecycle transition #{inspect(was)} → #{inspect(now)}: publishing this " <>
          "draft would rewrite the published row's lifecycle — " <> publish_sanctioned_verb(now)
      ]
    }
  end

  # THE REMEDY MUST BE ONE THAT LANDS (task-922e616cb9b99243). This refusal
  # used to prescribe "re-derive the draft from the published row (patch, then
  # publish)". Measured live on guerrilla 2026-09-16/18 (task-bff844cc812f0fe4)
  # and again 2026-09-19 for this row: while `drafts.<id>` exists, the bare-id
  # patch is refused by the published-first fork fence
  # (`Mutations.draft_twin_error/1`, "Resolve the fork first"), and a publish
  # after that refuses HERE again, byte-identically. The two refusals pointed
  # at each other, so an operator following the printed sentence could not get
  # out. The sequence that lands: DISCARD the unlandable twin, then a BARE-ID
  # patch — published-first for a task (`@published_first_patch_types` /
  # `land_patch/5`), so it edits the published row in place and the claim
  # (worker, epoch, ts_iso, lease) rides through byte-identical. The wall
  # itself is unchanged.
  #
  # WHAT THE MESSAGE CAN AND CANNOT FILL IN (the criterion-1 split, re-derived
  # here rather than assumed). "A remedy that needs a human to adapt it is the
  # defect" binds the part that CLEARS THE REFUSAL, and that part is now
  # placeholder-free: `bp doc get … --perspective drafts` then
  # `bp doc discard-draft task <real id> --yes`, both printed with the real id,
  # both runnable as pasted, and after the second nothing is refused. What
  # follows — re-applying the operator's own edit — cannot be pre-filled from
  # here, and the reason is mechanical, not stylistic:
  #
  #   * the desired value IS `draft.content`, which this module does hold, but
  #     `doc.patch` declares `flags: [set]` and nothing else
  #     (`Barkpark.Plugins.Capabilities`, the `doc.patch` core_cmd — the
  #     `--file` line is still owed and is pinned as owed by the CLI's own
  #     `doc_patch_file_body_e2e_test.go`). So the only expression available is
  #     inline `key=value` / `key:=json` ON A SHELL COMMAND LINE.
  #   * rendering arbitrary draft content into a shell-pasteable command inside
  #     a JSON error field means shell-quoting text that routinely carries
  #     newlines, quotes and `$`. A mis-quoted command that RUNS and writes
  #     something else is strictly worse than an honest placeholder.
  #   * the size is unbounded: a real row's `acceptance_criteria` is multi-KB,
  #     and this string is a 422 body.
  #
  # So `<field>=<value>` stays, and the message says whose it is and where to
  # read it back from — the capture step above exists for exactly that.
  #
  # SELF-RETIREMENT, STATED PRECISELY. `internal/cli/stale_draft_publish_remedy.go`
  # prints its corrective advisory only when ONE string under
  # `error.details.claim` carries BOTH `staleDraftClaimMarker` ("stale draft:
  # the published row carries claim state") AND `staleDraftBrokenRemedy`
  # ("Re-derive the draft from the published row"). This message drops the
  # second, so the advisory goes silent — that is the whole retirement.
  #
  # The phrase itself is NOT gone from this file: `criteria_regression_error/1`
  # below still uses it. That is harmless and must not be "fixed" by deleting
  # it there: that error is emitted under the `"acceptance_criteria"` key, and
  # the guard reads ONLY `.claim`, so it is structurally invisible to it — not
  # merely failing the two-clause AND. An earlier revision of this comment said
  # the phrase was "deliberately absent", full stop; it was absent from THIS
  # message only, and anyone who grepped the file would have caught the comment
  # lying rather than the code being wrong.
  defp stale_claim_error(pub_content, pid) do
    worker = get_in(pub_content, ["claim", "worker"])
    epoch = get_in(pub_content, ["claim", "epoch"])

    %{
      "claim" => [
        "stale draft: the published row carries claim state (worker #{inspect(worker)}, " <>
          "epoch #{inspect(epoch)}) this draft does not — publishing would obliterate it. " <>
          "Do NOT patch-then-publish: while `drafts.#{pid}` exists the bare-id patch is " <>
          "refused by the fork fence and this publish refuses again. To CLEAR this " <>
          "refusal, run these two exactly as printed: `bp doc get task #{pid} " <>
          "--perspective drafts` (keep the twin's bytes — `bp doc get` reads the " <>
          "published lens by default), then `bp doc discard-draft task #{pid} --yes`. " <>
          "To then LAND the edit you were publishing, re-apply it with a bare-id patch " <>
          "— `bp doc patch task #{pid} --set <field>=<value> --yes` — which is " <>
          "published-first for a task, so the claim rides through untouched; only " <>
          "<field>=<value> is yours to fill, and the first command above is where you " <>
          "read it back from. Or move the claim through the sanctioned verbs " <>
          "(`bp task claim` / `bp task release` / `bp task close`)."
      ]
    }
  end

  # Twin in shape and intent of `stale_claim_error/1`: name the exact row that
  # would lose its proof, say WHY the draft cannot see it, and name the
  # recovery. A refusal an operator cannot act on is a different bug.
  defp criteria_regression_error(%{index: index, criterion: criterion, kind: kind}) do
    %{
      "acceptance_criteria" => [
        "stale draft: publishing this draft would #{criteria_regression_verb(kind)} for " <>
          "acceptance criterion #{index}#{criterion_label(criterion)} — the published row " <>
          "holds that proof and this draft does not. A stamp is written DIRECTLY to the " <>
          "published row (`bp task stamp`) and never rebases an open draft, so a draft " <>
          "minted before the stamp still carries the pre-stamp criteria. Re-derive the " <>
          "draft from the published row (`bp doc discard-draft` the twin, then a bare-id " <>
          "`bp doc patch` — published-first, it lands without a publish), or move " <>
          "the criterion through the sanctioned verbs (`bp task stamp` / `bp task close`)."
      ]
    }
  end

  defp criteria_regression_verb(:dropped), do: "drop the proof-bearing row"
  defp criteria_regression_verb(:met), do: "clear the `met: true` flag"
  defp criteria_regression_verb(:evidence), do: "blank the recorded evidence"

  defp criterion_label(nil), do: ""
  defp criterion_label(criterion), do: " (#{inspect(String.slice(criterion, 0, 80))})"

  # Names the sanctioned verb per refused target — the refusal TEACHES (the
  # tasks_controller stage/close precedent). Twin of Writer.sanctioned_verb/1.
  defp publish_sanctioned_verb("done"),
    do:
      "`done` is reached only through the close primitive (`bp task close <id> <worker> " <>
        "<epoch>`, POST /v1/tasks/:id/close), which records who closed it."

  defp publish_sanctioned_verb("in_progress"),
    do:
      "a live claim is minted only by the claim primitive (`bp task claim <id> <worker>`, " <>
        "POST /v1/tasks/:id/claim), which fences on the claim epoch."

  defp publish_sanctioned_verb(to) when to in ~w(considering researching),
    do:
      "thought states move through the sanctioned stage verb (`bp task stage <id> #{to}`, " <>
        "POST /v1/tasks/:id/stage), which enforces the same legality table."

  defp publish_sanctioned_verb(_to),
    do:
      "move through the sanctioned task lifecycle verbs instead (`bp task stage` for " <>
        "considering|researching|open, `bp task claim`, `bp task close`)."

  # THE CRITERIA FENCE, RE-EVALUATED WHERE THE WRITE ACTUALLY HAPPENS.
  #
  # `door_gate/4` already runs `criteria_fence/2`
  # at the publish door, and that gate keeps ALL of its teeth — it is what
  # gives a caller a side-effect-free refusal before the wall and the hooks
  # run. What it cannot do is speak for the row as it will be at UPDATE time:
  # it reads the published row outside the transaction, and the window between
  # that read and this write is real wall-clock time (the exemption read, the
  # label-spine check, the tag-registry check, the dedup scan, the whole
  # `:before_publish` hook chain). A `Tasks.Stamp` landing anywhere in there
  # answered its caller with a success receipt and then lost the flip AND the evidence
  # to `"content" => pub_content` below — observed during PDS wave 23, and
  # reproduced deterministically by
  # `test/barkpark/tasks/stamp_publish_lost_update_test.exs`.
  #
  # REFUSAL, NOT MERGE, and deliberately so. Merging the stamped criterion
  # back into the draft's list would publish content no author ever wrote and
  # would have to guess how a re-ordered or re-worded draft list lines up with
  # the proven one. The refusal reuses the SAME `{:invalid_task_content, _}`
  # shape and the SAME message the door-level fence emits, so a caller cannot
  # tell which of the two refused it and no new error vocabulary reaches the
  # HTTP layer, the CLI exit-code table or the sync applier's error classes.
  # The lifecycle's `Repo.rollback/1` of the returned reason, inside the
  # transaction, unwinds the published update
  # and the fenced draft delete together, so the draft survives to be rebased
  # — the same remedy the door-level refusal names.
  #
  # Every publish SOURCE is covered here, `:sync` included, matching the
  # door-level rule that a stamped proof is erasable by no replication payload.
  @doc """
  Phase `:in_transaction` fence (see the moduledoc). `:ok`, or `{:error, reason}`
  for the lifecycle to `Repo.rollback(reason)` with.
  """
  @spec no_criteria_regression(String.t(), Document.t(), map(), keyword()) ::
          :ok | {:error, term()}
  def no_criteria_regression("task", %Document{content: pub_content}, pub_attrs, opts) do
    pub_content = pub_content || %{}
    draft_content = pub_attrs["content"] || %{}

    with :ok <- criteria_fence(pub_content, draft_content) do
      # The TERMINAL fence, re-evaluated here for the SAME reason the
      # regression fence is (task-b821ec4b2bcf8087): the door-level verdict
      # was taken against a published row read outside this transaction, and
      # a `Tasks.Close` landing in that window is EXACTLY the shape this
      # fence names — the row was open when the gate looked and is `done` by
      # the time this update runs. `:sync` is exempt at the door, so it is
      # exempt here too (the fence's own `source != :api` rule); nothing else
      # about the predicate changes.
      if Keyword.get(opts, :source, :api) == :sync do
        :ok
      else
        terminal_criteria_fence(pub_content, draft_content)
      end
    end
  end

  def no_criteria_regression(_type, _existing, _pub_attrs, _opts), do: :ok
end
