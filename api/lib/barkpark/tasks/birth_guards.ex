defmodule Barkpark.Tasks.BirthGuards do
  @moduledoc """
  The two task birth guards the core writer used to own
  (`Barkpark.Content.Writer.ensure_task_born_adjudicated/5` and
  `ensure_task_surface_declared/5`, task-2978357a0701cd10), now pre-write
  fences the Tasks plugin declares (`Barkpark.Plugins.Tasks.pre_write_fences/0`)
  at the exact position they held in the writer's `with` chain: after
  `CriteriaRequiredFence`, before `Dedup.check_new_task/5`.

  Moved VERBATIM. Each guard keeps its return shapes (`:ok` or
  `{:error, {:invalid_task_content, %{field => [msg]}}}`), its refusal text,
  its `:source` exemption, and its warn-tier `Logger.warning` line
  (`pds birth fence: unadjudicated task birth`, `filing law: undeclared
  surface`) byte for byte; the only change is the uniform fence arity, which
  adds a `dataset` argument neither guard reads.

  Both guards read `Barkpark.Tasks.Stage` — the reason they belong to the
  Tasks side, and the reason `Barkpark.Content.Writer` no longer names it.
  """

  require Logger

  alias Barkpark.Content.{Document, DraftId}
  alias Barkpark.Tasks.Stage

  # ── THE BIRTH FENCE (PDS wave 28) ─────────────────────────────────────────
  #
  # `Mutations.ensure_disposition_via_verb/4` fences every CHANGE of
  # `content.disposition` on a live row, and states its own residual harm:
  # "`ensure_*("task", nil, …), do: :ok` is the head of every sibling guard, and
  # the plain `create` clause calls no guard at all. So a `createOrReplace` on a
  # BRAND-NEW id carrying `disposition: "parked"` and no trigger is STILL
  # ACCEPTED". That is a row which SAYS it was adjudicated and adjudicated
  # nothing — born hollow, and thereafter untouchable by the update-path fence
  # precisely because the value never changes again.
  #
  # This is that fence, at the only place that can express "birth": beside
  # the task dedup fence in `do_create_document`'s `with` chain (since
  # task-2978357a0701cd10 as a Tasks pre-write fence the chain runs), where
  # `prev_doc` is already resolved and `opts` is already in hand. Three other
  # placements were measured and REFUTED (PDS-D393):
  #
  #   * `Barkpark.Tasks.Validation` is pure and receives CONTENT only — and
  #     `/v1/data/mutate`'s patch clauses (the two `"patch"` clauses of
  #     `mutations.ex:apply_one/3` — cited by SYMBOL because line anchors
  #     are what rot) build `merged` and hand it to `upsert_document`,
  #     which validates it.
  #     Merge happens BEFORE validation on EVERY update, so a content-only rule
  #     is RETROACTIVE: it would 422 every future patch to today's bare rows.
  #   * `validate_task_kind/2` is arity 2 — it never receives `opts`, so it can
  #     carry no `:source` carve-out — and it runs at `:114`/`:490` BEFORE
  #     `prev_doc` is resolved, so it cannot tell a birth from an update.
  #   * A DB CHECK is stateless: it sees the candidate row and never `prev_doc`,
  #     so it can require a disposition on ALL task rows or on NONE. (No
  #     migration is forced either — `20260528100000_w7a_task_schema` constrains
  #     `lifecycle_status` VALUES only.)
  #
  # WHAT IS HARD, AND WHY EXACTLY THAT. The rule is PARITY WITH THE VERB: the
  # birth door may not accept an adjudication that `Barkpark.Tasks.Stage` — the
  # one sanctioned writer — would refuse. Stage refuses a term outside its
  # vocabulary and refuses a park with no reopen trigger, so those two refusals
  # transfer here verbatim, sourced from Stage's own accessors so the two doors
  # can never drift. Case is exact for the same reason Stage normalises: the
  # measured OPEN 57 / open 47 split is a raw-door artefact, and a birth that
  # writes "OPEN" would re-open it under a fence that claims to have closed it.
  #
  # WHAT IS A WARN, AND WHY IT IS HONEST TO SAY SO. A birth carrying NO
  # disposition at all is LOGGED (`pds birth fence: unadjudicated task birth`,
  # greppable and countable) and allowed. Requiring one is not a fence, it is a
  # protocol change for every existing producer — `bp task create`, every fleet
  # file-order, every fixture — and landing it as a hard halt here would refuse
  # writes that no client yet knows how to make. The promotion to hard is filed
  # as its own row rather than implied; until it lands, "residue 0 by
  # construction" is FALSE and this comment is where that is admitted.
  #
  # REPLICATION IS EXEMPT, checked FIRST, for the reason the sibling guard
  # states: `Sync.Applier.apply_upsert` mirrors an upstream row verbatim inside
  # one transaction, so a refusal would roll back the whole batch and wedge the
  # replica. `:source` is server-set (every HTTP door prepends `source: :api`),
  # so a request body can never reach a non-`:api` value. The inbound GitHub
  # bridge rides `source: :github` and is therefore structurally exempt — but it
  # is NOT exempted in practice: `Github.Intake.build_attrs/4` supplies the term
  # AND a reason naming the issue, so the bridge is born adjudicated and the
  # carve-out is only its fail-safe. That matters because an unmatched intake
  # error becomes HTTP 500 (`intake.ex` fallthrough →
  # `github_webhook_controller.ex`), and GitHub redelivers a 5xx forever.
  @doc "The birth-adjudication fence. See the header above."
  def born_adjudicated(type, attrs, dataset, doc_id, prev_doc, opts)

  def born_adjudicated("task", attrs, _dataset, doc_id, nil = _prev_doc, opts) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}
    term = Map.get(content, "disposition") || Map.get(content, :disposition)
    trigger = Map.get(content, "reopen_trigger") || Map.get(content, :reopen_trigger)

    cond do
      Keyword.get(opts, :source, :api) != :api ->
        :ok

      blank?(term) ->
        # ONE greppable line, deliberately: this warning fires on every bare
        # birth, so its value is that it can be COUNTED
        # (`grep -c "pds birth fence: unadjudicated"`) — a paragraph per row
        # would drown the signal it exists to raise.
        Logger.warning(
          "pds birth fence: unadjudicated task birth #{inspect(doc_id)} — no " <>
            "content.disposition (allowed; adjudicate with `bp task stage <id> <state> " <>
            "--disposition <open|parked|closed> --note <why>`)"
        )

        :ok

      term not in Stage.dispositions() ->
        {:error, {:invalid_task_content, birth_disposition_term_error(term)}}

      term in Stage.trigger_required_dispositions() and blank?(trigger) ->
        {:error, {:invalid_task_content, birth_hollow_park_error(term)}}

      true ->
        :ok
    end
  end

  def born_adjudicated(_type, _attrs, _dataset, _doc_id, _prev_doc, _opts), do: :ok

  # ── THE FILING-LAW DOOR GUARD (cloud-console-hardening D307 / D331) ───────
  #
  # Standing Law 0 of the cloud-console-hardening epic says a row filed under
  # the epic declares WHICH SURFACE it is about. Wave 27 proved by hand that the
  # law can hold — 13 of 13 instrument rows went to the successor at create time
  # and zero residue reached the parent — but it held because a person was
  # watching. This is the door that makes it hold without one.
  #
  # THE SEAT IS HERE, beside `born_adjudicated/6` (D331, which
  # SUPERSEDES D324's `Content.apply_mutations` placement). D324 filed the guard
  # at `mutations.ex` on the premise that its create clause carries no guard —
  # true at that file, wrong as a conclusion: a create-time HARD refusal already
  # ships one layer down, where `prev_doc == nil` IS birth and `opts` (and so
  # `:source`) is already in hand. The three placements the birth fence's own
  # header measured and REFUTED (PDS-D393 — pure content-only validation is
  # retroactive, `validate_task_kind/2` cannot see `prev_doc` or `:source`, a DB
  # CHECK is stateless) refute them for this guard identically. So this copies
  # that function's shape verbatim: same arity, same `{:error,
  # {:invalid_task_content, %{field => [msg]}}}` family (→ 422
  # `validation_failed`, no new error code, no new controller branch), same
  # non-`:api` source exemption, same two-tier hard/warn doctrine.
  #
  # THE SCOPING, AND WHAT IT IS MEASURABLY WORTH TODAY. The guard fires only for
  # a birth whose `content.parent_id` (drafts-normalised) is the epic. The wave
  # brief predicted that deleting that one arm would take
  # `mutate_controller_test.exs` to 23 failures including the D53 create-family
  # pins; RUN, IT DOES NOT — the mutation (delete `not cch_epic_child?(parent)
  # -> :ok`, change nothing else) yields 46 tests / 1 failure, and that one
  # failure is this slice's own scoping test. The prediction was derived against
  # a PRESENCE requirement, which would indeed refuse every task fixture in the
  # repo; D331 made ABSENCE the warn tier, and no fixture outside this slice's
  # own block carries a `surface` key at all, so an unscoped guard has almost
  # nothing to refuse. The scoping still ships — it is what stops this epic's
  # filing law from silently becoming a global rule the day another epic uses
  # the word `surface` — but it is a DESIGN boundary, not a load-bearing leg
  # under today's corpus, and saying otherwise here would be the kind of
  # sentence this epic exists to delete.
  #
  # WHAT IS HARD: an OFF-VOCABULARY `surface`. The vocabulary is closed and
  # EXACT CASE, for the reason the birth fence states about `OPEN`/`open`: a
  # differently-cased term is a row that claims to be classified in a language
  # nothing else reads, and the raw door is exactly how that split gets in.
  #   * `console`    — a surface a person operates.
  #   * `instrument` — a gate, harness, generator or required-check.
  #   * `ledger`     — a defect in the TASK ROSTER itself. This does NOT collapse
  #     into `instrument`: rows like `cchi-w27-bl-d307-create-time-door-guard`
  #     have no console and no harness, and folding them would make the filing
  #     law classify ITSELF as an instrument defect.
  #
  # WHAT IS A WARN, AND WHY THAT IS THE HONEST TIER. A birth carrying NO
  # `surface` is LOGGED (one greppable, countable line) and ALLOWED. Requiring
  # presence today would refuse legitimate filings, and that is measured, not
  # feared: `surface` is a three-day-old convention carried by only 5 of the 347
  # rows created before 2026-08-02, and of the 56 live orphans it is populated
  # on 5 and null on 51 — a presence requirement armed now refuses 91% of
  # legitimate filings. The backfill that would earn the promotion is not
  # mechanically producible either: blind against the 15 open rows carrying
  # human-written surface prose, a description classifier scores 7/15 (47%) and
  # a structured-field classifier 6/15 (40%), while a one-line constant scores
  # 11/15 (73%) — both BELOW the majority baseline. (D324 filed this guard
  # rather than shipping one that lies after measuring its drafted predicate
  # refusing 4 of 6 legitimately person-facing rows.) The promotion to hard is
  # its own row; until the backfill lands, "every epic row declares a surface"
  # is FALSE and this comment is where that is admitted.
  #
  # REPLICATION IS EXEMPT, checked FIRST, for the sibling guards' reason:
  # `Sync.Applier.apply_upsert` mirrors an upstream row verbatim inside one
  # transaction, so a refusal would roll back the batch and wedge the replica.
  # `:source` is server-set on every HTTP door, so no request body can reach it.
  #
  # THE THIRD BYPASS, NAMED (cch-w29-bl-d307-guard-bypassed-by-create-patch-publish).
  # Two windows were already enumerated above and closed — `do_upsert_document`'s
  # own INSERT branch (the legacy `POST /api/documents/task` door), and a
  # `drafts.`-prefixed `parent_id`. A THIRD was open and, worse, was written
  # down as a design property rather than a hole: this guard head-matched
  # `nil = prev_doc`, so it was a BIRTH guard, and a birth guard cannot see the
  # write that carries the term when the term arrives SECOND. PROVEN LIVE
  # against guerrilla in wave 29, three calls: create the row BARE under the
  # epic (lands — absence is the warn tier), PATCH `surface` to the very prose
  # a create had just been refused for (200), PUBLISH (200). The published row
  # then read back `"surface":"cloud control plane - probe"` under
  # `parent_id: cloud-console-hardening-epic`. So "an off-vocabulary term
  # cannot enter the epic" was false as stated, and the sentence that made it
  # look intentional — "every UPDATE arriving here is structurally untouched" —
  # was the reassuring one.
  #
  # CLOSED BY DELETING THE `nil` HEAD, not by adding a fourth guard: the clause
  # now runs on updates too, and the birth/update distinction survives exactly
  # where it is load-bearing. An update whose merged `surface` is off-vocabulary
  # is refused UNLESS it equals what the row already carried (`previous_surface/1`
  # below) — grandfathered rows stay patchable on every other field, which is
  # what keeps this a guard on the WRITE rather than a retroactive audit of the
  # corpus. The absent-surface WARN stays birth-only; counting it per patch
  # would make `grep -c` measure patch traffic instead of filings.
  @cch_epic_parent "cloud-console-hardening-epic"
  @cch_surfaces ~w(console instrument ledger)

  @doc "The filing-law surface fence. See the header above."
  def surface_declared(type, attrs, dataset, doc_id, prev_doc, opts)

  def surface_declared("task", attrs, _dataset, doc_id, prev_doc, opts) do
    content = Map.get(attrs, "content") || Map.get(attrs, :content) || %{}
    parent = Map.get(content, "parent_id") || Map.get(content, :parent_id)
    surface = Map.get(content, "surface") || Map.get(content, :surface)

    cond do
      Keyword.get(opts, :source, :api) != :api ->
        :ok

      not cch_epic_child?(parent) ->
        :ok

      blank?(surface) ->
        # ONE greppable line, deliberately (the birth fence's precedent): this
        # fires on every undeclared epic filing, so its value is that it can be
        # COUNTED — `grep -c "filing law: undeclared surface"`. BIRTH ONLY: an
        # update that leaves the term absent is not a new undeclared filing, and
        # logging it would make the count grow with unrelated patch traffic.
        if is_nil(prev_doc) do
          Logger.warning(
            "filing law: undeclared surface on epic task birth #{inspect(doc_id)} — no " <>
              "content.surface (allowed; the backfill is not yet producible — 5 of 56 live " <>
              "orphans carry one. Declare it with one of: " <>
              Enum.join(@cch_surfaces, " | ") <> ")"
          )
        end

        :ok

      surface in @cch_surfaces ->
        :ok

      # GRANDFATHERED, and only this: the term is off-vocabulary but the write
      # does not CHANGE it, so this update did not carry the defect in. Rows
      # born before the guard (and the ones the create→patch→publish window let
      # through while it was open) stay patchable on every OTHER field —
      # criterion 2 of the row. A write that touches `surface` itself falls
      # through to the refusal below, on an update exactly as on a birth.
      not is_nil(prev_doc) and surface == previous_surface(prev_doc) ->
        :ok

      true ->
        {:error, {:invalid_task_content, birth_surface_term_error(surface)}}
    end
  end

  def surface_declared(_type, _attrs, _dataset, _doc_id, _prev_doc, _opts), do: :ok

  # `attrs` reaching the upsert gate is already the FINAL whole-document content
  # (patch merging ran in `upsert_document/4`), so the incoming `surface` is the
  # MERGED value — indistinguishable, on its own, from a term the row already
  # carried. The previous value is what makes an unrelated patch of a
  # grandfathered row separable from a patch that writes the term.
  defp previous_surface(%Document{content: content}),
    do: Map.get(content || %{}, "surface") || Map.get(content || %{}, :surface)

  defp previous_surface(_prev_doc), do: nil

  # The epic slug, drafts-normalised: a draft filing carries
  # `parent_id: "drafts.cloud-console-hardening-epic"` from the same
  # draft-first write path every other task field rides, and a guard that only
  # matched the published spelling would be bypassable by filing a draft.
  defp cch_epic_child?(parent) when is_binary(parent),
    do: DraftId.published_id(parent) == @cch_epic_parent

  defp cch_epic_child?(_parent), do: false

  # Same `invalid_task_content` family as the transition, disposition and birth
  # siblings (422 `validation_failed` with a per-field details map). The message
  # is the retry instruction: it names the vocabulary AND what each term means,
  # because the refusal is the only place a filer learns the law.
  defp birth_surface_term_error(term) do
    %{
      "surface" => [
        "cannot be filed under #{inspect(@cch_epic_parent)} as #{inspect(term)}. A row in this " <>
          "epic declares WHICH SURFACE it is about, drawn from a fixed, lowercase-canonical " <>
          "vocabulary (#{Enum.map_join(@cch_surfaces, ", ", &inspect/1)}): \"console\" is a " <>
          "surface a person operates, \"instrument\" is a gate/harness/generator/required-check, " <>
          "and \"ledger\" is a defect in the task roster itself. An off-vocabulary or " <>
          "differently-cased term is a row that claims to be classified in a language nothing " <>
          "else reads, which is how the epic's residue became uncountable in the first place. " <>
          "Re-file with one of the three terms, or omit `surface` entirely — an undeclared " <>
          "surface is warned and allowed while the backfill is unproducible."
      ]
    }
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false

  # Same `invalid_task_content` family as the transition and disposition
  # siblings (422 `validation_failed` with a per-field details map) — no new
  # error code, no new controller branch. The message is the retry instruction.
  defp birth_disposition_term_error(term) do
    %{
      "disposition" => [
        "cannot be born as #{inspect(term)}. A disposition is an adjudication drawn from a " <>
          "fixed, lowercase-canonical vocabulary (#{Enum.map_join(Stage.dispositions(), ", ", &inspect/1)}) — " <>
          "an off-vocabulary or differently-cased term is a row that claims to be decided in " <>
          "a language nothing else reads, and it is exactly how the measured OPEN/open split " <>
          "got in. File the task without a disposition and adjudicate it through the sanctioned " <>
          "verb (`bp task stage <id> <state> --disposition <open|parked|closed> --note <why> " <>
          "--reopen-trigger <what would reconsider it>`, POST /v1/tasks/:id/stage), which " <>
          "normalises the term and writes term, reason and trigger in one atomic write."
      ]
    }
  end

  defp birth_hollow_park_error(term) do
    %{
      "reopen_trigger" => [
        "is required when a task is BORN #{inspect(term)}. The reopen trigger is the only " <>
          "thing that makes a park a deferral rather than a silent drop: without it nothing " <>
          "states what would bring the row back, and because the term never changes again the " <>
          "update-path fence will never see it either. Supply `reopen_trigger` at birth, or " <>
          "file the task undecided and park it through the sanctioned verb (`bp task stage " <>
          "<id> <state> --disposition parked --note <why> --reopen-trigger <what would " <>
          "reconsider it>`, POST /v1/tasks/:id/stage)."
      ]
    }
  end
end
