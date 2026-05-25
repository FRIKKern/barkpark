defmodule Barkpark.Papers.Events do
  @moduledoc """
  Context over the append-only `paper_events` store — the data spine for the
  native goal-path rail (P6.U2). Pure Ecto over `Barkpark.Repo`; never shells
  out to Beads/`bd` (decoupled from W7).
  """

  import Ecto.Query
  import Barkpark.Content.Scope, only: [scope_to_workspace: 3]
  alias Barkpark.Repo
  alias Barkpark.Papers.Event

  @doc """
  Append a lifecycle event. Validates via `Event.changeset/2`
  (`event_type` required + at least one of `goal_id` / `paper_slug`).
  Returns `{:ok, %Event{}}` or `{:error, changeset}`.

  W1.5-C: a paper_event FOLLOWS its goal — `workspace_id` / `project_id` in
  `attrs` set the event's scope. The caller (upsert_paper, PaperLive) stamps
  these from the resolved paper/goal scope (Default fallback when the caller
  provides none) so a goal's events share the goal's workspace/project.
  """
  def create_event(attrs) when is_map(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

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
  Fetch a single event by id. Returns `nil` when absent.
  """
  def get_event(id) when is_binary(id) do
    Repo.get(Event, id)
  end

  @doc """
  Pending actionable intents for the loop-closer (P6.U6a, barkpark-jwai).

  An *intent* is an event the paperflow-side reader loop (U6b) must act on —
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
    Event
    |> where([e], is_nil(e.processed_at))
    |> where([e], like(e.event_type, "action:%") or like(e.event_type, "simplify-%"))
    |> scope_opts(opts)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  @doc """
  Mark an intent processed — stamps `processed_at` with the current UTC time so
  the row drops out of `list_pending_intents/0`. Idempotent re-stamp on an
  already-processed row.

  Returns `{:ok, %Event{}}` on success, `{:error, :not_found}` when no event
  has the given id.
  """
  def mark_processed(id) when is_binary(id) do
    case Repo.get(Event, id) do
      nil ->
        {:error, :not_found}

      %Event{} = event ->
        event
        |> Ecto.Changeset.change(processed_at: DateTime.utc_now())
        |> Repo.update()
    end
  end

  # Pull `:workspace_id` / `:project_id` from opts and pipe through the shared
  # Content.Scope filter. nil workspace_id leaves the query untouched (unscoped
  # / back-compat) — the same contract every scoped content read uses.
  defp scope_opts(query, opts) do
    scope_to_workspace(
      query,
      Keyword.get(opts, :workspace_id),
      Keyword.get(opts, :project_id)
    )
  end
end
