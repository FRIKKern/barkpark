defmodule Barkpark.StudioChat.TaskTransitionTest do
  @moduledoc """
  The ONE scoping/keying/labelling rule both chat surfaces fold
  (tlv-bl-chat-live-transition-stream). Pure — no DB, no PubSub, no LiveView:
  every branch of the rule is exercised here, and the surface tests then only
  have to prove the WIRING.
  """
  use ExUnit.Case, async: true

  alias Barkpark.StudioChat.TaskTransition

  @worker "claude-chat-abc12345"

  defp msg(opts) do
    %{
      type: "task",
      doc_id: Keyword.get(opts, :doc_id, "task-x"),
      rev: Keyword.get(opts, :rev, "rev-1"),
      mutation: Keyword.get(opts, :mutation, "task.claimed"),
      event_id: Keyword.get(opts, :event_id, "ev-1"),
      doc: %{
        doc_id: Keyword.get(opts, :doc_id, "task-x"),
        title: Keyword.get(opts, :title, "A task"),
        status: "published",
        content: Keyword.get(opts, :content, %{})
      }
    }
  end

  defp claimed_by(worker, status \\ "in_progress"),
    do: %{"lifecycle_status" => status, "claim" => %{"worker" => worker}}

  describe "scope — the sticky worker rule" do
    test "our worker's claim projects and enrols the task" do
      assert {:ok, t, touched} =
               TaskTransition.project(
                 msg(content: claimed_by(@worker)),
                 @worker,
                 MapSet.new()
               )

      assert t.task_id == "task-x"
      assert t.status == "in_progress"
      assert t.verb == "claimed"
      assert MapSet.member?(touched, "task-x")
    end

    test "another worker's claim is skipped and never enrols" do
      assert {:skip, touched} =
               TaskTransition.project(
                 msg(content: claimed_by("claude-chat-someone-else")),
                 @worker,
                 MapSet.new()
               )

      assert MapSet.size(touched) == 0
    end

    test "a claimless mutation of an ALREADY-touched task still projects" do
      # This is the whole point of stickiness: Tasks.Release clears the lease,
      # so a release carries no claim.worker to match on. Without the sticky
      # set the transition that most invalidates the agent's belief — the one
      # taking the task AWAY — would be the one that never renders.
      touched = MapSet.new(["task-x"])

      assert {:ok, t, ^touched} =
               TaskTransition.project(
                 msg(mutation: "task.released", content: %{"lifecycle_status" => "open"}),
                 @worker,
                 touched
               )

      assert t.verb == "released"
      assert t.status == "open"
    end

    test "a nil worker can never enrol a task" do
      assert {:skip, touched} =
               TaskTransition.project(msg(content: claimed_by(@worker)), nil, MapSet.new())

      assert MapSet.size(touched) == 0
    end

    test "a draft twin is never a transition" do
      assert {:skip, _} =
               TaskTransition.project(
                 msg(doc_id: "drafts.task-x", content: claimed_by(@worker)),
                 @worker,
                 MapSet.new(["drafts.task-x"])
               )
    end
  end

  describe "the lifecycle kind whitelist" do
    test "every whitelisted kind projects for a touched task" do
      touched = MapSet.new(["task-x"])

      for kind <- TaskTransition.lifecycle_kinds() do
        assert {:ok, t, _} =
                 TaskTransition.project(
                   msg(mutation: kind, content: %{"lifecycle_status" => "open"}),
                   @worker,
                   touched
                 )

        assert t.mutation == kind
        assert t.verb != ""
      end
    end

    test "a pulse heartbeat is not a transition" do
      # A held lease pulses on a timer. Rendering it would fill a transcript
      # with rows carrying no news.
      assert {:skip, _} =
               TaskTransition.project(
                 msg(mutation: "task.pulse", content: claimed_by(@worker)),
                 @worker,
                 MapSet.new(["task-x"])
               )
    end

    test "bookkeeping kinds are not transitions" do
      for kind <- ~w(task.criterion task.relabeled task.referenced task.reparented
                     task.compacted task.compaction_restored) do
        # Bind FIRST, then assert on a boolean. `assert pattern = expr, msg` is
        # assert/2 over a match: the match raises MatchError before assert/2 can
        # ever reach the message, so the per-kind label would be dead on the one
        # failure it exists to name (scripts/unreachable-assert-message-check.sh).
        result =
          TaskTransition.project(
            msg(mutation: kind, content: claimed_by(@worker)),
            @worker,
            MapSet.new(["task-x"])
          )

        assert match?({:skip, _}, result),
               "#{kind} must not project, got: #{inspect(result)}"
      end
    end

    test "a broadcast with no mutation kind projects nothing but still enrols" do
      m = Map.delete(msg(content: claimed_by(@worker)), :mutation)
      assert {:skip, touched} = TaskTransition.project(m, @worker, MapSet.new())
      # Enrolment is independent of the kind whitelist: the task is ours now,
      # so the NEXT lifecycle event on it renders.
      assert MapSet.member?(touched, "task-x")
    end
  end

  describe "the idempotency key" do
    test "is the durable mutation_events row id when present" do
      assert TaskTransition.key(msg(event_id: "ev-77")) == "ev-77"
    end

    test "an integer event id keys as its decimal string" do
      assert TaskTransition.key(msg(event_id: 77)) == "77"
    end

    test "degrades to doc_id:mutation:rev when the writer omitted the id" do
      m = Map.delete(msg(doc_id: "task-q", mutation: "task.closed", rev: "r9"), :event_id)
      assert TaskTransition.key(m) == "task-q:task.closed:r9"
    end

    test "two DIFFERENT events on one task key differently" do
      a = TaskTransition.key(msg(mutation: "task.claimed", event_id: "ev-a"))
      b = TaskTransition.key(msg(mutation: "task.closed", event_id: "ev-b"))
      refute a == b
    end
  end

  describe "label + colour" do
    test "the label is <subject> → <status> (<verb>)" do
      assert {:ok, t, _} =
               TaskTransition.project(
                 msg(title: "Sweep the yard", content: claimed_by(@worker)),
                 @worker,
                 MapSet.new()
               )

      assert t.label == "Sweep the yard → in_progress (claimed)"
    end

    test "a titleless broadcast falls back to the task id" do
      assert {:ok, t, _} =
               TaskTransition.project(
                 msg(title: nil, doc_id: "task-untitled", content: claimed_by(@worker)),
                 @worker,
                 MapSet.new()
               )

      assert t.label =~ "task-untitled → "
    end

    test "a missing lifecycle_status reads unknown, never a crash" do
      assert {:ok, t, _} =
               TaskTransition.project(
                 msg(content: %{"claim" => %{"worker" => @worker}}),
                 @worker,
                 MapSet.new()
               )

      assert t.status == "unknown"
    end

    test "colour is ALWAYS a design token, never a literal" do
      for state <-
            ~w(open ready in_progress blocked done closed cancelled considering researching) do
        assert TaskTransition.color(state) == "var(--life-#{state})"
      end

      # An unknown status degrades to the neutral dim token — still a token.
      assert TaskTransition.color("wat") == "var(--fg-dim)"
      assert TaskTransition.color(nil) == "var(--fg-dim)"
    end
  end
end
