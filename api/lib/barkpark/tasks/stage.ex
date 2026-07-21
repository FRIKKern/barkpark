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
       stage WRITES `content.engagement = %{object, holder, ts, note?}`
       (`object ∈ {"research","build"}`, how a thought "carries its object");
       a `→ open` stage CLEARS it (the thought resolved into ready backlog).
    4. **CAS-rev update** — `rev = <observed_rev>` guard, mirroring move/pulse;
       0 rows → `{:error, :stale_claim}`.
    5. **Additive event** — one `task.staged` mutation_event in the same
       transaction (`document.staged = %{from, to, object, holder, note}`), then
       a post-commit PubSub broadcast so live boards see the thought move.

  A same→same stage (`from == to`, both a staging target) is legal (the no-op
  clause in `Transitions`) and still writes — it lets a worker refresh the
  engagement object/note on a task already in that state, mirroring how
  `relabel_by_id` always persists even on a no-op label set.
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

  @doc "The mutation_events kind a stage emits."
  @spec event_kind() :: String.t()
  def event_kind, do: @event_task_staged

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
    * `:note` — a free-text note, stamped into `engagement.note`. Optional.
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
    note = Keyword.get(opts, :note)
    caller_token_id = Keyword.get(opts, :caller_token_id)

    result =
      Repo.transaction(fn ->
        _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["task:" <> task_id])

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

    {new_content, engagement} = apply_engagement(content, to, object, holder, note, ts_iso)
    new_content = Map.put(new_content, "lifecycle_status", to)

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
  defp apply_engagement(content, to, object, holder, note, ts_iso) when to in @thought do
    engagement =
      %{"object" => object, "ts" => ts_iso}
      |> maybe_put("holder", holder)
      |> maybe_put("note", note)

    {Map.put(content, "engagement", engagement), engagement}
  end

  defp apply_engagement(content, _to, _object, _holder, _note, _ts_iso) do
    {Map.delete(content, "engagement"), nil}
  end

  # Additive task.staged payload (charter D8): from, to, and the engagement
  # fields (object/holder/note) when the target carries a thought — nil on a
  # `→ open` stage that cleared engagement.
  defp staged_payload(from, to, engagement, holder, note) do
    %{
      "staged" => %{
        "from" => from,
        "to" => to,
        "object" => engagement && Map.get(engagement, "object"),
        "holder" => holder,
        "note" => note
      }
    }
  end

  defp current_status(%Document{content: content}) when is_map(content),
    do: Map.get(content, "lifecycle_status")

  defp current_status(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
