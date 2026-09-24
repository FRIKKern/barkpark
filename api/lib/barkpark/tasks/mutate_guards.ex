defmodule Barkpark.Tasks.MutateGuards do
  @moduledoc """
  The task guards of the RAW mutate door (`/v1/data/mutate`,
  `Barkpark.Content.Mutations.apply_mutations/3`), declared by the Tasks
  plugin through `Barkpark.Plugin.mutate_door_fences/0`
  (task-b04cbe7823d084a6). Until this module they were private functions of
  `Content.Mutations`, which named `Barkpark.Tasks.Stage` and
  `Barkpark.Tasks.QueueGate` to run them.

  They run ONLY on that door, at the positions they held there (see
  `Barkpark.Content.MutateDoorFences` for the phases and why the writer's
  pre-write fences could not carry them):

    * `:before_rev` — `create_not_forking_published/6`, the create family's
      published-fork fence (also run by the legacy create door through
      `Content.Mutations.ensure_create_not_forking_published_task/4`).
    * `:after_claim`, in this order — `disposition_via_verb/6` (term, rerun,
      operating instruction, reopen trigger), `adoption_adjudicated/6`,
      `disposition_owner_registered/6`.

  Every fence takes `(type, existing, merged, op, dataset, opts)` — the row
  the mutate door resolved, the content the write will carry, the raw
  mutation payload — and returns `:ok` or the refusal the door used to return,
  byte for byte. The guard bodies below are the ones that sat in
  `Content.Mutations`, moved unchanged; each still exempts `source: :sync`
  first.
  """

  alias Barkpark.Content
  alias Barkpark.Content.{DraftId, Warnings}
  alias Barkpark.Tasks.QueueGate
  alias Barkpark.Tasks.Stage

  # The type whose create family can fork a published row (mirrors the mutate
  # door's published-first patch types — `task` only).
  @published_first_types ~w(task)

  @doc "`:before_rev` — the create family's published-fork fence."
  def create_not_forking_published(type, _existing, _merged, op, dataset, opts),
    do: ensure_create_not_forking_published_task(type, op_id(op), dataset, opts)

  @doc "`:after_claim` — the adjudication triple, rerun and operating instruction by verb."
  def disposition_via_verb(type, existing, merged, _op, _dataset, opts),
    do: ensure_disposition_via_verb(type, existing, merged, opts)

  @doc "`:after_claim` — a reparent must leave the row adjudicated."
  def adoption_adjudicated(type, existing, merged, _op, _dataset, opts),
    do: ensure_adoption_adjudicated(type, existing, merged, opts)

  @doc "`:after_claim` — a written `disposition_owner` must be a registered role."
  def disposition_owner_registered(type, existing, merged, _op, _dataset, opts),
    do: ensure_disposition_owner_registered(type, existing, merged, opts)

  # The id the create family addresses — the same `_id || doc_id` read
  # `apply_one/3` makes.
  defp op_id(%{} = op), do: op["_id"] || op["doc_id"]
  defp op_id(_op), do: nil

  # ── The adjudication's own fence (PDS wave 24, charter D298 amended) ──────
  #
  # THE CLASS THIS CLOSES: a `type:task` row that SAYS it was adjudicated and
  # cannot say on what terms. `content.disposition` is the epic's adjudication
  # vocabulary — `open` / `parked` / `closed` — and until this slice it had ZERO
  # code writers repo-wide (re-derived 2026-07-30: `git grep '"disposition'`
  # over `api/lib`, `internal`, `js` and `scripts` returned exactly two hits,
  # neither a writer of the term). It existed because charter D298 instructed
  # AGENTS to hand-patch it through this very door. A field with no writer has,
  # by construction, no normaliser and no requirement, and the measured
  # consequence was both: a vocabulary reading `OPEN` 57 / `open` 47 / `parked`
  # 27 / ABSENT 37, and parked rows carrying nothing that says what would ever
  # reopen them. `content.reopen_trigger` existed in zero files and on zero
  # rows.
  #
  # WHY A GUARD HERE IS NOT ENOUGH ON ITS OWN, AND WHY THE VERB IS NOT EITHER.
  # This is the two-door judgment, and it is settled by measurement, not taste:
  #   * `Barkpark.Tasks.Stage` — the sole sanctioned writer of a durable
  #     adjudication REASON — could not write the TERM at all. Measured pre-fix:
  #     after a stage the persisted keys were exactly
  #     ["description","disposition_reason","engagement","kind",
  #      "lifecycle_status","tags"]. A stage-side requirement therefore cannot
  #     even SEE a parked disposition, so it can never fire.
  #   * Conversely a guard ONLY here leaves that sanctioned writer unfenced:
  #     `api/lib/barkpark/tasks/` contains ZERO references to
  #     `Content.apply_mutations` (the same fact the close guard in `Content.Mutations` relies
  #     on), and `Stage` persists with a bare `Repo.update_all` inside its own
  #     advisory lock.
  # Both doors are therefore load-bearing: this one refuses the raw write and
  # NAMES the verb; `Tasks.Stage` makes the verb able to write the whole triple
  # (term + reason + trigger) atomically, and refuses a park with no trigger.
  #
  # SCOPE: ANY CHANGE OF THE TERM, NOT JUST A HOLLOW PARK. Refusing only
  # `parked`-without-a-trigger has a near-zero fire rate — under the charter's
  # own recipe a park usually arrives WITH a reason, and the ungoverned
  # two-case `OPEN`/`open` writes would sail past untouched. Refusing every raw
  # change routes all of them to the one writer that normalises, which is what
  # makes the vocabulary converge instead of merely making one shape harder.
  # `now == was` is NOT a change: bookkeeping on already-adjudicated rows
  # (digests, github sync fingerprints, compaction) passes untouched, exactly
  # as it does for the two sibling guards.
  #
  # THE SECOND STEP IS FENCED TOO. Writing the term through the verb and then
  # erasing `reopen_trigger` through this door would restore hollowness in two
  # moves, so an api-door write that BLANKS or DROPS the trigger of a row whose
  # resulting disposition is `parked` is refused as well. ADDING a trigger raw
  # is deliberately still allowed — it can only make an existing hollow park
  # honest, and the 27 already-parked rows need exactly that remediation.
  #
  # THERE IS NO REVISION ESCAPE, UNLIKE THE CLOSE GUARD. A rev precondition
  # proves the caller READ the row; it says nothing about whether the value
  # being written is a governed term with its trigger. The escape here is the
  # verb, and the message says so.
  #
  # REPLICATION IS EXEMPT, checked FIRST, for the same concrete reason the
  # claim fence states: `Sync.Applier.apply_upsert` mirrors an upstream row with
  # `createOrReplace` + the FULL remote document, and because `apply_mutations`
  # wraps the batch in one transaction, a refusal would roll back the ENTIRE
  # sync batch and wedge the replica on that row with no operator recourse.
  # `:source` is server-set (`MutateController` prepends `source: :api`), so a
  # request body can never reach the `:sync` value.
  #
  # THE FRESH-CREATE EXEMPTION IS STILL INHERITED HERE, AND IS NOW CLOSED
  # DOWNSTREAM (PDS wave 28). `ensure_*("task", nil, …), do: :ok` is still the
  # head of every sibling guard on this seam and the plain `create` clause still
  # calls none of them — that is unchanged and correct, because a birth has no
  # prior revision and no prior term for a CHANGE guard to compare against.
  # What changed is that the create-family doors all funnel into
  # `Content.create_document/4`, and `Tasks.BirthGuards.born_adjudicated/6` now
  # sits in that chain where `prev_doc == nil` IS expressible: a birth carrying
  # an off-vocabulary term, or a park with no reopen trigger, is refused there.
  # It is a fence and not a ban — a COMPLETE adjudication is born, so the
  # dataset-importer shape the substrate anticipates (migration
  # 20260528100000) still works. The pinning test inverted on purpose.
  #
  # WHAT REMAINS, STATED NOT IMPLIED AWAY: a birth carrying NO disposition at
  # all is logged and allowed (see that function's comment for why a hard
  # requirement is a protocol change, not a fence), so "every task row is
  # adjudicated" is NOT true by construction yet.
  #
  # THE VOCABULARY IS NOT RETYPED HERE. `Barkpark.Tasks.Stage` is the one
  # writer of an adjudication and therefore the one owner of its key names and
  # its term set; this door SCREENS the same triple, so it reads them from
  # Stage (`disposition_key/0`, `reopen_trigger_key/0`,
  # `disposition_rerun_key/0`, `dispositions/0`,
  # `trigger_required_dispositions/0`) rather than keeping a second copy. The
  # copy used to sit 80 lines above a `Stage.dispositions()` call in this same
  # function group: two spellings of one truth table, with nothing that reds
  # when they diverge. Adding a fourth term to Stage now moves this door with
  # it. `mutations_adjudication_vocabulary_lock_test.exs` is the both-directions
  # lock; the same shape landed for the schema in #17843.

  # PDS wave 28: the FOURTH durable key gets the SAME raw-door treatment as the
  # term. `Tasks.Stage` screens a rerun that cannot fail (`git -C`, a `test`
  # predicate, command substitution, `merge-base --is-ancestor`, a pipe-masked
  # formatting tail) at the write seam — a screen a raw patch would walk
  # straight past, leaving the sanctioned-writer property as decoration. Any
  # CHANGE of the key through this door is refused and named to the verb;
  # `now == was` is not a change, so bookkeeping passes untouched.

  defp ensure_disposition_via_verb("task", nil, _merged, _opts), do: :ok

  defp ensure_disposition_via_verb("task", existing, merged, opts) do
    was = existing.content || %{}
    was_term = was[Stage.disposition_key()]
    now_term = merged[Stage.disposition_key()]

    cond do
      # Replication mirrors upstream rows verbatim — checked BEFORE any change
      # predicate so a mirror always applies.
      Keyword.get(opts, :source, :api) != :api ->
        :ok

      # The term CHANGED through the raw door. Route it to the verb.
      now_term != was_term ->
        {:error, {:invalid_task_content, disposition_bypass_error(was_term, now_term)}}

      # The RERUN changed through the raw door — the same bypass one field
      # over. Route it to the verb, which screens a rerun that cannot fail.
      merged[Stage.disposition_rerun_key()] != was[Stage.disposition_rerun_key()] ->
        {:error,
         {:invalid_task_content, rerun_bypass_error(merged[Stage.disposition_rerun_key()])}}

      # THE OPERATING-INSTRUCTION SLOT changed through the raw door
      # (task-bd7476eecdede252). The whole point of giving standing guidance
      # its own key is that it cannot be destroyed by a verdict write; a raw
      # `set` reaches it without ever meeting `check_instruction_supersession/3`,
      # which would re-open the destruction door one field over from where it
      # was closed. Fenced exactly like `disposition` and `disposition_rerun`.
      merged[Stage.operating_instruction_key()] != was[Stage.operating_instruction_key()] ->
        {:error,
         {:invalid_task_content,
          instruction_bypass_error(merged[Stage.operating_instruction_key()])}}

      # The term is unchanged, but the trigger that makes a park honest is
      # being erased underneath it.
      now_term in Stage.trigger_required_dispositions() and
          trigger_erased?(was[Stage.reopen_trigger_key()], merged[Stage.reopen_trigger_key()]) ->
        {:error, {:invalid_task_content, trigger_erasure_error(now_term)}}

      true ->
        :ok
    end
  end

  defp ensure_disposition_via_verb(_type, _existing, _merged, _opts), do: :ok

  # ── ADOPTION-BY-REPARENT (PDS wave 28, the birth fence's second half) ──────
  #
  # A birth-scoped fence is STRUCTURALLY BLIND to adoption. A task filed outside
  # an epic carries no `parent_id`; giving it one later is an UPDATE with
  # `prev_doc` non-nil, so `Tasks.BirthGuards.born_adjudicated/6` — and every
  # other birth-scoped gate — never sees it. Without this guard the closure has
  # a side door: file bare, then reparent in, and the row is inside the epic's
  # denominator having never been adjudicated by anything.
  #
  # So: a `type:task` write that CHANGES `content.parent_id` must leave the row
  # carrying a disposition. It reads `merged` (the write's RESULT, not the
  # patch) for the same reason its siblings do — a patch that sets only
  # `parent_id` still has to be judged on what the row will BE.
  #
  # The vocabulary check is deliberate, not decorative: `disposition: "maybe"`
  # would otherwise satisfy a mere-presence test while meaning nothing, and the
  # raw door has no normaliser (`Tasks.Stage` is the one writer).
  #
  # THIS COMPOSES WITH `ensure_disposition_via_verb/4` INTO A DELIBERATE ORDER
  # OF OPERATIONS, and callers must know it: that guard refuses any raw CHANGE
  # of the term, so a bare row cannot be reparented and adjudicated in the same
  # mutate — the disposition has to be written FIRST, through the verb, and the
  # reparent comes after. That is the intended shape (adopt only rows that have
  # been judged), and the message says so rather than leaving the caller to
  # discover a two-guard interaction by trial.
  #
  # Replication is exempt first, same reason as every sibling: a mirror applies
  # verbatim or wedges the batch.
  @parent_key "parent_id"

  defp ensure_adoption_adjudicated("task", nil, _merged, _opts), do: :ok

  defp ensure_adoption_adjudicated("task", existing, merged, opts) do
    was = existing.content || %{}
    was_parent = was[@parent_key]
    now_parent = merged[@parent_key]

    cond do
      Keyword.get(opts, :source, :api) != :api -> :ok
      was_parent == now_parent -> :ok
      merged[Stage.disposition_key()] in Stage.dispositions() -> :ok
      true -> {:error, {:invalid_task_content, adoption_error(was_parent, now_parent)}}
    end
  end

  defp ensure_adoption_adjudicated(_type, _existing, _merged, _opts), do: :ok

  # ── THE ADJUDICATION OWNER (api half of
  # pds-bl-disposition-owner-role-registry) ──────────────────────────────────
  #
  # `content.disposition_owner` had NO schema declaration, NO validator and NO
  # code writer anywhere in `api/lib` or `internal/`, so a census over the
  # ledger could only assert "non-empty and slug-shaped" and green on sixteen
  # strings nobody had defined — the same shape of nothing the disposition
  # triple was before wave 24 fenced it. PR #17836 defines the vocabulary:
  # `tooling/pds/disposition-owner-registry.json` lists the `durable-role`
  # slugs that ARE owners, plus a `refused[]` census of what was measured in
  # the slot and why each one is not.
  #
  # THE LIST IS NOT RETYPED HERE, for the same reason the disposition
  # vocabulary is not: `Barkpark.Tasks.Stage` reads the registry at compile
  # time (`@external_resource`) and this door screens against
  # `Stage.owner_refusal_code/1` — the registry's OWN order, expiring-shape
  # before membership. Two spellings of one truth table with nothing that reds
  # when they diverge is the defect this row exists to remove;
  # `disposition_owner_registry_lock_test.exs` decodes the JSON and asserts
  # term identity in BOTH directions.
  #
  # IT FENCES THE WRITE, NOT THE ROW. `now == was` is not a change, so the
  # live rows already carrying a refused owner (the registry counted 8 `wave-N`
  # violations alone) keep reading and keep accepting patches to every other
  # field. A row-scoped rule would be RETROACTIVE — it would start refusing
  # unrelated bookkeeping on rows written before the registry existed, which is
  # precisely the placement the birth fence's own header measured and refuted.
  # Clearing the owner (`nil`) is always allowed: removing an unregistered
  # owner is the remediation, and a fence that forbade it would strand every
  # bad row.
  #
  # IT FENCES A BIRTH TOO, UNLIKE ITS SIBLINGS, and that asymmetry is
  # deliberate. The siblings head on `("task", nil, …), do: :ok` because a
  # CHANGE guard has nothing to compare a birth against. This is not a change
  # guard: it judges the VALUE BEING WRITTEN against a registry, and that
  # question is answerable at a birth. Letting a `createOrReplace` mint a row
  # with `disposition_owner: "wave-99"` would leave the fleet's own file-order
  # shape as the one open door (D53's lesson, re-derived).
  #
  # REPLICATION IS EXEMPT, CHECKED FIRST, same concrete reason as every
  # sibling: `Sync.Applier.apply_upsert` mirrors an upstream row verbatim, and
  # because `apply_mutations` wraps the batch in one transaction a refusal
  # would roll back the ENTIRE sync batch and wedge the replica with no
  # operator recourse. `:source` is server-set, so a request body can never
  # reach the `:sync` value.
  #
  # WHEN THE REGISTRY IS ABSENT THE DOOR FAILS CLOSED. `Stage` compiles an
  # EMPTY role list and warns; every owner write is then refused and the
  # message names the missing path. An absent registry must never read as
  # "every owner is legal" — that is the failure this whole row is about.

  defp ensure_disposition_owner_registered("task", existing, merged, opts) do
    was = (existing && existing.content) || %{}
    was_owner = was[Stage.disposition_owner_key()]
    now_owner = merged[Stage.disposition_owner_key()]

    cond do
      Keyword.get(opts, :source, :api) != :api ->
        :ok

      # Not a change — bookkeeping on a row that already carries this owner,
      # legal or not, passes untouched.
      now_owner == was_owner ->
        :ok

      # Clearing the owner is the remediation, never the offence.
      is_nil(now_owner) ->
        :ok

      true ->
        case Stage.owner_refusal_code(now_owner) do
          nil -> :ok
          code -> {:error, {:invalid_task_content, owner_registry_error(code, now_owner)}}
        end
    end
  end

  defp ensure_disposition_owner_registered(_type, _existing, _merged, _opts), do: :ok

  defp owner_registry_error(code, owner) do
    %{
      Stage.disposition_owner_key() => [
        "cannot be set to #{inspect(owner)}: " <>
          owner_refusal_why(code, owner) <>
          " The legal owners are the `durable-role` entries of " <>
          "`tooling/pds/disposition-owner-registry.json`" <>
          owner_registry_state() <>
          " Adding a role there is pds-owner-onboarding-owner's call; a row with no owner is " <>
          "honest, so clearing this key is always allowed."
      ]
    }
  end

  defp owner_refusal_why(:expiring_owner, _owner),
    do:
      "that is the EXPIRING `wave-N` shape, refused outright by the registry's ruling. A wave " <>
        "owner self-clears when the wave closes, and `disposition_owner` has no code writer " <>
        "repo-wide, so there is nothing to hang an auto-reassignment on — the row would " <>
        "silently become unowned at wave close. Name the durable role that outlives the wave."

  defp owner_refusal_why(:task_id_shape, _owner),
    do:
      "that is a ledger TASK ID in the owner slot. A task cannot own its own adjudication (or " <>
        "another task's): the slot names a standing accountability, not a row."

  defp owner_refusal_why(:not_a_string, _owner),
    do: "an owner is a lowercase-hyphen role slug, and that is not a string."

  defp owner_refusal_why(:unregistered, owner) do
    case Stage.refused_owner_entry(owner) do
      %{reason: reason} when is_binary(reason) ->
        "the registry lists it under `refused[]`: " <> reason

      _ ->
        "it is not a registered durable role."
    end
  end

  defp owner_registry_state do
    if Stage.owner_registry_loaded?() do
      " (#{length(Stage.durable_owner_roles())} today: " <>
        Enum.join(Stage.durable_owner_roles(), ", ") <> ")."
    else
      ", which was ABSENT when this build compiled (#{Stage.owner_registry_path()}) — so this " <>
        "door is failing CLOSED and refusing every owner. Land PR #17836 (or rebuild with the " <>
        "registry present) rather than reading this as a rejection of the slug."
    end
  end

  defp adoption_error(was_parent, now_parent) do
    %{
      @parent_key => [
        "cannot be changed from #{inspect(was_parent)} to #{inspect(now_parent)} on a task " <>
          "carrying no adjudication. Reparenting is ADOPTION: it moves the row into (or out " <>
          "of) a parent's closure, and a row that joins a closure unjudged is exactly the " <>
          "bare row a birth-time fence cannot see, because giving a task a parent later is an " <>
          "update, not a birth. Adjudicate it FIRST through the sanctioned verb (`bp task " <>
          "stage <id> <state> --disposition <open|parked|closed> --note <why>`, " <>
          "POST /v1/tasks/:id/stage) — the disposition cannot be written in this same " <>
          "mutate, because the raw door refuses any change of it — then reparent."
      ]
    }
  end

  # A trigger is "erased" when the row carried a real one and the write's result
  # carries none. A blank string is not a trigger — the verb normalises the same
  # way (`Tasks.Stage.normalize_note/1`), so the two doors agree on what
  # "present" means.
  defp trigger_erased?(was, now), do: present_trigger?(was) and not present_trigger?(now)

  defp present_trigger?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_trigger?(_), do: false

  # Same `invalid_task_content` family as the close and claim siblings (422
  # `validation_failed` with a per-field details map) — no new error code, no
  # new controller branch. Keyed on the field the caller actually wrote, and the
  # message is the retry instruction: it names the verb, the flags, and the fact
  # that the verb writes the triple atomically.
  defp disposition_bypass_error(was, now) do
    %{
      Stage.disposition_key() => [
        "cannot be set to #{inspect(now)} through /v1/data/mutate" <>
          if(is_binary(was), do: " (currently #{inspect(was)})", else: "") <>
          ". A disposition is an adjudication: written raw it carries no normalised term, no " <>
          "durable reason and — for a park — nothing that says what would ever reopen it, " <>
          "which is a row that claims to be decided and has decided nothing. A revision " <>
          "precondition does NOT unlock this. Write it through the sanctioned verb instead " <>
          "(`bp task stage <id> <state> --disposition <open|parked|closed> " <>
          "--note <why> --reopen-trigger <what would reconsider it>`, " <>
          "POST /v1/tasks/:id/stage), which normalises the term and writes term, reason and " <>
          "trigger in one atomic write — and refuses a park with no trigger."
      ]
    }
  end

  # Same `invalid_task_content` family, keyed on the field the caller wrote,
  # and the message is the retry instruction. It states the property the raw
  # door would destroy: the rerun is screened at the verb's write seam, so a
  # rerun written raw is one nobody has checked can fail.
  defp rerun_bypass_error(now) do
    %{
      Stage.disposition_rerun_key() => [
        "cannot be set to #{inspect(now)} through /v1/data/mutate. The rerun is the one " <>
          "thing that could prove a durable reason WRONG, and it is screened at the verb's " <>
          "write seam — a rerun that cannot fail (`git -C`, a `test` predicate, `$( … )` " <>
          "command substitution, `git merge-base --is-ancestor`, or a pipe-masked " <>
          "formatting tail like `| head -1`) is refused there. Written raw it bypasses that " <>
          "screen, which is a check nobody has checked. A revision precondition does NOT " <>
          "unlock this. Write it through the sanctioned verb instead " <>
          "(`bp task stage <id> <state> --rerun \"git cat-file -e origin/main:<path>\"`), " <>
          "POST /v1/tasks/:id/stage — and omitting the rerun is always allowed: a reason " <>
          "may honestly refuse to be checkable."
      ]
    }
  end

  defp instruction_bypass_error(now) do
    %{
      Stage.operating_instruction_key() => [
        "cannot be set to #{inspect(now)} through /v1/data/mutate. An operating instruction " <>
          "is STANDING GUIDANCE for whoever touches this row next, and it is durable " <>
          "precisely because the verb refuses to let one writer displace another's " <>
          "(`instruction_would_supersede`, overridable only per call with " <>
          "--supersede-instruction, which quotes the text you would destroy). A raw set " <>
          "reaches the key without meeting that guard, which puts the destruction back one " <>
          "field over from where it was closed. A revision precondition does NOT unlock " <>
          "this. Write it through the sanctioned verb instead " <>
          "(`bp task stage <id> <state> --instruction \"READ BEFORE STAMPING: …\"`), " <>
          "POST /v1/tasks/:id/stage."
      ]
    }
  end

  defp trigger_erasure_error(term) do
    %{
      Stage.reopen_trigger_key() => [
        "cannot be erased through /v1/data/mutate while this task is #{inspect(term)}. The " <>
          "reopen trigger is the only thing that makes a park a deferral rather than a silent " <>
          "drop: without it nothing states what would bring the row back. Re-adjudicate it " <>
          "through the sanctioned verb (`bp task stage <id> <state> --disposition open` to " <>
          "un-park, or `--reopen-trigger <new condition>` to replace the condition), " <>
          "POST /v1/tasks/:id/stage."
      ]
    }
  end

  # ── The create family's published-first fence (task-f0de48637a21d3dc) ──────
  #
  # THE DOOR. `patch` on a bare `type:task` id is published-first (`Content.Mutations`) and
  # LANDS through `land_patch/5`. The CREATE family is not: `create`,
  # `createOrReplace` and `createIfNotExists` resolve `existing` from
  # `DraftId.draft_id(id)` ALONE, and `Writer.create_document/4` always
  # draft-prefixes its write target. Name an id that already has a PUBLISHED
  # task row and the published row is invisible to the whole clause: `existing`
  # is nil, so `ensure_claim_not_dropped`, `ensure_task_close_is_cas`,
  # `ensure_disposition_via_verb` and `ensure_adoption_adjudicated` are all
  # structurally exempt (each has an explicit `nil` head), and the write lands a
  # `drafts.<id>` twin carrying `claim: null` / `lifecycle_status: "open"`
  # beside a published row that may be claimed and in progress. The receipt says
  # rc=0 and `results[0].id = "drafts.<id>"`; nothing says a fork happened.
  # Measured on guerrilla 2026-09-10: 354 of 8625 published task rows carry such
  # a twin, 218 of them disagreeing with their published row on
  # `lifecycle_status` and 244 on `claim` — and on every one of them
  # `bp doc patch <bare id>` is refused until somebody discards or publishes the
  # twin.
  #
  # THE RULING (lead-api-r7). Two outcomes, split on whether anybody is holding
  # the row RIGHT NOW:
  #
  #   * the published row carries a LIVE claim → REFUSE, in the same
  #     `{:invalid_task_content, %{field => [msg]}}` family (422
  #     `validation_failed`) the publish door and `ensure_claim_not_dropped`
  #     already use. This is the shape that destroys work: a lane holds a lease
  #     and the fork parks an unclaimed, `open` copy of its row where no reader
  #     looks.
  #   * no live claim → LAND AS TODAY and say so, through the same
  #     `Warnings.put/2` channel the patch door uses for
  #     `patch.forked_published`. Importers, seeders and migrations that
  #     re-write settled task rows by id keep working; they just stop being
  #     silent about which row they wrote.
  #
  # A birth on a FRESH id (no published row) is untouched — the whole fence is
  # behind a published-row lookup. `source: :sync` is exempt BEFORE the lookup,
  # exactly as `ensure_claim_not_dropped` exempts it: `Sync.Applier.apply_upsert`
  # mirrors upstream rows with `createOrReplace` + the full remote document, and
  # a refusal there rolls the whole replication batch back with no operator
  # recourse. `:source` is server-set (`MutateController` prepends `source:
  # :api`), so a request body can never reach the exempt value.
  #
  # "LIVE" IS NOT RE-DERIVED HERE. `Tasks.QueueGate.execution_class/2` is the
  # one place that answers "does anybody hold this row", and it is live in three
  # parts: a non-blank `claim.worker`, no close stamp, AND a lease that has not
  # lapsed (`claim_lease_live?/1`, measured against the same
  # `:task_lease_ttl_seconds` `TtlSweeper` reaps on). Called with a nil worker it
  # returns `"foreign_claimed"` exactly when that private `live_claim_worker/1`
  # is non-nil — and `"foreign_claimed"` is DERIVED-ONLY (`validate_state/1`
  # refuses to persist it), so the answer cannot be spoofed by a stored gate.
  defp ensure_create_not_forking_published_task(type, id, dataset, opts) do
    with true <- forkable_create_target?(type, id, opts),
         {:ok, published} <-
           Content.get_document(DraftId.published_id(id), type, dataset, opts) do
      if live_claim?(published) do
        {:error, {:invalid_task_content, create_fork_error(id, published)}}
      else
        warn_create_forked_published(id)
        :ok
      end
    else
      _ -> :ok
    end
  end

  defp forkable_create_target?(type, id, opts) do
    is_binary(id) and type in @published_first_types and not DraftId.draft?(id) and
      Keyword.get(opts, :source, :api) == :api
  end

  defp live_claim?(%{content: content}) when is_map(content),
    do: QueueGate.execution_class(content, nil) == "foreign_claimed"

  defp live_claim?(_published), do: false

  defp create_fork_error(id, published) do
    twin = DraftId.draft_id(id)
    claim = Map.get(published.content || %{}, "claim") || %{}
    worker = claim["worker"]
    epoch = claim["epoch"]

    held =
      if is_binary(worker) do
        " held by #{inspect(worker)}" <> if(is_integer(epoch), do: " at epoch #{epoch}", else: "")
      else
        ""
      end

    %{
      "_id" => [
        "refusing to fork the published task `#{id}`. A create-family write " <>
          "(`create` / `createOrReplace` / `createIfNotExists`, and " <>
          "`POST /api/documents/task`) ALWAYS writes `drafts.<id>`, so this one would mint " <>
          "the draft twin `#{twin}` beside a published row carrying a LIVE claim#{held}. " <>
          "No canonical reader serves that twin (`GET /v1/tasks/#{id}`, the board and the " <>
          "ready queue are all published-first), and because the twin is a brand-new row " <>
          "every task birth guard (claim preservation, close-CAS, disposition-by-verb, " <>
          "adoption) sees no existing row and is structurally exempt — so the write would " <>
          "strand a claim-less `open` copy of a claimed, in-progress row and report success. " <>
          "Sanctioned verbs: move the claim with `bp task release #{id} <worker> <epoch>` or " <>
          "`bp task close #{id} <worker> <epoch>` (or let the lease lapse) and resend; edit " <>
          "the published row with `bp doc patch task #{id}`, which is published-first and " <>
          "lands in one transaction; or address the twin deliberately by name, " <>
          "`\"_id\": \"#{twin}\"`."
      ]
    }
  end

  defp warn_create_forked_published(id) do
    Warnings.put(
      "create.forked_published",
      "this create-family mutation names the published task `#{id}` but writes a DRAFT twin " <>
        "(`drafts.#{id}`): the published row is untouched, and every canonical reader " <>
        "(/v1/data/doc, /v1/tasks/:id, the board, the queue) keeps serving it until the twin " <>
        "is published — `bp doc publish task #{id}` lands it, " <>
        "`bp doc discard-draft task #{id}` drops it. Allowed because the published row " <>
        "carries no live claim; the same write against a claimed row is refused.",
      "warning"
    )
  end
end
