defmodule BarkparkWeb.Studio.ChatRegroupIncrementalTest do
  @moduledoc """
  INCREMENTAL REGROUPING (task-07f27c32c84a5005).

  `ChatLive.assign_messages/2` used to re-run the whole grouping pipeline —
  `group_agent_rows/1` -> `fold_running_turn/1` -> `fold_settled_turns/1` — over
  the ENTIRE transcript on every write: O(N) grouping per append, O(N^2) across a
  session. `ChatLive.regroup/2` keeps an already-grouped PREFIX and regroups only
  the tail that can still change.

  Two things are proved here, and they pull in opposite directions:

    * THE BOUND — `cache.visited` is the number of transcript rows this call
      handed to the grouping pass. It must be bounded by the size of the last
      turn and be IDENTICAL at N=20 and N=400. This is the whole point of the
      slice; restoring the whole-list regroup reds it at N=400.
    * CORRECTNESS — at every single append, the incremental items must equal the
      items a from-scratch regroup of the same list produces, byte for byte.
      This is the fence on the bound: shrinking the incremental boundary by one
      turn (letting the prefix swallow rows of a turn that is still running)
      reds it, because a running turn's fold needs all of its rows at once.

  The visit count is read from the production memo itself, not from a test-only
  wrapper, so it cannot drift away from what the pipeline actually does.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.ChatLive

  # A turn is 5 rows: the prompt, three tool rows, the reply. The BOUND is
  # therefore 4 — the tool rows plus the reply that closes the turn.
  @turn_tools 3
  @turn_rows @turn_tools + 2
  @bound @turn_tools + 1

  defp user(id), do: %{id: id, role: :user, text: "u#{id}"}
  defp assistant(id), do: %{id: id, role: :assistant, text: "a#{id}"}

  defp settled_tool(id, turn),
    do: %{
      id: id,
      role: :tool,
      turn_settled: true,
      turn_settled_at: "turn-#{turn}",
      turn_outcome: "completed",
      turn_duration_ms: 1000,
      output: "done",
      spawn?: false,
      tool_use_id: nil,
      parent_tool_use_id: nil
    }

  # A row of a RUNNING turn: no settle stamp, so U1's fold can never claim it.
  # An EMPTY output is a row still awaiting its tool_result — the ACTIVE row.
  defp live_tool(id, output),
    do: %{
      id: id,
      role: :tool,
      turn_settled: false,
      output: output,
      spawn?: false,
      tool_use_id: nil,
      parent_tool_use_id: nil
    }

  # `turns` settled turns back to back, each closed by an assistant reply.
  defp transcript(turns) do
    Enum.flat_map(1..turns, fn t ->
      base = (t - 1) * @turn_rows

      [user(base + 1)] ++
        Enum.map(1..@turn_tools, fn i -> settled_tool(base + 1 + i, t) end) ++
        [assistant(base + @turn_rows)]
    end)
  end

  # One more turn's rows, appended ONE AT A TIME onto `base`; returns the visit
  # count each append cost.
  defp append_visits(base) do
    turn = div(length(base), @turn_rows) + 1
    base_id = length(base)

    new_rows =
      [user(base_id + 1)] ++
        Enum.map(1..@turn_tools, fn i -> settled_tool(base_id + 1 + i, turn) end) ++
        [assistant(base_id + @turn_rows)]

    {_items, seeded} = ChatLive.regroup(base, ChatLive.empty_grouping_cache())

    {visits, _acc} =
      Enum.map_reduce(new_rows, {base, seeded}, fn row, {msgs, cache} ->
        msgs = msgs ++ [row]
        {_items, cache} = ChatLive.regroup(msgs, cache)
        {cache.visited, {msgs, cache}}
      end)

    visits
  end

  describe "the per-append bound" do
    test "the grouping pass visits the last turn, not the transcript — same at N=20 and N=400" do
      small = transcript(div(20, @turn_rows))
      large = transcript(div(400, @turn_rows))

      # Non-vacuity: the two transcripts really are the sizes the criterion names.
      assert length(small) == 20
      assert length(large) == 400

      visits_small = append_visits(small)
      visits_large = append_visits(large)

      assert visits_small == visits_large,
             "the per-append visit count must not depend on N: N=20 gave #{inspect(visits_small)}, N=400 gave #{inspect(visits_large)}"

      assert Enum.max(visits_large) <= @bound,
             "one append must visit at most the last turn (#{@bound} rows), got #{inspect(visits_large)}"

      # And the bound is not vacuously large: a full regroup at N=400 would be 400.
      assert Enum.max(visits_large) < 20
    end

    test "a from-scratch regroup reports the whole list as visited" do
      # The instrument reads honestly in the other direction too — otherwise a
      # `visited: 0` stub would pass the bound test above.
      large = transcript(80)
      {_items, cache} = ChatLive.regroup(large, ChatLive.empty_grouping_cache())
      assert cache.visited == 400
    end
  end

  # ── the correctness fence on the bound ──────────────────────────────────────

  # A transcript with every shape the boundary has to survive: settled turns, an
  # agent spawn with its children, an ORPHAN child (parent never spawns), and a
  # RUNNING turn at the end whose active row is not its first.
  defp mixed_transcript do
    [
      user(1),
      settled_tool(2, 1),
      settled_tool(3, 1),
      assistant(4),
      user(5),
      Map.merge(settled_tool(6, 2), %{spawn?: true, tool_use_id: "sp-1"}),
      Map.merge(settled_tool(7, 2), %{parent_tool_use_id: "sp-1"}),
      Map.merge(settled_tool(8, 2), %{parent_tool_use_id: "sp-1"}),
      Map.merge(settled_tool(9, 2), %{parent_tool_use_id: "never-spawned"}),
      assistant(10),
      user(11),
      live_tool(12, "r1"),
      live_tool(13, "r2"),
      live_tool(14, "")
    ]
  end

  defp from_scratch(messages) do
    {items, _cache} = ChatLive.regroup(messages, ChatLive.empty_grouping_cache())
    items
  end

  describe "incremental regrouping is indistinguishable from a full regroup" do
    test "every append of a mixed transcript matches a from-scratch regroup" do
      all = mixed_transcript()

      Enum.reduce(1..length(all), ChatLive.empty_grouping_cache(), fn k, cache ->
        prefix = Enum.take(all, k)
        {items, cache} = ChatLive.regroup(prefix, cache)

        assert items == from_scratch(prefix),
               "append ##{k} diverged from a full regroup of the same #{k} rows"

        cache
      end)
    end

    test "a running turn keeps ONE fold across every mid-turn append" do
      # The named case the boundary mutation breaks: rows 12..14 are one running
      # turn, and its fold has to see all three rows at once. If the prefix is
      # allowed to swallow row 12 or 13 the turn folds nothing and the transcript
      # renders three flat rows instead of "+2 previous" plus the active row.
      all = mixed_transcript()

      cache =
        Enum.reduce(1..(length(all) - 1), ChatLive.empty_grouping_cache(), fn k, cache ->
          {_items, cache} = ChatLive.regroup(Enum.take(all, k), cache)
          cache
        end)

      {items, _cache} = ChatLive.regroup(all, cache)

      assert Enum.any?(items, &match?({:running_fold, 2, _label, _hidden, _visible}, &1)),
             "the running turn must still collapse to one +2 control, got: #{inspect(items)}"

      assert items == from_scratch(all)
    end

    test "a row rewritten in place (a tool_result landing) invalidates the prefix" do
      # Writes are not only appends: a tool-result merge rewrites an EXISTING row.
      # The memo must miss rather than serve a stale prefix.
      all = mixed_transcript()
      {_items, cache} = ChatLive.regroup(all, ChatLive.empty_grouping_cache())

      merged = List.replace_at(all, 1, %{settled_tool(2, 1) | output: "landed later"})
      {items, _cache} = ChatLive.regroup(merged, cache)

      assert items == from_scratch(merged)
    end

    test "a spawn appended after its orphan child adopts it, prefix or not" do
      # `group_agent_rows/1` buckets by ID match, not adjacency, so a LATER spawn
      # can change how an EARLIER row groups. The guard must catch that.
      orphan = Map.merge(settled_tool(2, 1), %{parent_tool_use_id: "late-spawn"})

      before = [user(1), orphan, assistant(3)]
      {_items, cache} = ChatLive.regroup(before, ChatLive.empty_grouping_cache())

      after_spawn =
        before ++ [Map.merge(settled_tool(4, 2), %{spawn?: true, tool_use_id: "late-spawn"})]

      {items, _cache} = ChatLive.regroup(after_spawn, cache)

      assert items == from_scratch(after_spawn)
      assert Enum.any?(items, &match?({:agent, _spawn, [_child]}, &1))
    end
  end
end
