defmodule Barkpark.Plugins.Bulldocs.Events do
  @moduledoc """
  Context over the append-only `paper_events` store — the data spine for the
  native goal-path rail (P6.U2). Pure Ecto over `Barkpark.Repo`; never shells
  out to an external task process (decoupled from W7).
  """

  import Ecto.Query
  import Barkpark.Content.Scope, only: [scope_to_workspace_or_global: 3]
  alias Barkpark.Repo
  alias Barkpark.Plugins.Bulldocs.Event

  @doc """
  Append a lifecycle event. Validates via `Event.changeset/2`
  (`event_type` required + at least one of `goal_id` / `paper_slug`).
  Returns `{:ok, %Event{}}` or `{:error, changeset}`.

  W1.5-C: a paper_event FOLLOWS its goal — `workspace_id` / `project_id` in
  `attrs` set the event's scope. The caller (upsert_paper, BulldocsLive) stamps
  these from the resolved paper/goal scope (Default fallback when the caller
  provides none) so a goal's events share the goal's workspace/project.
  """
  def create_event(attrs) when is_map(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  @decision_ttl_seconds 24 * 60 * 60

  @doc """
  How long a `simplify-request` stays decidable, in seconds.
  """
  @spec decision_ttl_seconds() :: pos_integer()
  def decision_ttl_seconds, do: @decision_ttl_seconds

  @doc """
  Record a DECISION (`simplify-accept` / `simplify-reject`) against the
  `simplify-request` that originated it — the requester<->accepter identity
  tie (task-cefcbf5b3a9b1665).

  `create_event/1` is append-only and asks nothing. This is the trusted path:
  it refuses unless EVERY tie holds, and only it may stamp
  `authorization: "authorized"`.

  `attrs` must carry `"event_type"`, `"request_event_id"`, `"actor_kind"`,
  `"actor_id"` and the caller's resolved `"workspace_id"` / `"project_id"`
  scope. Returns `{:ok, %Event{}}`, or `{:error, reason}` where reason is one
  of:

    * `:anonymous` — no authenticated actor behind the decision.
    * `:unknown_request` — no such request row (including a non-UUID id).
    * `:not_a_request` — the referenced row is not a `simplify-request`.
    * `:wrong_paper` — the request belongs to a different paper.
    * `:cross_scope` — the request lives in a different workspace/project.
    * `:foreign_actor` — the accepter is not the requester.
    * `:expired_request` — the request is older than `decision_ttl_seconds/0`.
    * `:already_decided` — an authorized decision already exists for it
      (replay of a captured click cannot transfer authority).

  NOTHING is written on any of those — the refusal path inserts no row, so a
  failed decision mutates no content and no history.
  """
  @spec record_decision(map()) ::
          {:ok, %Event{}} | {:error, atom()} | {:error, Ecto.Changeset.t()}
  def record_decision(attrs) when is_map(attrs) do
    with :ok <- check_decision_type(attrs),
         {:ok, actor} <- check_actor(attrs),
         {:ok, request} <- fetch_request(attrs),
         :ok <- check_same_paper(request, attrs),
         :ok <- check_same_scope(request, attrs),
         :ok <- check_same_actor(request, actor),
         :ok <- check_fresh(request),
         :ok <- check_undecided(request) do
      attrs
      |> Map.put("branch", request.branch)
      |> Map.put("goal_id", request.goal_id)
      |> Map.put("request_event_id", request.id)
      |> Map.put("authorization", "authorized")
      |> create_event()
    end
  end

  @doc """
  Whether an event may be treated as an APPROVAL by a downstream consumer.

  True only for a decision row the server itself tied to its request
  (`authorization == "authorized"`). A legacy row (NULL), a row written
  straight through `create_event/1` (`"unverified"`), and every non-decision
  event are all false.
  """
  @spec authoritative_decision?(any()) :: boolean()
  def authoritative_decision?(%Event{event_type: type, authorization: "authorized"}),
    do: type in Event.decision_event_types()

  def authoritative_decision?(_), do: false

  @doc """
  The audit read: who decided which request, for one paper.

  Returns one map per DECISION row, newest first — the decision's own id and
  type, the `request_event_id` it decided, the request's branch, the actor on
  both sides, and whether the server tied them (`authoritative?`). A legacy or
  `"unverified"` decision is listed too, with `authoritative?: false` and a
  `requested_by` of `nil` when it names no request: the audit surface must
  show the untrustworthy rows, not hide them.

  `opts` takes the same `:workspace_id` / `:project_id` scope every other
  read here does.
  """
  @spec decision_audit(String.t(), keyword()) :: [map()]
  def decision_audit(paper_slug, opts \\ []) when is_binary(paper_slug) do
    decision_types = Event.decision_event_types()

    decisions =
      Event
      |> where([e], e.paper_slug == ^paper_slug)
      |> where([e], e.event_type in ^decision_types)
      |> scope_opts(opts)
      |> order_by([e], desc: e.inserted_at)
      |> Repo.all()

    request_ids = decisions |> Enum.map(& &1.request_event_id) |> Enum.reject(&is_nil/1)

    requests =
      Event
      |> where([e], e.id in ^request_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(decisions, fn decision ->
      request = Map.get(requests, decision.request_event_id)

      %{
        decision_id: decision.id,
        decision: decision.event_type,
        decided_at: decision.inserted_at,
        request_event_id: decision.request_event_id,
        branch: (request && request.branch) || decision.branch,
        requested_by: request && {request.actor_kind, request.actor_id},
        decided_by: {decision.actor_kind, decision.actor_id},
        authorization: decision.authorization,
        authoritative?: authoritative_decision?(decision)
      }
    end)
  end

  defp check_decision_type(attrs) do
    if fetch(attrs, "event_type") in Event.decision_event_types() do
      :ok
    else
      {:error, :not_a_decision}
    end
  end

  defp check_actor(attrs) do
    kind = fetch(attrs, "actor_kind")
    id = fetch(attrs, "actor_id")

    if is_binary(kind) and kind != "" and is_binary(id) and id != "" do
      {:ok, {kind, id}}
    else
      {:error, :anonymous}
    end
  end

  defp fetch_request(attrs) do
    case get_event(to_string(fetch(attrs, "request_event_id") || "")) do
      nil -> {:error, :unknown_request}
      %Event{event_type: "simplify-request"} = request -> {:ok, request}
      %Event{} -> {:error, :not_a_request}
    end
  end

  defp check_same_paper(%Event{paper_slug: slug}, attrs) do
    if slug == fetch(attrs, "paper_slug"), do: :ok, else: {:error, :wrong_paper}
  end

  defp check_same_scope(%Event{} = request, attrs) do
    if request.workspace_id == fetch(attrs, "workspace_id") and
         request.project_id == fetch(attrs, "project_id") do
      :ok
    else
      {:error, :cross_scope}
    end
  end

  defp check_same_actor(%Event{actor_kind: kind, actor_id: id}, {kind, id})
       when is_binary(kind) and is_binary(id),
       do: :ok

  defp check_same_actor(%Event{}, _actor), do: {:error, :foreign_actor}

  defp check_fresh(%Event{inserted_at: inserted_at}) do
    if DateTime.diff(DateTime.utc_now(), inserted_at) <= @decision_ttl_seconds do
      :ok
    else
      {:error, :expired_request}
    end
  end

  defp check_undecided(%Event{id: id}) do
    decided? =
      Event
      |> where([e], e.request_event_id == ^id)
      |> where([e], e.authorization == "authorized")
      |> Repo.exists?()

    if decided?, do: {:error, :already_decided}, else: :ok
  end

  # `record_decision/1` is called with the same STRING-keyed attr map every
  # other `create_event/1` caller builds; this is a plain read of that shape.
  defp fetch(attrs, key), do: Map.get(attrs, key)

  @doc """
  All events for a goal, oldest first (rail walks the lineage forward).

  W1.5-C: `opts` may carry `:workspace_id` / `:project_id` to scope the read
  to a single workspace/project. `nil` workspace_id (the default) returns the
  query unscoped — pre-tenancy back-compat for callers that thread no scope.
  """
  def list_for_goal(goal_id, opts \\ []) when is_binary(goal_id) do
    Event
    |> where([e], e.goal_id == ^goal_id)
    |> scope_opts(opts)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  @doc """
  All events for a paper (by slug), oldest first.

  W1.5-C: `opts` may carry `:workspace_id` / `:project_id` (nil = unscoped).
  """
  def list_for_paper(paper_slug, opts \\ []) when is_binary(paper_slug) do
    Event
    |> where([e], e.paper_slug == ^paper_slug)
    |> scope_opts(opts)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  @doc """
  Fetch a single event by id. Returns `nil` when absent — including ids that
  aren't a valid UUID (the public paper reader's `open-diff` handler pushes
  client-controlled `from`/`to` ids straight in, and Ecto would otherwise raise
  `Ecto.Query.CastError` trying to bind them to the `:binary_id` primary key).
  """
  def get_event(id) when is_binary(id) do
    case Repo.uuid_or_nil(id) do
      nil -> nil
      uuid -> Repo.get(Event, uuid)
    end
  end

  @doc """
  Pending actionable intents for the loop-closer (P6.U6a, barkpark-jwai).

  An *intent* is an event the paper-side reader loop (U6b) must act on —
  the `action:*` clicks (`action:build`, `action:grill`, …) and the
  `simplify-*` requests (`simplify-request`, …) that U4/U5 record. Lifecycle
  events (`goal-opened`, `plan-written`, `phase-advanced`, …) are NOT intents
  and are excluded.

  Returns rows where `event_type LIKE 'action:%' OR LIKE 'simplify-%'` AND
  `processed_at IS NULL`, oldest first (the loop drains them in order).

  W1.5-C: `opts` may carry `:workspace_id` / `:project_id` to drain only one
  workspace's intents (nil = unscoped, all workspaces — pre-tenancy default).
  """
  def list_pending_intents(opts \\ []) do
    decision_types = Event.decision_event_types()

    Event
    |> where([e], is_nil(e.processed_at))
    |> where([e], like(e.event_type, "action:%") or like(e.event_type, "simplify-%"))
    # task-cefcbf5b3a9b1665 — THE CONSUMER GATE. This drain is the first
    # reader that treats a `simplify-accept` as authoritative, so a decision
    # row only reaches it once the server tied it to its own request
    # (`record_decision/1`). An `"unverified"` or legacy-NULL decision stays
    # in the store and never reaches an automation. Non-decision intents
    # (`action:*`, `simplify-request`) are untouched.
    |> where([e], e.event_type not in ^decision_types or e.authorization == "authorized")
    |> scope_opts(opts)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  @doc """
  Mark an intent processed — stamps `processed_at` with the current UTC time so
  the row drops out of `list_pending_intents/0`. Idempotent re-stamp on an
  already-processed row.

  Returns `{:ok, %Event{}}` on success, `{:error, :not_found}` when no event
  has the given id (including ids that aren't a valid UUID — paper-intents
  ships opaque `evt_…` strings on bad input, and Ecto would otherwise raise
  `Ecto.Query.CastError` trying to bind them to the `:binary_id` primary key).
  """
  def mark_processed(id) when is_binary(id) do
    case Repo.uuid_or_nil(id) do
      nil ->
        {:error, :not_found}

      uuid ->
        case Repo.get(Event, uuid) do
          nil ->
            {:error, :not_found}

          %Event{} = event ->
            event
            |> Ecto.Changeset.change(processed_at: DateTime.utc_now())
            |> Repo.update()
        end
    end
  end

  # Pull `:workspace_id` / `:project_id` from opts and pipe through the shared
  # Content.Scope filter. nil workspace_id leaves the query untouched (unscoped
  # / back-compat) — the same contract every scoped content read uses.
  defp scope_opts(query, opts) do
    scope_to_workspace_or_global(
      query,
      Keyword.get(opts, :workspace_id),
      Keyword.get(opts, :project_id)
    )
  end
end
