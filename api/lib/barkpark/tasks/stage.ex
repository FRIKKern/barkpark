defmodule Barkpark.Tasks.Stage do
  @moduledoc """
  `bp task stage` — the sanctioned lifecycle-transition verb for the thought
  states (charter D8).

  Stage is the ONE user-facing path that moves a task between the staging
  targets — `considering`, `researching`, `open` — enforcing the shared
  `Barkpark.Tasks.Transitions` legality table and maintaining the engagement
  companion map (charter D3). Kills stay on `close` (`→ cancelled`), claims on
  `claim` (`→ in_progress`); `done` is reachable ONLY through `close`. Stage
  never mints or fences a live claim — thought is not contended work, so there
  is NO epoch machinery here (D3), unlike close/pulse/claim.

  ## What one stage does, in one Postgres transaction

    1. **Advisory lock** — `pg_advisory_xact_lock(hashtext("task:" <> task_id))`,
       where `task_id` is the document's UUID PRIMARY KEY, not its `doc_id`
       slug. That is the same per-task key the close/pulse/move/stamp family
       uses, so a stage serializes with any concurrent CAS write on the same row.

       THE KEY IS THE INVARIANT, and it is easy to break by reading this
       sentence rather than the code. Until this correction the line above said
       `hashtext('task:' || doc_id)`. Keying a stage on the SLUG while close and
       stamp key on the UUID hashes to a different lock, so the two would no
       longer exclude each other, the read-modify-write on
       `content.acceptance_criteria` would stop being serialized — and NO TEST
       WOULD RED, because the Ecto sandbox cannot express a two-connection race
       (see `test/barkpark/tasks/stamp_serialization_test.exs`). A wrong
       docstring on a lock, a key or an index is as urgent as wrong code:
       nothing downstream re-derives it, and the next person to touch this
       function will.
    2. **Legality gate** — read the current `lifecycle_status` (`from`); refuse
       with `{:error, {:illegal_transition, from, to}}` when `to` is neither a
       staging target nor the row's own current state, OR when
       `Transitions.legal?/2` says no. The controller renders that as a 422
       naming `from`, `to`, and the sanctioned verb.
    3. **Engagement map** (charter D3) — a `→ considering`/`→ researching`
       stage WRITES `content.engagement = %{object, holder, ts,
       lapse_ttl_seconds, lapses_at}` (`object ∈ {"research","build"}`, how a
       thought "carries its object"); a MOVEMENT to `→ open` CLEARS it (the
       thought resolved into ready backlog). A same-state ADJUDICATION
       (`from == to`, PDS wave 25/27) leaves it byte-identical — it moves
       nothing, so it resolves no thought.
    3b. **Durable reason** (PDS wave 23) — a `:note` does NOT ride the
       engagement map. It lands in `content.disposition_reason`, a key no
       sweeper owns. See "The durable/ephemeral split" below.
    3c. **The adjudication triple** (PDS wave 24) — `:disposition`,
       `:disposition_reason` and `:reopen_trigger` are written TOGETHER, in
       this one CAS update, or not at all. See "Hollowness is unwritable"
       below.
    4. **CAS-rev update** — `rev = <observed_rev>` guard, mirroring move/pulse;
       0 rows → `{:error, :stale_claim}`.
    5. **Additive event** — one `task.staged` mutation_event in the same
       transaction (`document.staged = %{from, to, object, holder, note}`), then
       a post-commit PubSub broadcast so live boards see the thought move.

  A same→same stage (`from == to`) is legal (the no-op clause in `Transitions`)
  and still writes — it lets a worker refresh the engagement object/holder on a
  task already in that state, mirroring how `relabel_by_id` always persists even
  on a no-op label set.

  ## Adjudication without resurrection (PDS wave 25)

  The same→same no-op is admitted on EVERY status, not just the staging targets
  — `done → done`, `blocked → blocked`, `in_progress → in_progress` included.
  That is the door through which a FINISHED row states its verdict.

  Stage is the only sanctioned writer of `content.disposition` (the raw
  `/v1/data/mutate` door refuses a disposition change on a `type:task` and names
  this verb), so while `@stageable` gated the target alone, a done row could be
  adjudicated only by first being reopened — trading an off-vocabulary lie for a
  LIFECYCLE lie (a row saying `open` while carrying `claim.closed_by`, back in
  `bp task ready`). It is now `to in @stageable or from == to`.

  This widens ADJUDICATION, never MOVEMENT: `from` is read from the row under
  the advisory lock, never from caller input, so `from == to` can only ever be
  satisfied by a row already in that state — `any → done` and `any → in_progress`
  stay refused exactly as before, and `do_stage` never touches `content.claim`,
  so a `done → done` adjudication leaves close attribution byte-identical.

  ## The durable/ephemeral split (PDS wave 23)

  `content.engagement` is an **ephemeral ownership lease**: `TtlSweeper`'s
  engagement sweep does `Map.delete("engagement")` once `engagement.ts` is
  older than `:task_engagement_ttl_seconds` (default 900 s, swept every
  minute). That is intentional design — an unowned thought row must not claim
  a holder forever.

  What was NOT intentional: a **durable adjudication reason** — "parked
  because X" — was piggy-backed onto that lease as `engagement.note`, so the
  verb returned `ok: true` on text with a 15-minute half-life and said
  nothing. Measured on guerrilla: a row staged at 20:02:00.455593 lapsed at
  20:17:01.430503 (15m00.97s); an epic-wide census found `engagement.note`
  surviving on 0 of 31 parked rows while `content.disposition_reason` survived
  12 of 12.

  So the two things are now split at the source:

    * `content.engagement` — LEASE ONLY: `object`, `holder`, `ts`, plus the
      honesty pair `lapse_ttl_seconds` / `lapses_at` so the stage receipt
      STATES when the lease dies instead of implying permanence. Deleted
      wholesale by the sweeper, by design.
    * `content.disposition_reason` — DURABLE: where a `:note` lands. No
      sweeper owns this key (`apply_lapse` deletes exactly one key, by name),
      so an adjudication written here survives the lapse it describes.

  A note is therefore never refused and never silently eaten: it is routed,
  and `task.staged` records the key it was routed to (`staged.note_key`).
  `TtlSweeper.apply_lapse` additionally PROMOTES a legacy `engagement.note`
  into `disposition_reason` on the way out, so rows written before this split
  keep their reason too.

  ## Hollowness is unwritable (PDS wave 24)

  Wave 23 gave a stage a durable place to put its REASON but no place to put
  the VOCABULARY TERM the reason is for. `content.disposition` was written
  exclusively by hand-patching (charter D298), so it had ZERO code writers
  repo-wide — and a field with no writer has, by construction, no normaliser
  and no requirement. The measured consequence: an epic-wide vocabulary
  reading `OPEN` 57 / `open` 47 / `parked` 27 / ABSENT 37, and parked rows
  carrying no statement of what would ever reopen them.

  A park that cannot say what would reopen it is a disposition that has
  decided nothing. So stage now owns the whole adjudication:

    * `content.disposition` — the TERM, from `#{inspect(~w(open parked closed))}`,
      normalised (trimmed + downcased, which is what closes the two-case
      split);
    * `content.disposition_reason` — the durable WHY (where `:note` already
      landed);
    * `content.reopen_trigger` — the durable WHEN-RECONSIDERED.

  All three are written in the SAME advisory-locked CAS update as the
  lifecycle transition, so there is no window in which a row is parked without
  its trigger. A `→ parked` stage that supplies no trigger — and whose row
  carries none already — is REFUSED with
  `{:error, {:missing_reopen_trigger, "parked"}}` before anything is written.
  A stage that supplies no disposition at all is untouched by any of this: the
  refusal fires on what THIS stage writes, never on what the row carries.

  The RAW door onto the same key is closed in
  `Barkpark.Content.Mutations` (`ensure_disposition_via_verb/4`), which refuses
  any `/v1/data/mutate` change of `disposition` on a `type:task` and names this
  verb as the retry instruction. The two doors are complementary and both are
  needed: a stage-side requirement cannot see a raw patch, and a raw-side guard
  would leave the only sanctioned writer unfenced.

  ## The reason carries its own falsifier (PDS wave 28)

  Waves 23–25 gave every adjudication a durable TERM, a durable WHY and a
  durable WHEN-RECONSIDERED. Nothing in that triple can be shown WRONG. A
  census can assert that 213 reasons are byte-distinct and nothing more — so a
  STALE, INVENTED or PARTIAL reason passes exactly as well as a re-derived one.

  A mechanical floor was tried first and REFUTED by measurement (PDS-D387):
  scraping shas and `path:line` out of prose reds 14 rows of which ONE is a real
  refutation (precision 0.07) and misses 2 of the 3 real defects (recall 0.33),
  and four independent extractors gave four different prose-only counts over the
  same 172 strings (64 / 69 / 76 / 118) — the class SIZE is not measurable by
  extraction. So the burden moves to the AUTHOR:

    * `content.disposition_rerun` — the DURABLE fourth key: one command an
      auditor can run to try to prove this reason WRONG.

  It is written in the same CAS update as the other three, by this same one
  writer, and the raw `/v1/data/mutate` door refuses it exactly as it refuses
  `disposition`.

  ### The field is OPTIONAL, and that is the point

  A reason is ALLOWED to refuse to be checkable — parked on a licence, a
  runtime-only probe, a judgment call. Saying so is a PASS: an absent rerun
  lands at L6 (truth-grip D3, demoted never rejected) and is NEVER refused. What
  is refused is a rerun that CANNOT FAIL, because a check that cannot fail is
  the vacuous green this epic exists to kill, one level up.

  ### The write-seam screen (PDS-D390)

  Refused BEFORE anything is written, so a refused rerun leaves the row
  byte-identical:

    * `git -C` in any spelling (also `--git-dir` / `--work-tree`) — it retargets
      the repository the check runs against, so the auditor and the author are
      not looking at the same thing;
    * a `test` / `[` filesystem predicate — it asserts about the CHECKOUT, which
      is per-machine state, not about `origin/main`;
    * `$( )` / backtick command substitution — the exit code becomes the OUTER
      command's, so the inner probe's failure is swallowed;
    * `git merge-base --is-ancestor` — refused by truth-grip's own screen, and
      PDS does not patch another epic's module to route around it;
    * a PIPE-MASKED tail: a pipeline whose LAST stage is a formatter
      (`head`, `tail`, `wc`, `cat`, `jq`, …). `git show origin/main:<gone> |
      head -1` exits **0** while the bare `git show` exits **128** — the
      formatter's success is reported as the check's.

  Every refusal NAMES a legal substitute — the `rev-list` / `cat-file` / `grep`
  forms spelled out in `legal_rerun_substitutes/0`, each of which reports the
  probe's OWN failure as a non-zero exit.

  ### Distinctness is NOT extended to this field (PDS-D391b / PDS-D336(a))

  Distinctness is a PROSE clause. A SHARED rerun over distinct reasons is the
  HONEST shape — one command can falsify a whole family of rows, exactly as a
  shared family `reopen_trigger` already does. D336(a) ruled this once for
  `reopen_trigger` and pinned it with the SHAREDTRIG fixture; a distinctness
  check here would repeat that mistake under a new field name.
  """

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
      fenced_content_write: 4,
      insert_mutation_event!: 5,
      caller_stamp: 1,
      task_broadcast: 4,
      emit_broadcasts: 1
    ]

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Transitions

  @event_task_staged "task.staged"

  # The lifecycle statuses `stage` may target. Kills (`cancelled`) go through
  # `close`, claims (`in_progress`) through `claim`, `done` only through `close`,
  # and `blocked` is an engine-driven state — none are user-stageable.
  @stageable ~w(considering researching open)

  # The states that CARRY an engagement object (thought). Reaching `open` (or
  # any other state) CLEARS it.
  @thought ~w(considering researching)

  # Valid engagement objects (charter D3): what a thought is ABOUT.
  @objects ~w(research build)

  # The DURABLE key a `:note` lands on — no sweeper owns it (PDS wave 23).
  # `TtlSweeper.apply_lapse/1` deletes exactly one key ("engagement"), by name.
  @durable_reason_key "disposition_reason"

  # The adjudication TERM and its reopen condition (PDS wave 24). Both durable,
  # both owned by this verb, both written in the same CAS update as the reason.
  @disposition_key "disposition"
  @reopen_trigger_key "reopen_trigger"

  # The FOURTH durable key (PDS wave 28): the command that could prove the
  # reason WRONG. Same writer, same CAS update, same raw-door refusal — and
  # OPTIONAL, because a reason is allowed to say it cannot be checked.
  @disposition_rerun_key "disposition_rerun"

  # What a refused rerun is told to write instead. Each of these reports the
  # PROBE's own failure as a non-zero exit, which is the whole property the
  # screen exists to preserve.
  @legal_rerun_substitutes [
    "git rev-list --count origin/main..<sha> | grep -qx 0",
    "git cat-file -e origin/main:<path>",
    "git grep -n <token> origin/main -- <path>"
  ]

  # The shapes a rerun may not take (PDS-D390), each with the reason it cannot
  # fail honestly. Matched in order; the FIRST match is what the refusal names,
  # so the most specific/most misleading shapes come first.
  @forbidden_rerun_shapes [
    {:repo_redirect, ~r/(?<![\w.-])git\s+(?:-C\b|--git-dir\b|--work-tree\b)/,
     "`git -C` (and `--git-dir` / `--work-tree`) retargets the repository the check runs " <>
       "against, so the auditor and the author are not looking at the same tree"},
    {:merge_base_ancestor, ~r/merge-base\b[^|;&]*--is-ancestor\b/,
     "`git merge-base --is-ancestor` is refused by truth-grip's own screen, and this epic " <>
       "does not route around another epic's module"},
    {:command_substitution, ~r/\$\(|`/,
     "command substitution (`$( … )` / backticks) reports the OUTER command's exit code, " <>
       "so the inner probe's failure is swallowed"},
    {:filesystem_predicate, ~r/(?:^|[|;&]\s*)(?:test|\[)\s/,
     "a `test` / `[` predicate asserts about the local CHECKOUT — per-machine state that " <>
       "says nothing about origin/main"}
  ]

  # The pipeline tails that report THEIR success as the check's. `git show
  # origin/main:<deleted> | head -1` exits 0; the bare `git show` exits 128.
  @rerun_formatting_tails ~w(head tail cat less more wc awk sed cut tr sort uniq
                             jq column tee xargs echo printf rev nl fold paste)

  # The three-class vocabulary, lowercase-canonical. Normalising here is what
  # closes the measured two-case split (OPEN 57 / open 47): the ONE writer is
  # the ONE normaliser.
  @dispositions ~w(open parked closed)

  # The terms that make no sense without a reopen condition. `closed` is
  # terminal by construction and `open` is not a deferral, so only a park owes
  # a trigger.
  @trigger_required ~w(parked)

  # Mirrors TtlSweeper's engagement lease default so the receipt can state the
  # half-life the sweeper will actually enforce.
  @default_engagement_ttl_seconds 900

  @doc "The mutation_events kind a stage emits."
  @spec event_kind() :: String.t()
  def event_kind, do: @event_task_staged

  @doc """
  The content key a staged `:note` is written to — the DURABLE adjudication
  reason, deliberately NOT the ephemeral engagement lease (PDS wave 23).
  """
  @spec durable_reason_key() :: String.t()
  def durable_reason_key, do: @durable_reason_key

  @doc """
  The content key the adjudication TERM is written to (PDS wave 24). Written
  by this verb only — `Barkpark.Content.Mutations` refuses a raw change of it
  on a `type:task`.
  """
  @spec disposition_key() :: String.t()
  def disposition_key, do: @disposition_key

  @doc """
  The content key the reopen condition is written to (PDS wave 24) — what
  would make a parked row worth reconsidering.
  """
  @spec reopen_trigger_key() :: String.t()
  def reopen_trigger_key, do: @reopen_trigger_key

  @doc """
  The content key the RERUN is written to (PDS wave 28) — one command an
  auditor can run to try to prove the durable reason wrong. Optional: an
  absent rerun is an honest "this cannot be checked", never a refusal.
  """
  @spec disposition_rerun_key() :: String.t()
  def disposition_rerun_key, do: @disposition_rerun_key

  @doc """
  The rerun shapes a refusal names as the legal substitute — each reports the
  probe's OWN failure as a non-zero exit.
  """
  @spec legal_rerun_substitutes() :: [String.t()]
  def legal_rerun_substitutes, do: @legal_rerun_substitutes

  @doc """
  The refused rerun shapes (PDS-D390) as `{code, why}` pairs, in match order.
  Exposed so a test can enumerate the screen instead of restating it.
  """
  @spec forbidden_rerun_shapes() :: [{atom(), String.t()}]
  def forbidden_rerun_shapes,
    do: Enum.map(@forbidden_rerun_shapes, fn {c, _re, why} -> {c, why} end)

  @doc """
  The lowercase-canonical adjudication vocabulary. A `:disposition` is trimmed
  and downcased into this set; anything else is `{:error, {:invalid_disposition,
  value}}`.
  """
  @spec dispositions() :: [String.t()]
  def dispositions, do: @dispositions

  @doc """
  The dispositions that REQUIRE a reopen trigger (supplied on the stage, or
  already carried by the row).
  """
  @spec trigger_required_dispositions() :: [String.t()]
  def trigger_required_dispositions, do: @trigger_required

  @doc """
  The engagement lease TTL, in seconds, as the sweeper will apply it
  (`:task_engagement_ttl_seconds`, default #{@default_engagement_ttl_seconds}).
  Stamped into the written lease so the stage receipt states its own half-life.
  """
  @spec engagement_ttl_seconds() :: non_neg_integer()
  def engagement_ttl_seconds do
    Application.get_env(
      :barkpark,
      :task_engagement_ttl_seconds,
      @default_engagement_ttl_seconds
    )
  end

  @doc "The lifecycle statuses `stage` may target."
  @spec stageable_targets() :: [String.t()]
  def stageable_targets, do: @stageable

  @doc """
  Stage the task identified by `task_id` (`documents.id` uuid — the controller
  resolves `doc_id` → row) into `to` (`considering` | `researching` | `open`).

  Opts:

    * `:object` — `"research"` | `"build"` (the thought's object). Defaults to
      `"research"`; only consumed on a `→ considering`/`→ researching` stage.
      Any other value → `{:error, {:invalid_object, object}}`.
    * `:holder` — the agent/worker owning the thought, stamped into
      `engagement.holder`. Optional.
    * `:note` — a free-text adjudication reason. Optional. Written to
      `content.#{@durable_reason_key}` — NOT to the engagement lease, which the
      TTL sweeper deletes wholesale (see "The durable/ephemeral split"). A
      blank/whitespace-only note is treated as absent and overwrites nothing;
      a real note is recorded on the row AND named in the `task.staged`
      payload as `staged.note_key`. Routed on EVERY stageable target,
      including `→ open`, where the reason for resolving the thought is
      exactly the thing worth keeping.
    * `:disposition_reason` — an explicit spelling of `:note`. Same key, same
      semantics; it exists so a caller adjudicating a row can name all three
      parts of the triple by the key each lands on. `:note` wins if both are
      given (it is the older, wired spelling).
    * `:disposition` — the adjudication TERM (PDS wave 24):
      `#{inspect(@dispositions)}`, trimmed and downcased. Absent → the row's
      existing term is left exactly as it was. Anything outside the vocabulary
      → `{:error, {:invalid_disposition, value}}`.
    * `:reopen_trigger` — what would make this row worth reconsidering.
      Durable, written to `content.#{@reopen_trigger_key}`. Blank is treated
      as absent. REQUIRED when `:disposition` is one of
      `#{inspect(@trigger_required)}` and the row does not already carry one.
    * `:rerun` (alias `:disposition_rerun`) — the command that could prove the
      reason WRONG (PDS wave 28). Durable, written to `content.#{@disposition_rerun_key}`.
      OPTIONAL and blank-is-absent: a reason may honestly refuse to be
      checkable. What is refused is a rerun that CANNOT FAIL — see
      `forbidden_rerun_shapes/0` — with `{:error, {:unfalsifiable_rerun, code,
      value}}` and NOTHING written.
    * `:caller_token_id` — audit stamp for the mutation_event.

  Returns `{:ok, doc}`, or:

    * `{:error, :not_found}` — no such task.
    * `{:error, {:illegal_transition, from, to}}` — `to` is neither a staging
      target nor the row's own current state (the in-place adjudication no-op),
      or `from → to` is refused by the legality table.
    * `{:error, {:invalid_object, object}}` — engagement object not in
      `#{inspect(@objects)}`.
    * `{:error, {:invalid_disposition, value}}` — term outside
      `#{inspect(@dispositions)}`.
    * `{:error, {:missing_reopen_trigger, disposition}}` — a park with no
      reopen condition, on the stage or on the row. NOTHING is written.
    * `{:error, {:unfalsifiable_rerun, code, value}}` — a rerun that cannot
      fail. NOTHING is written.
    * `{:error, :stale_claim}` — CAS lost (rare under the advisory lock).
  """
  @spec stage(binary(), String.t(), keyword()) ::
          {:ok, Document.t()}
          | {:error,
             :not_found
             | :stale_claim
             | {:illegal_transition, String.t(), String.t()}
             | {:invalid_object, term()}
             | {:invalid_disposition, term()}
             | {:missing_reopen_trigger, String.t()}
             | {:unfalsifiable_rerun, atom(), term()}}
  def stage(task_id, to, opts \\ []) when is_binary(task_id) and is_binary(to) do
    object = Keyword.get(opts, :object) || "research"
    holder = Keyword.get(opts, :holder)
    note = normalize_note(Keyword.get(opts, :note) || Keyword.get(opts, :disposition_reason))
    reopen_trigger = normalize_note(Keyword.get(opts, :reopen_trigger))
    rerun = normalize_note(Keyword.get(opts, :rerun) || Keyword.get(opts, :disposition_rerun))
    caller_token_id = Keyword.get(opts, :caller_token_id)

    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:" <> task_id])

        # global-read: by-PK re-read inside the stage-family advisory lock — same posture as pulse.ex/stamp.ex; caller authorization is enforced at the API seam.
        case Repo.get(Document, task_id) do
          nil ->
            {:error, :not_found}

          %Document{} = doc ->
            from = current_status(doc)

            # The adjudication is validated against the row we hold the lock on
            # (a trigger already ON the row satisfies a re-park), and every
            # refusal happens BEFORE the CAS update — a refused stage writes
            # nothing at all.
            with :ok <- check_stageable(from, to),
                 :ok <- check_object(to, object),
                 {:ok, disposition} <- check_disposition(Keyword.get(opts, :disposition)),
                 :ok <- check_reopen_trigger(doc, disposition, reopen_trigger),
                 :ok <- check_rerun(rerun) do
              adj = %{
                note: note,
                disposition: disposition,
                reopen_trigger: reopen_trigger,
                rerun: rerun
              }

              do_stage(doc, from, to, object, holder, adj, caller_token_id)
            end
        end
      end)

    case result do
      {:ok, {:ok, doc, broadcasts}} ->
        :ok = emit_broadcasts(broadcasts)
        {:ok, doc}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `to` must be a staging target OR a same-state no-op on the row we hold the
  # lock on, AND the transition must be legal. Both refusals collapse to one
  # `{:illegal_transition, from, to}` shape — the controller renders either as a
  # 422 naming from/to and the sanctioned verb (a caller asking to MOVE a task
  # to `cancelled`/`in_progress`/`done` is told which verb to use).
  #
  # THE `from == to` CLAUSE IS AN ADJUDICATION DOOR, NOT A MOVEMENT DOOR (PDS
  # wave 25 / D348). Before it, a finished row was UNWRITABLE: `stage` is the
  # only sanctioned writer of `content.disposition`, the raw `/v1/data/mutate`
  # door refuses a disposition change on a `type:task`, and `done` was not in
  # `@stageable` — so a done/blocked/in_progress row could be adjudicated only
  # by first being RESURRECTED (`→ open`), trading an off-vocabulary lie for a
  # lifecycle lie. This clause lets such a row carry its verdict in place.
  #
  # It cannot be used to reach a state: `from` is read from the locked row
  # (`current_status/1`), never from caller input, so `from == to` is satisfiable
  # only by a row ALREADY in that state — the `any → done` / `any → in_progress`
  # refusals are untouched. It cannot forge a claim either: `do_stage` writes
  # `lifecycle_status`, the engagement lease and the adjudication triple, and
  # never reads or writes `content.claim`, so close attribution survives a
  # `done → done` adjudication byte-for-byte. `Transitions.legal?/2` still gates
  # it, which is what keeps an unknown status string (not in `@statuses`) out.
  defp check_stageable(from, to) do
    if (to in @stageable or from == to) and Transitions.legal?(from, to) do
      :ok
    else
      {:error, {:illegal_transition, from, to}}
    end
  end

  # The engagement object is only consumed on a thought-target stage; guard it
  # only there so a `→ open` stage (which clears engagement) never rejects on a
  # leftover/absent object.
  defp check_object(to, object) when to in @thought do
    if object in @objects, do: :ok, else: {:error, {:invalid_object, object}}
  end

  defp check_object(_to, _object), do: :ok

  # The vocabulary normaliser (PDS wave 24). ONE writer, so ONE normaliser:
  # trim + downcase is what collapses the measured `OPEN`/`open` split at the
  # source instead of asking every reader to fold case.
  #
  # FAIL CLOSED, NEVER RAISE — chosen deliberately, not discovered. This module
  # is reachable from `/v1/tasks/:doc_id/stage` and, through the capability
  # manifest, from any surface that enumerates verbs. Raising on an unexpected
  # value would turn a caller's typo into a 500 (and, on the manifest/normalise
  # side, would take the whole `/v1/capabilities` response down for every
  # third-party plugin sharing that response). An error tuple the controller
  # already renders as a 422 costs the caller one retry and costs everyone else
  # nothing.
  defp check_disposition(nil), do: {:ok, nil}

  defp check_disposition(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> {:ok, nil}
      normalized when normalized in @dispositions -> {:ok, normalized}
      _ -> {:error, {:invalid_disposition, value}}
    end
  end

  defp check_disposition(value), do: {:error, {:invalid_disposition, value}}

  # A park owes a reopen condition. The trigger may arrive on THIS stage or
  # already sit on the row (a re-park of an already-triggered row is honest and
  # must not be busywork). Checked against the locked row, before the CAS.
  defp check_reopen_trigger(%Document{content: content}, disposition, trigger)
       when disposition in @trigger_required do
    carried = content |> content_map() |> Map.get(@reopen_trigger_key)

    if is_binary(trigger) or is_binary(normalize_note(carried)) do
      :ok
    else
      {:error, {:missing_reopen_trigger, disposition}}
    end
  end

  defp check_reopen_trigger(_doc, _disposition, _trigger), do: :ok

  # THE WRITE-SEAM SCREEN (PDS wave 28 / PDS-D390).
  #
  # ABSENCE IS A PASS, and that is load-bearing: a reason may honestly refuse
  # to be checkable and land at L6, demoted never rejected. The screen fires
  # ONLY on a rerun that was actually supplied — and only to refuse the shapes
  # that CANNOT FAIL. It does not, and cannot, judge whether a well-formed
  # rerun actually falsifies its reason; that is the author's burden, which is
  # exactly what PDS-D387 moved here after a mechanical floor measured
  # precision 0.07 / recall 0.33.
  #
  # NOTHING IS WRITTEN ON REFUSAL. Like every other check in the `with`, this
  # runs under the advisory lock and BEFORE the CAS update, so a refused stage
  # leaves the row byte-identical — the caller's retry is the whole remedy.
  #
  # NO DISTINCTNESS (PDS-D391b / PDS-D336(a)): a SHARED rerun over distinct
  # rows is the honest shape. There is deliberately no cross-row check here.
  defp check_rerun(nil), do: :ok

  defp check_rerun(rerun) when is_binary(rerun) do
    case Enum.find(@forbidden_rerun_shapes, fn {_code, re, _why} -> Regex.match?(re, rerun) end) do
      {code, _re, _why} -> {:error, {:unfalsifiable_rerun, code, rerun}}
      nil -> check_rerun_pipe_tail(rerun)
    end
  end

  # A pipeline reports its LAST stage's exit code. `git show origin/main:<gone>
  # | head -1` is therefore 0 where the bare `git show` is 128 — the formatter
  # launders a failure into a pass. A last stage that COMPARES (grep -q, diff,
  # cmp, …) is fine; a last stage that merely formats is not.
  defp check_rerun_pipe_tail(rerun) do
    if String.contains?(rerun, "|") and formatting_tail?(last_pipeline_stage(rerun)) do
      {:error, {:unfalsifiable_rerun, :pipe_masked, rerun}}
    else
      :ok
    end
  end

  defp last_pipeline_stage(rerun) do
    rerun
    |> String.split("|")
    |> List.last()
    |> String.trim()
  end

  defp formatting_tail?(stage) do
    case String.split(stage, ~r/\s+/, trim: true) do
      [command | _] -> Path.basename(command) in @rerun_formatting_tails
      [] -> false
    end
  end

  defp content_map(content) when is_map(content), do: content
  defp content_map(_), do: %{}

  defp do_stage(
         %Document{content: content} = doc,
         from,
         to,
         object,
         holder,
         adj,
         caller_token_id
       ) do
    observed_rev = doc.rev
    new_rev = generate_rev()
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    {new_content, engagement} = apply_engagement(content, from, to, object, holder, ts_iso)

    # THE NOTE THIS STAGE IS ABOUT TO SUPERSEDE. `apply_durable_reason` is a
    # plain `Map.put` — one disposition holds ONE reason, so a second annotator
    # replaces the first's text with no trace in the row. That is the intended
    # shape of the FIELD and the wrong shape for what callers do with it: notes
    # reading "do not execute this row as written" are written here and are
    # gone the moment anyone re-adjudicates. Reconstructing the lost text meant
    # replaying every task.staged event for the row and diffing — possible, and
    # nobody knew to do it. So the event now carries the OLD text beside the
    # new one: one event answers "what did I just overwrite", the receipt shows
    # the supersession instead of hiding it, and no read-before-write or client
    # upgrade is required to see it.
    superseded_note =
      case adj.note do
        nil -> nil
        _ -> Map.get(content || %{}, @durable_reason_key)
      end

    # The adjudication triple lands in this ONE map, which this ONE CAS update
    # persists — there is no window in which a row is parked without its
    # trigger, because there is no second write.
    new_content =
      new_content
      |> Map.put("lifecycle_status", to)
      |> apply_durable_reason(adj.note)
      |> apply_adjudication_key(@disposition_key, adj.disposition)
      |> apply_adjudication_key(@reopen_trigger_key, adj.reopen_trigger)
      |> apply_adjudication_key(@disposition_rerun_key, adj.rerun)

    # PDS-D451: the receipt is the STORED row, not a reconstruction of intent.
    case fenced_content_write(doc, observed_rev, new_content, new_rev) do
      {:ok, updated} ->
        ev =
          insert_mutation_event!(
            updated,
            @event_task_staged,
            observed_rev,
            "api",
            Map.merge(
              staged_payload(from, to, engagement, holder, adj, superseded_note),
              caller_stamp(caller_token_id)
            )
          )

        {:ok, updated, [task_broadcast(updated, @event_task_staged, ev, observed_rev)]}

      :stale ->
        {:error, :stale_claim}
    end
  end

  # `→ considering`/`→ researching` writes the engagement companion map; every
  # other MOVEMENT (i.e. `→ open`) CLEARS it; a same-state ADJUDICATION leaves
  # it alone (see the ruling below). Returns `{new_content, engagement_or_nil}`
  # so the event payload can echo what this stage WROTE.
  #
  # LEASE FIELDS ONLY (PDS wave 23). The map carries what the sweeper's lease
  # semantics need — object, holder, ts — plus the two honesty fields that make
  # the receipt state its own half-life: `lapse_ttl_seconds` and the derived
  # `lapses_at`. Nothing durable rides here; the sweeper deletes this whole map.
  defp apply_engagement(content, _from, to, object, holder, ts_iso) when to in @thought do
    ttl = engagement_ttl_seconds()

    engagement =
      %{
        "object" => object,
        "ts" => ts_iso,
        "lapse_ttl_seconds" => ttl,
        "lapses_at" => lapses_at(ts_iso, ttl)
      }
      |> maybe_put("holder", holder)

    {Map.put(content, "engagement", engagement), engagement}
  end

  # THE ADJUDICATION DOOR DOES NOT CLEAR THE LEASE (PDS wave 27).
  #
  # The lead's ruling, verbatim: "a same-state stage (from == to) that clears a
  # live engagement lease is a DEFECT. `apply_engagement/5`'s catch-all clause
  # in api/lib/barkpark/tasks/stage.ex [line reference elided] returns
  # `{Map.delete(content, \"engagement\"), nil}` for every non-thought target.
  # When from == to the row is being ADJUDICATED, not MOVED, so the engagement
  # map must survive byte-identical. Movement (from != to, to not in @thought)
  # still clears it, as documented. A thought→same-thought stage
  # (considering→considering) keeps its current re-lease behaviour."
  #
  # That last sentence is why this clause sits BELOW the `to in @thought` one:
  # a considering→considering stage matches the thought clause first and
  # re-leases exactly as it did before.
  #
  # The returned `nil` is not "the lease is gone" — it is "this stage wrote no
  # lease". `staged_payload/6` echoes what this stage WROTE, and an
  # adjudication writes nothing to `content.engagement`, so the event payload
  # for a same-state stage is byte-identical to what it was before this fix.
  defp apply_engagement(content, from, to, _object, _holder, _ts_iso) when from == to do
    {content, nil}
  end

  defp apply_engagement(content, _from, _to, _object, _holder, _ts_iso) do
    {Map.delete(content, "engagement"), nil}
  end

  # The note's DURABLE home. Absent note → the row's existing reason is left
  # exactly as it was (a stage that says nothing must not erase an earlier
  # adjudication).
  defp apply_durable_reason(content, nil), do: content
  defp apply_durable_reason(content, note), do: Map.put(content, @durable_reason_key, note)

  # Same "absent means leave it alone" rule as the reason: a stage that says
  # nothing about the term or the trigger must not erase an earlier
  # adjudication.
  defp apply_adjudication_key(content, _key, nil), do: content
  defp apply_adjudication_key(content, key, value), do: Map.put(content, key, value)

  # When the written lease dies, as an ISO-8601 instant. Derived from the same
  # `ts` the sweeper compares against, so this is a statement about the actual
  # enforcement, not a guess.
  defp lapses_at(ts_iso, ttl) when is_integer(ttl) and ttl >= 0 do
    case DateTime.from_iso8601(ts_iso) do
      {:ok, dt, _offset} -> dt |> DateTime.add(ttl, :second) |> DateTime.to_iso8601()
      _ -> nil
    end
  end

  defp lapses_at(_ts_iso, _ttl), do: nil

  # A blank note is no note: it must not overwrite a durable reason with "".
  defp normalize_note(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      _ -> note
    end
  end

  defp normalize_note(_), do: nil

  # Additive task.staged payload (charter D8): from, to, the engagement fields
  # (object/holder) when the target carries a thought — nil on a `→ open` stage
  # that cleared engagement — and the note WITH the key it was routed to
  # (`note_key`), so the event says where the durable text actually landed
  # instead of implying it rode the lease (PDS wave 23). `lapses_at` echoes the
  # written lease's death so a consumer of the event knows it too.
  # The adjudication triple is echoed the same way the note is — the VALUE plus
  # the KEY it landed on — so a consumer of the event can tell an adjudication
  # that was written from one that was merely passed.
  defp staged_payload(from, to, engagement, holder, adj, superseded_note) do
    %{
      "staged" => %{
        "superseded_note" => superseded_note,
        "from" => from,
        "to" => to,
        "object" => engagement && Map.get(engagement, "object"),
        "holder" => holder,
        "note" => adj.note,
        "note_key" => adj.note && @durable_reason_key,
        "disposition" => adj.disposition,
        "disposition_key" => adj.disposition && @disposition_key,
        "reopen_trigger" => adj.reopen_trigger,
        "reopen_trigger_key" => adj.reopen_trigger && @reopen_trigger_key,
        "disposition_rerun" => adj.rerun,
        "disposition_rerun_key" => adj.rerun && @disposition_rerun_key,
        "lapses_at" => engagement && Map.get(engagement, "lapses_at")
      }
    }
  end

  defp current_status(%Document{content: content}) when is_map(content),
    do: Map.get(content, "lifecycle_status")

  defp current_status(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
