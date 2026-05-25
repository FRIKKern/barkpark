defmodule Barkpark.Papers.EventsTest do
  @moduledoc """
  P6.U1 (barkpark-3s2u) — the `paper_events` Postgres event store, data spine
  for the native goal-path rail (P6.U2). Covers the `Events` context directly
  and the `Content.upsert_paper/1` event-append (gated on `event_type`).
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Papers.Events

  describe "create_event/1" do
    test "inserts a valid event" do
      assert {:ok, event} =
               Events.create_event(%{
                 "goal_id" => "bd-a1b2",
                 "paper_slug" => "my-plan",
                 "event_type" => "plan-written"
               })

      assert event.id
      assert event.goal_id == "bd-a1b2"
      assert event.paper_slug == "my-plan"
      assert event.event_type == "plan-written"
      assert event.branch == "main"
    end

    test "defaults branch to \"main\" when omitted" do
      assert {:ok, event} =
               Events.create_event(%{
                 "goal_id" => "bd-a1b2",
                 "event_type" => "goal-opened"
               })

      assert event.branch == "main"
    end

    test "carries an explicit branch for the rail gitGraph" do
      assert {:ok, event} =
               Events.create_event(%{
                 "goal_id" => "bd-a1b2",
                 "event_type" => "plan-grilled",
                 "branch" => "alt-2"
               })

      assert event.branch == "alt-2"
    end

    test "rejects a missing event_type" do
      assert {:error, changeset} =
               Events.create_event(%{"goal_id" => "bd-a1b2"})

      assert %{event_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects an event with neither goal_id nor paper_slug" do
      assert {:error, changeset} =
               Events.create_event(%{"event_type" => "plan-written"})

      assert %{goal_id: ["goal_id or paper_slug is required"]} = errors_on(changeset)
    end
  end

  describe "list_for_goal/1" do
    test "returns events for a goal in insertion order" do
      goal_id = "bd-order"

      {:ok, e1} = Events.create_event(%{"goal_id" => goal_id, "event_type" => "goal-opened"})
      {:ok, e2} = Events.create_event(%{"goal_id" => goal_id, "event_type" => "plan-written"})
      {:ok, e3} = Events.create_event(%{"goal_id" => goal_id, "event_type" => "plan-grilled"})

      # An unrelated goal's events must not leak in.
      {:ok, _other} = Events.create_event(%{"goal_id" => "bd-other", "event_type" => "goal-opened"})

      ids = goal_id |> Events.list_for_goal() |> Enum.map(& &1.id)
      assert ids == [e1.id, e2.id, e3.id]
    end
  end

  describe "list_for_paper/1 and get_event/1" do
    test "list_for_paper returns the paper's events; get_event fetches one" do
      {:ok, event} =
        Events.create_event(%{
          "paper_slug" => "p6-u1-spec",
          "event_type" => "goal-snapshot"
        })

      assert [found] = Events.list_for_paper("p6-u1-spec")
      assert found.id == event.id
      assert Events.get_event(event.id).id == event.id
    end
  end

  describe "Content.upsert_paper/1 event append" do
    test "appends exactly one event when event_type is present" do
      slug = "wired-paper"

      assert {:ok, _doc} =
               Content.upsert_paper(%{
                 "slug" => slug,
                 "body_html" => "<p>hello</p>",
                 "goal_id" => "bd-wire",
                 "event_type" => "plan-written",
                 "source_doc" => "plans/my-plan.html"
               })

      events = Events.list_for_paper(slug)
      assert length(events) == 1

      [event] = events
      assert event.event_type == "plan-written"
      assert event.goal_id == "bd-wire"
      assert event.paper_slug == slug
      assert event.source_doc == "plans/my-plan.html"
      assert event.branch == "main"
    end

    test "appends no event when event_type is absent (ordinary streaming save)" do
      slug = "quiet-paper"

      assert {:ok, _doc} =
               Content.upsert_paper(%{
                 "slug" => slug,
                 "body_html" => "<p>no event here</p>"
               })

      assert Events.list_for_paper(slug) == []
    end

    test "appends no event when event_type is an empty string" do
      slug = "empty-type-paper"

      assert {:ok, _doc} =
               Content.upsert_paper(%{
                 "slug" => slug,
                 "body_html" => "<p>blank</p>",
                 "event_type" => ""
               })

      assert Events.list_for_paper(slug) == []
    end
  end
end
