defmodule Barkpark.Plugins.Bulldocs.EventsTest do
  @moduledoc """
  P6.U1 (barkpark-3s2u) — the `paper_events` Postgres event store, data spine
  for the native goal-path rail (P6.U2). Covers the `Events` context directly
  and the `Content.upsert_paper/1` event-append (gated on `event_type`).
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Plugins.Bulldocs.Events

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
      {:ok, _other} =
        Events.create_event(%{"goal_id" => "bd-other", "event_type" => "goal-opened"})

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

    test "get_event returns nil for a malformed (non-UUID) id instead of raising" do
      # The public paper reader's open-diff handler pushes client-controlled
      # ids straight in — a non-UUID must yield nil, not an Ecto.Query.CastError.
      assert Events.get_event("not-a-uuid") == nil
      assert Events.get_event("evt_abc") == nil
    end
  end

  describe "list_pending_intents/0 and mark_processed/1" do
    test "returns only unprocessed actionable intents; excludes lifecycle + processed" do
      goal_id = "bd-intents"

      {:ok, build} =
        Events.create_event(%{
          "goal_id" => goal_id,
          "event_type" => "action:build"
        })

      {:ok, simplify} =
        Events.create_event(%{
          "goal_id" => goal_id,
          "event_type" => "simplify-request"
        })

      # A lifecycle event — NOT an intent, must be excluded.
      {:ok, _opened} =
        Events.create_event(%{
          "goal_id" => goal_id,
          "event_type" => "goal-opened"
        })

      # An actionable intent that has already been processed — must be excluded.
      {:ok, grill} =
        Events.create_event(%{
          "goal_id" => goal_id,
          "event_type" => "action:grill"
        })

      {:ok, _} = Events.mark_processed(grill.id)

      pending_ids = Events.list_pending_intents() |> Enum.map(& &1.id)

      assert pending_ids == [build.id, simplify.id]
      refute grill.id in pending_ids
    end

    test "mark_processed/1 stamps processed_at and drops the row from pending" do
      {:ok, intent} =
        Events.create_event(%{
          "goal_id" => "bd-mark",
          "event_type" => "action:review"
        })

      assert is_nil(intent.processed_at)
      assert intent.id in (Events.list_pending_intents() |> Enum.map(& &1.id))

      assert {:ok, marked} = Events.mark_processed(intent.id)
      assert marked.processed_at

      refute intent.id in (Events.list_pending_intents() |> Enum.map(& &1.id))
    end

    test "mark_processed/1 on a bad id returns {:error, :not_found}" do
      assert {:error, :not_found} = Events.mark_processed(Ecto.UUID.generate())
    end
  end

  describe "Content.upsert_paper/1 event append" do
    test "appends exactly one event when event_type is present" do
      slug = "wired-paper"

      assert {:ok, _doc} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   "slug" => slug,
                   "body_html" => "<p>hello</p>",
                   "goal_id" => "bd-wire",
                   "event_type" => "plan-written",
                   "source_doc" => "plans/my-plan.html"
                 })
               )

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
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   "slug" => slug,
                   "body_html" => "<p>no event here</p>"
                 })
               )

      assert Events.list_for_paper(slug) == []
    end

    test "appends no event when event_type is an empty string" do
      slug = "empty-type-paper"

      assert {:ok, _doc} =
               Content.upsert_paper(
                 Barkpark.LabelFixtures.paper_attrs(%{
                   "slug" => slug,
                   "body_html" => "<p>blank</p>",
                   "event_type" => ""
                 })
               )

      assert Events.list_for_paper(slug) == []
    end
  end

  describe "record_decision/1 — the requester<->accepter identity tie (task-cefcbf5b3a9b1665)" do
    @slug "tie-demo-paper"

    defp seed_request(overrides \\ %{}) do
      {:ok, request} =
        Events.create_event(
          Map.merge(
            %{
              "goal_id" => "g-tie",
              "paper_slug" => @slug,
              "event_type" => "simplify-request",
              "branch" => "simplified-1",
              "actor_kind" => "user",
              "actor_id" => "user-alice"
            },
            overrides
          )
        )

      request
    end

    defp decision_attrs(request, overrides \\ %{}) do
      Map.merge(
        %{
          "event_type" => "simplify-accept",
          "paper_slug" => request.paper_slug,
          "request_event_id" => request.id,
          "actor_kind" => "user",
          "actor_id" => "user-alice"
        },
        overrides
      )
    end

    test "the REQUESTER's own accept is authorized and points back at the request" do
      request = seed_request()

      assert {:ok, decision} = Events.record_decision(decision_attrs(request))

      assert decision.event_type == "simplify-accept"
      assert decision.request_event_id == request.id
      assert decision.actor_kind == "user"
      assert decision.actor_id == "user-alice"
      assert decision.authorization == "authorized"
      # Branch + goal are re-derived from the STORED request, never trusted
      # from the caller.
      assert decision.branch == "simplified-1"
      assert decision.goal_id == "g-tie"
      assert Events.authoritative_decision?(decision)
    end

    test "a DIFFERENT user cannot decide someone else's request, and writes nothing" do
      request = seed_request()
      before = length(Events.list_for_paper(@slug))

      assert {:error, :foreign_actor} =
               Events.record_decision(decision_attrs(request, %{"actor_id" => "user-mallory"}))

      # No row — a refused decision leaves no trace in the append-only history.
      assert length(Events.list_for_paper(@slug)) == before
    end

    test "an ANONYMOUS decision is refused before the request is even read" do
      request = seed_request()

      assert {:error, :anonymous} =
               Events.record_decision(
                 decision_attrs(request, %{"actor_kind" => nil, "actor_id" => nil})
               )
    end

    test "a CROSS-WORKSPACE decision is refused even from the same actor" do
      workspace = create_workspace!()
      other = create_workspace!()

      request = seed_request(%{"workspace_id" => workspace.id})

      assert {:error, :cross_scope} =
               Events.record_decision(decision_attrs(request, %{"workspace_id" => other.id}))

      # Control: the SAME call with the request's own workspace lands.
      assert {:ok, _} =
               Events.record_decision(decision_attrs(request, %{"workspace_id" => workspace.id}))
    end

    # The PROJECT rung of check_same_scope/2. The sibling test above holds
    # project_id nil on BOTH sides, so the workspace conjunct decides it in
    # both arms — these hold the WORKSPACE equal so only the project
    # conjunct can produce the refusal.
    test "a CROSS-PROJECT decision is refused with the workspace held EQUAL" do
      workspace = create_workspace!()
      proj_a = create_project!(workspace)
      proj_b = create_project!(workspace)

      request =
        seed_request(%{"workspace_id" => workspace.id, "project_id" => proj_a.id})

      # Same workspace on both sides — the workspace conjunct CANNOT refuse
      # this; only the project conjunct can.
      assert request.workspace_id == workspace.id
      assert request.project_id == proj_a.id
      assert proj_a.id != proj_b.id

      assert {:error, :cross_scope} =
               Events.record_decision(
                 decision_attrs(request, %{
                   "workspace_id" => workspace.id,
                   "project_id" => proj_b.id
                 })
               )

      # Control: the SAME call with the request's own project lands.
      assert {:ok, decision} =
               Events.record_decision(
                 decision_attrs(request, %{
                   "workspace_id" => workspace.id,
                   "project_id" => proj_a.id
                 })
               )

      assert decision.authorization == "authorized"
    end

    test "a decision that OMITS project_id cannot decide a project-scoped request" do
      workspace = create_workspace!()
      proj_a = create_project!(workspace)

      request =
        seed_request(%{"workspace_id" => workspace.id, "project_id" => proj_a.id})

      # The unscoped-reader shape: stamp_scope/2 omits the key entirely when
      # the resolved paper carries no project, so fetch/2 reads nil.
      attrs = decision_attrs(request, %{"workspace_id" => workspace.id})
      refute Map.has_key?(attrs, "project_id")

      assert {:error, :cross_scope} = Events.record_decision(attrs)

      # Control: the same actor, same workspace, WITH the project lands.
      assert {:ok, decision} =
               Events.record_decision(
                 decision_attrs(request, %{
                   "workspace_id" => workspace.id,
                   "project_id" => proj_a.id
                 })
               )

      assert decision.authorization == "authorized"
    end

    test "a project-scoped decision cannot decide an UNSCOPED request" do
      workspace = create_workspace!()
      proj_a = create_project!(workspace)

      # The mirror of the arm above: the request carries no project, the
      # decision does. nil != proj_a.id is still a scope mismatch.
      request = seed_request(%{"workspace_id" => workspace.id})
      assert is_nil(request.project_id)

      assert {:error, :cross_scope} =
               Events.record_decision(
                 decision_attrs(request, %{
                   "workspace_id" => workspace.id,
                   "project_id" => proj_a.id
                 })
               )

      assert {:ok, decision} =
               Events.record_decision(decision_attrs(request, %{"workspace_id" => workspace.id}))

      assert decision.authorization == "authorized"
    end

    test "REPLAY: a second authorized decision on the same request is refused" do
      request = seed_request()

      assert {:ok, _} = Events.record_decision(decision_attrs(request))

      assert {:error, :already_decided} =
               Events.record_decision(
                 decision_attrs(request, %{"event_type" => "simplify-reject"})
               )
    end

    test "an EXPIRED request can no longer be decided" do
      request = seed_request()

      stale =
        DateTime.add(DateTime.utc_now(), -(Events.decision_ttl_seconds() + 60), :second)

      {1, _} =
        Barkpark.Repo.update_all(
          Ecto.Query.from(e in Barkpark.Plugins.Bulldocs.Event, where: e.id == ^request.id),
          set: [inserted_at: stale]
        )

      assert {:error, :expired_request} = Events.record_decision(decision_attrs(request))
    end

    test "an unknown / non-UUID / non-request id is refused, never raised" do
      assert {:error, :unknown_request} =
               Events.record_decision(%{
                 "event_type" => "simplify-accept",
                 "paper_slug" => @slug,
                 "request_event_id" => "not-a-uuid",
                 "actor_kind" => "user",
                 "actor_id" => "user-alice"
               })

      {:ok, lifecycle} =
        Events.create_event(%{
          "paper_slug" => @slug,
          "event_type" => "goal-opened",
          "actor_kind" => "user",
          "actor_id" => "user-alice"
        })

      assert {:error, :not_a_request} =
               Events.record_decision(decision_attrs(lifecycle))
    end

    test "a decision for a DIFFERENT paper is refused" do
      request = seed_request()

      assert {:error, :wrong_paper} =
               Events.record_decision(decision_attrs(request, %{"paper_slug" => "other-paper"}))
    end
  end

  describe "decision_audit/2 — who accepted what request (task-cefcbf5b3a9b1665)" do
    test "names both sides of an authorized decision and flags an untied one" do
      slug = "audit-paper"

      {:ok, request} =
        Events.create_event(%{
          "goal_id" => "g-audit",
          "paper_slug" => slug,
          "event_type" => "simplify-request",
          "branch" => "simplified-1",
          "actor_kind" => "user",
          "actor_id" => "user-alice"
        })

      {:ok, _} =
        Events.record_decision(%{
          "event_type" => "simplify-accept",
          "paper_slug" => slug,
          "request_event_id" => request.id,
          "actor_kind" => "user",
          "actor_id" => "user-alice"
        })

      # An untied decision written straight through create_event/1.
      {:ok, _} =
        Events.create_event(%{
          "goal_id" => "g-audit",
          "paper_slug" => slug,
          "event_type" => "simplify-reject",
          "branch" => "simplified-7"
        })

      audit = Events.decision_audit(slug)

      tied = Enum.find(audit, & &1.authoritative?)
      untied = Enum.find(audit, &(not &1.authoritative?))

      assert tied.decision == "simplify-accept"
      assert tied.request_event_id == request.id
      assert tied.branch == "simplified-1"
      assert tied.requested_by == {"user", "user-alice"}
      assert tied.decided_by == {"user", "user-alice"}
      assert tied.authorization == "authorized"

      # The untrustworthy row is LISTED, not hidden — that is the point of an
      # audit surface.
      assert untied.decision == "simplify-reject"
      assert untied.request_event_id == nil
      assert untied.requested_by == nil
      assert untied.authorization == "unverified"
    end
  end

  describe "the consumer gate: list_pending_intents/1 (task-cefcbf5b3a9b1665)" do
    test "drains an AUTHORIZED decision and withholds an unverified one" do
      goal_id = "bd-consumer-gate"

      # A decision written straight through create_event/1 — nobody checked
      # the tie, so the changeset stamps it "unverified".
      {:ok, unverified} =
        Events.create_event(%{
          "goal_id" => goal_id,
          "paper_slug" => "gate-paper",
          "event_type" => "simplify-accept",
          "branch" => "simplified-9"
        })

      assert unverified.authorization == "unverified"
      refute Events.authoritative_decision?(unverified)

      {:ok, request} =
        Events.create_event(%{
          "goal_id" => goal_id,
          "paper_slug" => "gate-paper",
          "event_type" => "simplify-request",
          "branch" => "simplified-1",
          "actor_kind" => "user",
          "actor_id" => "user-alice"
        })

      {:ok, authorized} =
        Events.record_decision(%{
          "event_type" => "simplify-accept",
          "paper_slug" => "gate-paper",
          "request_event_id" => request.id,
          "actor_kind" => "user",
          "actor_id" => "user-alice"
        })

      pending_ids = Events.list_pending_intents() |> Enum.map(& &1.id)

      # The request itself still drains (it is not a decision).
      assert request.id in pending_ids
      # The tied decision reaches the automation …
      assert authorized.id in pending_ids
      # … the untied one never does.
      refute unverified.id in pending_ids
    end
  end
end
