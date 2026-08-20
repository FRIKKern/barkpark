defmodule Barkpark.Plugins.Sheets.SessionUndoKeyCapTest do
  @moduledoc """
  Bound on DISTINCT `"user"` keys in the session undo/redo maps.

  `"user"` is client-supplied and unauthenticated on the :ingest tier
  (identity rides the op — see `OpsController`), so without a key cap N
  distinct user strings grow `map_size(state.undo)` to N: unbounded
  per-session GenServer memory an anonymous client controls. These locks
  prove the cap: at most 64 distinct users retained, LRU-evicted
  (the least-recently-TOUCHED user's undo AND redo stacks drop together,
  mirroring `ReplayRing`'s bounded evict-on-write cache), while the
  per-key depth cap (100) and the single-edit/batch-group recording
  behavior stay byte-identical.

  Offline on purpose: `Ops.record_undo/3` / `record_batch_undo/2` are
  pure state-map transforms — no DB, no GenServer, plain `ExUnit.Case`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.Session.Ops

  # Mirrors `@undo_user_cap` in `Session.Ops` — a ReplayRing-style module
  # constant, hardcoded here exactly like the depth-100 locks in
  # `SessionUndoTest` hardcode `@undo_depth`.
  @cap 64

  @inverse {:cell, 0, "A1", nil}

  defp state0, do: %{undo: %{}, redo: %{}}

  defp op(user),
    do: %{"op" => "set_cell", "tab" => 0, "ref" => "A1", "raw" => "x", "user" => user}

  defp user(n), do: "user-#{n}"

  defp push_users(state, users),
    do: Enum.reduce(users, state, &Ops.record_undo(&2, op(&1), @inverse))

  describe "distinct-user-key cap (the unbounded-growth lock)" do
    test "N distinct client-supplied users leave at most #{@cap} undo/redo keys" do
      state = push_users(state0(), Enum.map(1..200, &user/1))

      assert map_size(state.undo) <= @cap
      assert map_size(state.redo) <= @cap
    end

    test "the most-recently-touched users are the ones retained" do
      n = 200
      state = push_users(state0(), Enum.map(1..n, &user/1))

      # the newest @cap users survive …
      for i <- (n - @cap + 1)..n do
        assert Map.has_key?(state.undo, user(i)), "expected #{user(i)} retained"
      end

      # … the stalest are evicted, their stacks gone from BOTH maps
      for i <- 1..(n - @cap) do
        refute Map.has_key?(state.undo, user(i)), "expected #{user(i)} evicted from undo"
        refute Map.has_key?(state.redo, user(i)), "expected #{user(i)} evicted from redo"
      end
    end

    test "eviction is LRU (least-recently-TOUCHED), not insertion-order FIFO" do
      state = push_users(state0(), Enum.map(1..@cap, &user/1))

      # re-touch the oldest-inserted user, then overflow with a fresh one
      state = push_users(state, [user(1), user(@cap + 1)])

      assert map_size(state.undo) == @cap
      assert Map.has_key?(state.undo, user(1)), "re-touched user must survive"
      refute Map.has_key?(state.undo, user(2)), "least-recently-touched user is the evictee"
      assert Map.has_key?(state.undo, user(@cap + 1))
    end

    test "a re-push by an already-tracked user never evicts anyone" do
      state = push_users(state0(), Enum.map(1..@cap, &user/1))
      state = push_users(state, [user(5)])

      assert map_size(state.undo) == @cap
      for i <- 1..@cap, do: assert(Map.has_key?(state.undo, user(i)))
    end

    test "record_batch_undo rides the same cap" do
      state =
        Enum.reduce(1..200, state0(), fn i, st ->
          Ops.record_batch_undo(st, [{op(user(i)), @inverse}])
        end)

      assert map_size(state.undo) <= @cap
      assert map_size(state.redo) <= @cap
    end
  end

  describe "preserved behavior (regression locks)" do
    test "per-user depth stays capped at 100 entries under one key" do
      state = push_users(state0(), List.duplicate(user(1), 150))

      assert map_size(state.undo) == 1
      assert length(state.undo[user(1)]) == 100
    end

    test "a lone batch inverse is pushed BARE (single-edit lock)" do
      state = Ops.record_batch_undo(state0(), [{op(user(1)), @inverse}])

      assert state.undo[user(1)] == [@inverse]
    end

    test "a >=2-inverse batch pushes ONE {:group, …} entry in application order" do
      inv2 = {:cell, 0, "B2", nil}

      state =
        Ops.record_batch_undo(state0(), [{op(user(1)), @inverse}, {op(user(1)), inv2}])

      assert state.undo[user(1)] == [{:group, [@inverse, inv2]}]
    end
  end
end
