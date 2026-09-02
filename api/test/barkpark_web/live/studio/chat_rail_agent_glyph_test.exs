defmodule BarkparkWeb.Studio.ChatRailAgentGlyphTest do
  @moduledoc """
  task-5e88e691e0d6e31d — the STUDIO half of the agents-rail glyph lock.

  The agents rail paints one glyph per workflow_agent node, and that truth table
  shipped TWICE with nothing holding the copies together: `rail_agent_glyph/1`
  here, and `workflowAgentGlyph` in `internal/chat/render.go` — whose own comment
  said it "mirrors Studio's rail_agent_glyph", which is the informal way of
  saying kept in sync by hand.

  This suite and `internal/chat/rail_glyph_lock_test.go` read the SAME checked-in
  file, `test/support/fixtures/chat_rail_agent_glyphs.json`, so a glyph change on
  either surface reds the OTHER surface's test.

  Two things are locked, not one:

    * the CHARACTERS — failed ✕, terminal ✓, otherwise ●;
    * the PRECEDENCE — the failure set is a SUBSET of the terminal set, and
      `failed` is checked FIRST, so a node that is BOTH renders ✕. Swap the two
      cond arms and the glyph SET still matches while the behaviour diverges;
      `test "precedence: ..."` below is what catches that.

  Pure functions only — no mount, no DB — so `async: true`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.StudioChat
  alias BarkparkWeb.Studio.ChatLive

  @fixture Path.expand("../../../support/fixtures/chat_rail_agent_glyphs.json", __DIR__)
  @external_resource @fixture

  setup_all do
    cases =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("cases")

    {:ok, cases: cases}
  end

  test "the shared fixture is non-vacuous and covers all three glyphs", %{cases: cases} do
    refute cases == [], "an empty fixture is a lock that proves nothing"

    glyphs = cases |> Enum.map(& &1["glyph"]) |> Enum.uniq() |> Enum.sort()
    assert glyphs == Enum.sort(["✕", "✓", "●"]),
           "the fixture must exercise every arm of rail_agent_glyph/1, got #{inspect(glyphs)}"
  end

  test "rail_agent_glyph/1 matches the shared cross-surface fixture", %{cases: cases} do
    for c <- cases do
      node = %{"type" => "workflow_agent", "state" => c["state"]}

      assert ChatLive.rail_agent_glyph(node) == c["glyph"],
             "state #{inspect(c["state"])} (#{c["case"]}): rail_agent_glyph/1 returned " <>
               "#{inspect(ChatLive.rail_agent_glyph(node))}, the shared fixture " <>
               "(#{Path.relative_to_cwd(@fixture)}) says #{inspect(c["glyph"])} — " <>
               "internal/chat/rail_glyph_lock_test.go reads the same row"
    end
  end

  test "the fixture's terminal/failed flags are the ones this surface actually answers",
       %{cases: cases} do
    for c <- cases do
      node = %{"type" => "workflow_agent", "state" => c["state"]}

      assert StudioChat.workflow_node_terminal?(node) == c["terminal"],
             "state #{inspect(c["state"])}: workflow_node_terminal?/1 disagrees with the fixture"

      assert StudioChat.workflow_node_failed?(node) == c["failed"],
             "state #{inspect(c["state"])}: workflow_node_failed?/1 disagrees with the fixture"
    end
  end

  test "precedence: a node that is BOTH failed and terminal renders the FAILED glyph",
       %{cases: cases} do
    both = Enum.filter(cases, &(&1["failed"] and &1["terminal"]))

    refute both == [],
           "the fixture carries no failed-AND-terminal row, so the arm ORDER is unproved"

    for c <- both do
      node = %{"type" => "workflow_agent", "state" => c["state"]}

      assert StudioChat.workflow_node_failed?(node) and StudioChat.workflow_node_terminal?(node),
             "fixture row #{inspect(c["state"])} claims both, but this surface disagrees"

      assert ChatLive.rail_agent_glyph(node) == "✕",
             "state #{inspect(c["state"])} is failed AND terminal, so `failed` must be checked " <>
               "BEFORE `terminal` — got #{inspect(ChatLive.rail_agent_glyph(node))}, want \"✕\". " <>
               "Swapping the two cond arms in rail_agent_glyph/1 is exactly what this reds on."
    end
  end

  test "an absent state has not settled — it breathes" do
    assert ChatLive.rail_agent_glyph(%{"type" => "workflow_agent"}) == "●"
    assert ChatLive.rail_agent_glyph(%{"type" => "workflow_agent", "state" => nil}) == "●"
  end
end
