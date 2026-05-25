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
end
