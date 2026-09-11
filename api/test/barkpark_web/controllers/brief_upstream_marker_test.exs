defmodule BarkparkWeb.TasksController.BriefUpstreamMarkerTest do
  @moduledoc """
  task-e8d0fe00383f8499, criterion 1: a ready row whose remaining work is a
  SEAL but which carries `child_count: 0` must be mechanically distinguishable
  in `bp task ready` output — demonstrated on `task-08b05ad1e792a850`
  specifically, the PRIORITY 0 miss, beside a genuine leaf from the SAME live
  listing.

  This is the sibling of `BriefDispatchMarkerTest` (#16762), which proves the
  OUTBOUND half. Both render through the shipped `Params.render_brief/4` — the
  exact function `GET /v1/tasks?view=brief` maps over its page — and the
  fixtures are REAL rows off a live 1,000-row ready page read 2026-09-07, with
  their real parent edges and their real criterion text.

  MUTATION PROOF: make `put_brief_upstream/3` a no-op
  (`defp put_brief_upstream(map, _, _), do: map`) and the GOAL test reds while
  every negative-arm test stays green.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Document
  alias BarkparkWeb.TasksController.Params

  # The row the filing names. child_count 0 — its children hang off the mobile
  # epic, not off it — so #16762's parent-edge rule renders it as a leaf.
  @goal_id "task-08b05ad1e792a850"
  @goal_parent "task-c31a4f0a6c5be3ea"

  # A genuine zero-child leaf from the same listing, with a LIVE parent it
  # simply never names. It must fail differently from the GOAL row or the
  # comparison proves nothing.
  @leaf_id "legendary-quality-takeover-experiment-readers"
  @leaf_parent "legendary-quality-takeover-root"

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

  defp goal_row do
    doc(@goal_id, "GOAL: drive the mobile epic to the seal — rounds until every child closes", %{
      "priority" => 0,
      "parent_id" => @goal_parent,
      "acceptance_criteria" => [
        %{
          "criterion" =>
            "Every executable child of #{@goal_parent} EXCEPT this GOAL task and " <>
              "the D34 bucket-C human-gate rows is lifecycle_status done or cancelled.",
          "met" => false
        }
      ]
    })
  end

  defp leaf_row do
    doc(@leaf_id, "Run Experiment 15 on five real readers with the local E22 allocator", %{
      "priority" => 0,
      "parent_id" => @leaf_parent,
      "acceptance_criteria" => [%{"criterion" => "The five readers run.", "met" => false}]
    })
  end

  setup do
    # Both parents are LIVE on the measured page: the leaf's parent being live
    # too is the point — liveness alone does not mark a card.
    live_parents = %{@goal_parent => true, @leaf_parent => true}

    %{
      goal: Params.render_brief(goal_row(), %{}, %{}, live_parents),
      leaf: Params.render_brief(leaf_row(), %{}, %{}, live_parents),
      live_parents: live_parents
    }
  end

  test "the childless GOAL card SAYS its work is upstream", %{goal: card, leaf: leaf} do
    assert card.dispatch == "upstream"
    # The whole point: the outbound edge sees NOTHING here.
    assert card.child_count == 0
    assert card.priority == 0

    # Criterion 1 asks for the two rendered lines side by side. Printed so the
    # evidence can be pasted rather than described.
    IO.puts("\nGOAL(childless)  " <> Jason.encode!(card))
    IO.puts("LEAF             " <> Jason.encode!(leaf))
  end

  test "the ordinary leaf renders UNCHANGED — no key, not even a null", %{leaf: card} do
    refute Map.has_key?(card, :dispatch)
    assert card.child_count == 0
    assert card.priority == 0
  end

  test "an UNMEASURED parent map says nothing rather than something false" do
    # nil live_parents = the caller never paid for the parent query. An empty
    # map would have read as "no parent is live", a measurement nobody made —
    # but nil and empty must BOTH stay silent, and for different reasons.
    assert Params.render_brief(goal_row(), %{}, %{}, nil) |> Map.has_key?(:dispatch) == false
    assert Params.render_brief(goal_row(), %{}, %{}, %{}) |> Map.has_key?(:dispatch) == false
  end

  test "a TERMINAL parent is declined, not marked" do
    # 166 of the 1,000 measured rows sit under a parent that has already
    # stopped. `batch_live_parents/2` simply omits them, and omission must not
    # read as "live".
    card = Params.render_brief(goal_row(), %{}, %{}, %{"some-other-parent" => true})
    refute Map.has_key?(card, :dispatch)
  end

  test "a MET criterion naming the live parent does not mark the card" do
    # The signal is unmet work pointing upstream. Once the criterion is
    # stamped, the row no longer waits on anything.
    stamped =
      doc(@goal_id, "GOAL: …", %{
        "priority" => 0,
        "parent_id" => @goal_parent,
        "acceptance_criteria" => [
          %{"criterion" => "Every executable child of #{@goal_parent} is done.", "met" => true}
        ]
      })

    refute Map.has_key?(
             Params.render_brief(stamped, %{}, %{}, %{@goal_parent => true}),
             :dispatch
           )
  end

  test "classify/2 OUTRANKS classify_upstream/3 — one key, one verdict", %{
    live_parents: live_parents
  } do
    # github-bridge-mirror-exposure-decision off the same page: it matches BOTH
    # rules (1 live child, and a criterion naming its live parent). The
    # outbound edge is the stronger measurement (precision 11/15 vs 2/9) and
    # must win, or the card would carry two verdicts.
    both =
      doc("github-bridge-mirror-exposure-decision", "DECISION (human): public-mirror exposure", %{
        "priority" => 2,
        "parent_id" => "github-bridge-epic",
        "acceptance_criteria" => [
          %{
            "criterion" => "follow-up build slice task(s) filed under github-bridge-epic",
            "met" => false
          }
        ]
      })

    card =
      Params.render_brief(
        both,
        %{"github-bridge-mirror-exposure-decision" => 1},
        %{"github-bridge-mirror-exposure-decision" => 1},
        Map.put(live_parents, "github-bridge-epic", true)
      )

    assert card.dispatch == "delegated"
  end

  test "the marker costs 22 bytes on the wire, and never stacks" do
    # Criterion 3 / the live payload defect: the 50-card brief page is already
    # over its byte bound, so a new key has to be priced, not estimated.
    live = %{@goal_parent => true}
    marked = Jason.encode!(Params.render_brief(goal_row(), %{}, %{}, live))
    unmarked = Jason.encode!(Params.render_brief(goal_row(), %{}, %{}, nil))

    assert byte_size(marked) - byte_size(unmarked) == 22

    assert String.contains?(marked, ~s(,"dispatch":"upstream")) or
             String.contains?(marked, ~s("dispatch":"upstream"))

    # Shorter than #16762's own worst case, and mutually exclusive with it, so
    # the page worst case does not grow: 50 cards can still only carry one
    # dispatch value each.
    assert 22 < byte_size(~s(,"dispatch":"delegated"))
  end
end
