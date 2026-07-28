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

    1. **Advisory lock** — `pg_advisory_xact_lock(hashtext('task:' || doc_id))`,
       the same per-task key the close/pulse/move family uses, so a stage
       serializes with any concurrent CAS write on the same row.
    2. **Legality gate** — read the current `lifecycle_status` (`from`); refuse
       with `{:error, {:illegal_transition, from, to}}` when `to` is not a
       staging target OR `Transitions.legal?/2` says no. The controller renders
       that as a 422 naming `from`, `to`, and the sanctioned verb.
    3. **Engagement map** (charter D3) — a `→ considering`/`→ researching`
       stage WRITES `content.engagement = %{object, holder, ts,
       lapse_ttl_seconds, lapses_at}` (`object ∈ {"research","build"}`, how a
       thought "carries its object"); a `→ open` stage CLEARS it (the thought
       resolved into ready backlog).
    3b. **Durable reason** (PDS wave 23) — a `:note` does NOT ride the
       engagement map. It lands in `content.disposition_reason`, a key no
       sweeper owns. See "The durable/ephemeral split" below.
    4. **CAS-rev update** — `rev = <observed_rev>` guard, mirroring move/pulse;
       0 rows → `{:error, :stale_claim}`.
    5. **Additive event** — one `task.staged` mutation_event in the same
       transaction (`document.staged = %{from, to, object, holder, note}`), then
       a post-commit PubSub broadcast so live boards see the thought move.

  A same→same stage (`from == to`, both a staging target) is legal (the no-op
  clause in `Transitions`) and still writes — it lets a worker refresh the
  engagement object/holder on a task already in that state, mirroring how
  `relabel_by_id` always persists even on a no-op label set.

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
  """

  import Ecto.Query, only: [from: 2]

  import Barkpark.Tasks.Internal,
    only: [
      generate_rev: 0,
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
    * `:caller_token_id` — audit stamp for the mutation_event.

  Returns `{:ok, doc}`, or:

    * `{:error, :not_found}` — no such task.
    * `{:error, {:illegal_transition, from, to}}` — `to` is not a staging
      target, or `from → to` is refused by the legality table.
    * `{:error, {:invalid_object, object}}` — engagement object not in
      `#{inspect(@objects)}`.
    * `{:error, :stale_claim}` — CAS lost (rare under the advisory lock).
  """
  @spec stage(binary(), String.t(), keyword()) ::
          {:ok, Document.t()}
          | {:error,
             :not_found
             | :stale_claim
             | {:illegal_transition, String.t(), String.t()}
             | {:invalid_object, term()}}
  def stage(task_id, to, opts \\ []) when is_binary(task_id) and is_binary(to) do
    object = Keyword.get(opts, :object) || "research"
    holder = Keyword.get(opts, :holder)
    note = normalize_note(Keyword.get(opts, :note))
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

            with :ok <- check_stageable(from, to),
                 :ok <- check_object(to, object) do
              do_stage(doc, from, to, object, holder, note, caller_token_id)
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

  # `to` must be a staging target AND the transition must be legal. Both refusals
  # collapse to one `{:illegal_transition, from, to}` shape — the controller
  # renders either as a 422 naming from/to and the sanctioned verb (a caller
  # asking to stage to `cancelled`/`in_progress`/`done` is told which verb to
  # use). Legal same→same no-ops pass (Transitions.legal?/2).
  defp check_stageable(from, to) do
    if to in @stageable and Transitions.legal?(from, to) do
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

  defp do_stage(
         %Document{content: content} = doc,
         from,
         to,
         object,
         holder,
         note,
         caller_token_id
       ) do
    observed_rev = doc.rev
    new_rev = generate_rev()
    ts_iso = DateTime.utc_now() |> DateTime.to_iso8601()

    {new_content, engagement} = apply_engagement(content, to, object, holder, ts_iso)

    new_content =
      new_content
      |> Map.put("lifecycle_status", to)
      |> apply_durable_reason(note)

    {rows, _} =
      from(d in Document, where: d.id == ^doc.id and d.rev == ^observed_rev)
      |> Repo.update_all(
        set: [content: new_content, rev: new_rev, updated_at: DateTime.utc_now()]
      )

    case rows do
      1 ->
        updated = %Document{doc | content: new_content, rev: new_rev}

        ev =
          insert_mutation_event!(
            updated,
            @event_task_staged,
            observed_rev,
            "api",
            Map.merge(
              staged_payload(from, to, engagement, holder, note),
              caller_stamp(caller_token_id)
            )
          )

        {:ok, updated, [task_broadcast(updated, @event_task_staged, ev, observed_rev)]}

      0 ->
        {:error, :stale_claim}
    end
  end

  # `→ considering`/`→ researching` writes the engagement companion map;
  # everything else (i.e. `→ open`) CLEARS it. Returns `{new_content,
  # engagement_or_nil}` so the event payload can echo what was written.
  #
  # LEASE FIELDS ONLY (PDS wave 23). The map carries what the sweeper's lease
  # semantics need — object, holder, ts — plus the two honesty fields that make
  # the receipt state its own half-life: `lapse_ttl_seconds` and the derived
  # `lapses_at`. Nothing durable rides here; the sweeper deletes this whole map.
  defp apply_engagement(content, to, object, holder, ts_iso) when to in @thought do
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

  defp apply_engagement(content, _to, _object, _holder, _ts_iso) do
    {Map.delete(content, "engagement"), nil}
  end

  # The note's DURABLE home. Absent note → the row's existing reason is left
  # exactly as it was (a stage that says nothing must not erase an earlier
  # adjudication).
  defp apply_durable_reason(content, nil), do: content
  defp apply_durable_reason(content, note), do: Map.put(content, @durable_reason_key, note)

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
  defp staged_payload(from, to, engagement, holder, note) do
    %{
      "staged" => %{
        "from" => from,
        "to" => to,
        "object" => engagement && Map.get(engagement, "object"),
        "holder" => holder,
        "note" => note,
        "note_key" => note && @durable_reason_key,
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
