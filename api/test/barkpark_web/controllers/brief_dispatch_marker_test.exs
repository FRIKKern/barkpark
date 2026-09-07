defmodule BarkparkWeb.TasksController.BriefDispatchMarkerTest do
  @moduledoc """
  task-52f4f3aff99c64d5, criterion 0: the ready listing must distinguish an
  umbrella seal from a dispatchable slice IN ITS OWN OUTPUT, without the
  reader opening the row.

  This renders BOTH cards through the shipped `Params.render_brief/3` — the
  exact function `GET /v1/tasks?view=brief` (which is what `bp task ready`
  calls) maps over its page — and asserts the difference is on the card. The
  fixtures are the REAL rows off a live 1,000-row ready page read 2026-09-07,
  with their real child edges.

  MUTATION PROOF: make `put_brief_dispatch/4` a no-op (`def
  put_brief_dispatch(map, _, _, _), do: map`) and the umbrella test reds while
  the leaf test stays green — which is the whole shape of the claim.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Document
  alias BarkparkWeb.TasksController.Params

  # The row the filing names. 359 children, 71 of them live; its seventh
  # criterion reads "SEAL — THE LEAD CLOSES THIS".
  @umbrella_id "task-fb4fb869490b4213"
  @umbrella_children 359
  @umbrella_live 71

  # A genuine zero-child leaf sitting in the SAME ready page at the SAME
  # priority 0 — the control. It must fail differently from the umbrella or
  # the comparison proves nothing.
  @leaf_id "legendary-quality-takeover-experiment-readers"

  defp doc(doc_id, title, content) do
    %Document{
      id: Ecto.UUID.generate(),
      doc_id: doc_id,
      type: "task",
      status: "published",
      title: title,
      content: Map.merge(%{"kind" => "task", "lifecycle_status" => "open"}, content),
      updated_at: ~N[2026-09-06 01:27:00]
    }
  end

  setup do
    umbrella =
      doc(@umbrella_id, "Guerrilla deployments fail 69% of the time and nothing says so", %{
        "priority" => 0,
        "assignee" => "lane-guerrilla-deploy",
        "acceptance_criteria" => [
          %{"criterion" => "SEAL -- THE LEAD CLOSES THIS.", "met" => false}
        ]
      })

    leaf =
      doc(@leaf_id, "Run Experiment 15 on five real readers with the local E22 allocator", %{
        "priority" => 0,
        "parent_id" => "legendary-quality-takeover-root",
        "acceptance_criteria" => [%{"criterion" => "The five readers run.", "met" => false}]
      })

    # The two batched maps the controller hands render_brief/3. The leaf is
    # absent from both, exactly as the grouped queries leave a childless row.
    totals = %{@umbrella_id => @umbrella_children}
    lives = %{@umbrella_id => @umbrella_live}

    %{
      umbrella: Params.render_brief(umbrella, totals, lives),
      leaf: Params.render_brief(leaf, totals, lives)
    }
  end

  test "the umbrella card SAYS it is not a slice", %{umbrella: card, leaf: leaf} do
    assert card.dispatch == "delegated"
    assert card.child_count == @umbrella_children
    assert card.priority == 0

    # The two rendered lines, side by side, as criterion 0 asks. Printed so
    # the evidence can be pasted rather than described.
    IO.puts("\nUMBRELLA  " <> Jason.encode!(card))
    IO.puts("LEAF      " <> Jason.encode!(leaf))
  end

  test "the ordinary leaf renders UNCHANGED — no key, not even a null", %{leaf: card} do
    refute Map.has_key?(card, :dispatch)
    assert card.child_count == 0
    # Same priority, same status, same shape as before this change: the only
    # difference between the two cards is the marker itself.
    assert card.priority == 0
  end

  test "an UNMEASURED live map says nothing rather than something false" do
    # nil live map = the caller never paid for the live query. An empty map
    # would have read as "zero live children" and stamped `undecided` on a
    # 359-child epic.
    card =
      Params.render_brief(
        doc(@umbrella_id, "x", %{"priority" => 0}),
        %{@umbrella_id => @umbrella_children},
        nil
      )

    refute Map.has_key?(card, :dispatch)
    assert card.child_count == @umbrella_children
  end

  test "a parent whose children are all closed is marked UNDECIDED, not dispatchable" do
    # chat-local-cloud-context-w3 off the same live page: 3 children, all done.
    card =
      Params.render_brief(
        doc("chat-local-cloud-context-w3", "Make local-first Barkpark Chat …", %{"priority" => 0}),
        %{"chat-local-cloud-context-w3" => 3},
        %{}
      )

    assert card.dispatch == "undecided"
  end
end
