defmodule Barkpark.Papers.Events do
  @moduledoc """
  Context over the append-only `paper_events` store — the data spine for the
  native goal-path rail (P6.U2). Pure Ecto over `Barkpark.Repo`; never shells
  out to Beads/`bd` (decoupled from W7).
  """

  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Papers.Event

  @doc """
  Append a lifecycle event. Validates via `Event.changeset/2`
  (`event_type` required + at least one of `goal_id` / `paper_slug`).
  Returns `{:ok, %Event{}}` or `{:error, changeset}`.
  """
  def create_event(attrs) when is_map(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  All events for a goal, oldest first (rail walks the lineage forward).
  """
  def list_for_goal(goal_id) when is_binary(goal_id) do
    Event
    |> where([e], e.goal_id == ^goal_id)
    |> order_by([e], asc: e.inserted_at)
    |> Repo.all()
  end

  @doc """
  All events for a paper (by slug), oldest first.
  """
  def list_for_paper(paper_slug) when is_binary(paper_slug) do
    Event
    |> where([e], e.paper_slug == ^paper_slug)
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
  """
  def list_pending_intents do
    Event
    |> where([e], is_nil(e.processed_at))
    |> where([e], like(e.event_type, "action:%") or like(e.event_type, "simplify-%"))
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
end
