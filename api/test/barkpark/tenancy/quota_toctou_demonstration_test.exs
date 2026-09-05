defmodule Barkpark.Tenancy.QuotaToctouDemonstrationTest do
  @moduledoc """
  THIS FILE ASSERTS THE CURRENT, BROKEN BEHAVIOUR — it is a DEMONSTRATION of a
  live count-then-compare (TOCTOU) defect in the per-workspace document quota,
  NOT a regression guard, and when the invariant is finally pushed into the
  database EVERY over-admission assertion here MUST BE INVERTED (each
  `assert final == @cap - 1 + N` becomes `assert final == @cap`, and the
  admitted counts collapse to the headroom) rather than deleted.

  ## The defect, stated concretely

  `Barkpark.Tenancy.Quota.within_quota?/1` is `usage(id) < quota`, where
  `usage/1` is a live `Repo.aggregate(:count)` over `documents`.
  `BarkparkWeb.Plugs.RequireWithinQuota` calls `Quota.check/1` exactly ONCE per
  request and HALTS BEFORE the controller runs. The quota-relevant write then
  happens later, in a DIFFERENT transaction in a DIFFERENT module —
  `Content.Mutations.apply_mutations/3` opens its own `Repo.transaction`, and
  `Media.upload/3` does a bare `Repo.insert` with no transaction at all.

  Two processes, precise instruction order, cap 10 with 9 documents already
  committed (headroom 1):

      P1: SELECT count(*) ... -> 9    (9 < 10, admitted)
      P2: SELECT count(*) ... -> 9    (9 < 10, admitted — P1 has not written yet)
      P1: INSERT document             -> count 10
      P2: INSERT document             -> count 11   <-- OVER THE CAP

  The read takes no lock and the compare happens in application memory, so
  nothing confined to `quota.ex` can be atomic against a write that is not in
  the scope of the check. That is why this wave ships NO fix there: a narrowed
  window would still be fail-open while being believed fixed. The fix locus is
  the database — see the ranked costed menu on task `acpc-bl-quota-toctou`.

  ## The four legs

    1. STAGED — the load-bearing one. The interleaving above, made explicit for
       8 callers. Deterministic; needs no scheduler luck.
    2. CONCURRENT — the same fan-out released from a barrier, showing the staged
       ordering arises naturally under ordinary contention. It asserts
       OVER-ADMISSION (`admitted > 1`, against leg 3's pinned sequential 1)
       rather than an exact count: it is the only leg whose number depends on
       scheduling, and the exact count is leg 1's deterministic job.
    3. SEQUENTIAL CONTROL — the SAME code path driven one caller at a time
       admits exactly the headroom. Without this leg the demo could not
       distinguish "the race is real" from "the gate is simply broken".
    4. BATCH — the overshoot is bounded by the caller-chosen BATCH SIZE, not by
       the concurrency factor: one single-process request that passes one
       `Quota.check/1` may then create N documents. Zero flakiness, and it
       SURVIVES any fix to the race — an atomic `within_quota?` that still
       answers "room for one" before an unbounded batch is still fail-open.

       SCOPE NOTE (`acpc-bl-quota-batch-overshoot-unbounded`): the HTTP DOOR is
       now fenced — `RequireWithinQuota` counts the request's room-consuming ops
       and asks `Quota.check(ws, needed)`, and caps `length(mutations)` at 1000.
       Leg 4 deliberately still calls `Quota.check/1` (room for ONE) and
       `Content.apply_mutations/3` DIRECTLY, so it keeps measuring the ENGINE:
       `apply_mutations/3` itself remains quota-blind, and any future caller
       that reaches it without passing the plug reproduces this exactly. Do not
       "fix" this leg by routing it through the plug — that would delete the
       only guard on the engine's own fail-open.

  `async: false` — the concurrent leg fans out `Task.async` children that need
  the shared sandbox connection.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Tenancy.Quota

  @dataset "test"
  @cap 10
  @fanout 8

  setup do
    ws = create_workspace!()
    project = create_project!(ws)
    {:ok, ws} = Quota.set_quota(ws, @cap)
    %{ws: ws, project: project}
  end

  # One document write, exactly as the controller would perform it AFTER the
  # plug has already admitted the request.
  defp write!(ws, project, label) do
    {:ok, _doc} =
      create_document_in!(ws, project, "post", %{"title" => "toctou #{label}"}, @dataset)

    :written
  end

  # Seed `n` committed documents so the workspace sits at a known usage.
  defp seed!(ws, project, n) do
    Enum.each(1..n//1, &write!(ws, project, "seed-#{&1}"))
  end

  defp usage(ws), do: Quota.usage(ws.id)

  # The full request shape: check first, write only if admitted.
  defp check_then_write(ws, project, label) do
    case Quota.check(ws) do
      :ok ->
        write!(ws, project, label)
        :admitted

      {:error, reason} ->
        reason
    end
  end

  describe "leg 1 — STAGED: the interleaving written out, no scheduler luck" do
    test "8 callers all observe usage 9 < quota 10, then all write: 8 admitted, final 17",
         %{ws: ws, project: project} do
      seed!(ws, project, @cap - 1)

      assert usage(ws) == @cap - 1,
             "the fixture must park the workspace one document below its cap, " <>
               "otherwise the staged interleaving proves nothing"

      # TIME OF CHECK — every caller runs the plug's decision before any of them
      # has written. This is exactly what RequireWithinQuota does: once, per
      # request, in a transaction that has already ended by the time the
      # controller writes.
      decisions = Enum.map(1..@fanout, fn _ -> Quota.check(ws) end)

      assert Enum.all?(decisions, &(&1 == :ok)),
             "DEMONSTRATION (current broken behaviour): all #{@fanout} callers must be " <>
               "admitted off the SAME observed usage of #{@cap - 1}; got #{inspect(decisions)}"

      # TIME OF USE — the writes land afterwards, each in its own transaction.
      Enum.each(1..@fanout, &write!(ws, project, "staged-#{&1}"))

      final = usage(ws)

      assert final == @cap - 1 + @fanout,
             "DEMONSTRATION (current broken behaviour): the count-then-compare quota admits " <>
               "every caller that read the pre-write count, so the workspace ends at " <>
               "#{@cap - 1 + @fanout} documents against a cap of #{@cap}. When the invariant " <>
               "is pushed into the database this assertion MUST be inverted to " <>
               "`final == #{@cap}`. Got #{final}."

      assert final > @cap,
             "the whole point of this file: the cap of #{@cap} was exceeded (#{final})"
    end
  end

  describe "leg 2 — CONCURRENT: the staged ordering arises naturally" do
    test "a barrier-released fan-out reproduces 8 admitted / final 17",
         %{ws: ws, project: project} do
      seed!(ws, project, @cap - 1)

      parent = self()

      tasks =
        for i <- 1..@fanout do
          Task.async(fn ->
            # Barrier: every caller is spawned and waiting before ANY of them
            # runs the check, so the checks contend rather than trickle.
            send(parent, {:ready, self()})

            receive do
              :go -> :ok
            after
              5_000 -> exit(:barrier_never_released)
            end

            check_then_write(ws, project, "concurrent-#{i}")
          end)
        end

      Enum.each(1..@fanout, fn _ ->
        assert_receive {:ready, _pid}, 5_000
      end)

      Enum.each(tasks, &send(&1.pid, :go))

      outcomes = Task.await_many(tasks, 30_000)
      admitted = Enum.count(outcomes, &(&1 == :admitted))
      final = usage(ws)

      # The CLAIM of this leg is over-admission arising naturally, not a
      # particular count: the exact `admitted == @fanout` figure is leg 1's,
      # where it is staged and needs no scheduler luck. Asserting the exact
      # count HERE would make the file's only scheduling-dependent number
      # load-bearing, and a partial serialisation on a starved runner would red
      # a file that asserts BROKEN behaviour — the most confusing red there is.
      # Measured by the reviewer: 26 consecutive clean runs under
      # `ELIXIR_ERL_OPTIONS="+S 1" --max-cases 1`, plus the builder's ~13 at 10
      # schedulers, and `admitted` was the full fan-out every time. Bounded at
      # `> 1` because leg 3 pins the sequential answer at EXACTLY 1, so any
      # value above it is over-admission and nothing else.
      assert admitted > 1,
             "DEMONSTRATION (current broken behaviour): concurrent callers read the SAME " <>
               "pre-write count and are all admitted, so more than the headroom (1, pinned " <>
               "by leg 3) must get through; got #{admitted} of #{@fanout} " <>
               "(#{inspect(outcomes)}). When the invariant moves into the database this " <>
               "MUST be inverted to `admitted == 1`."

      assert final > @cap,
             "DEMONSTRATION (current broken behaviour): concurrent callers overshoot the cap " <>
               "of #{@cap}; got #{final}. Invert to `final == #{@cap}` when fixed."

      assert final == @cap - 1 + admitted,
             "every admitted caller must have written exactly once — final #{final} does not " <>
               "equal the seeded #{@cap - 1} plus the #{admitted} admitted writes, so this " <>
               "leg is measuring something other than the quota gate"
    end
  end

  describe "leg 3 — SEQUENTIAL CONTROL: the harness is not vacuous" do
    test "the SAME path driven one caller at a time admits exactly the headroom and denies 7",
         %{ws: ws, project: project} do
      seed!(ws, project, @cap - 1)

      outcomes =
        Enum.map(1..@fanout, fn i -> check_then_write(ws, project, "sequential-#{i}") end)

      admitted = Enum.count(outcomes, &(&1 == :admitted))
      denied = Enum.count(outcomes, &(&1 == :quota_exceeded))

      assert admitted == 1,
             "CONTROL: driven sequentially the gate is correct — exactly the headroom (1) is " <>
               "admitted. Got #{admitted} (#{inspect(outcomes)}). If this ever exceeds 1 the " <>
               "gate is simply broken and legs 1-2 prove nothing about a RACE."

      assert denied == @fanout - 1,
             "CONTROL: the remaining #{@fanout - 1} callers must be denied :quota_exceeded; " <>
               "got #{denied} (#{inspect(outcomes)})"

      assert usage(ws) == @cap,
             "CONTROL: sequentially the workspace stops exactly at its cap of #{@cap}; " <>
               "got #{usage(ws)}. This is the behaviour legs 1, 2 and 4 depart from."
    end
  end

  describe "leg 4 — BATCH: the overshoot is bounded by the batch size, not the concurrency" do
    @batch 25

    test "one process, one :ok check, then a #{@batch}-document batch overshoots by #{@batch - 1}",
         %{ws: ws, project: project} do
      seed!(ws, project, @cap - 1)

      assert Quota.check(ws) == :ok,
             "the single gate call the plug makes must admit this request (headroom 1) — " <>
               "the batch that follows is never re-checked"

      mutations =
        for i <- 1..@batch do
          %{
            "create" => %{
              "_type" => "post",
              "_id" => "quota-batch-#{System.unique_integer([:positive])}-#{i}",
              "title" => "batch #{i}"
            }
          }
        end

      assert {:ok, {_tx_id, results}} =
               Content.apply_mutations(mutations, @dataset,
                 workspace_id: ws.id,
                 project_id: project.id,
                 source: :api
               )

      assert length(results) == @batch,
             "the whole batch must be written by the single transaction that one " <>
               "`Quota.check/1` admitted; got #{length(results)} results"

      final = usage(ws)

      assert final == @cap - 1 + @batch,
             "DEMONSTRATION (current broken behaviour): the request passed ONE quota check " <>
               "reporting room for ONE document and then wrote #{@batch}, so the overshoot is " <>
               "the CALLER-CHOSEN BATCH SIZE minus the headroom (#{@batch - 1}), not the " <>
               "concurrency factor. Final #{final} against a cap of #{@cap}. This leg survives " <>
               "any fix to the race: an atomic `within_quota?` that still answers \"room for " <>
               "one\" before an unbounded batch is still fail-open. Invert to " <>
               "`final == #{@cap}` only when the invariant lives in the database."

      assert final - @cap == @batch - 1,
             "the overshoot above the cap must be exactly #{@batch - 1}; got #{final - @cap}"
    end
  end
end
