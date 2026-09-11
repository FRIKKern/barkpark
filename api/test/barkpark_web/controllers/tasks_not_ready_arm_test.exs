defmodule BarkparkWeb.TasksNotReadyArmTest do
  @moduledoc """
  A STALE CLAIM MAP IS NOT A HOLDER (task-4753f80a2ec47d03).

  `bp task stage <id> open` moves a row and leaves the claim map behind, and a
  lapsed lease is never swept from the map either — so a `claim.worker` proves
  only that somebody ONCE claimed this row, not that anybody holds it now.

  THE PAIRED REFUSALS ARE THE WHOLE ARGUMENT, and this file is that pair as a
  test. Measured on the live server 2026-09-08: two `cancelled` rows, same verb,
  same session, differing ONLY in whose name sat in a stale map.

    * the row whose map named the CALLER got the correct, permanent reason
    * the row whose map named ANOTHER lane got "held by lead-instruments —
      nobody else can claim it", on a claim that had expired SIX DAYS earlier

  One difference, opposite messages. Neither arm alone shows that the ordering
  is the variable, which is why both are pinned here.

  THE OLD MESSAGE WAS WRONG THREE WAYS, ascending in harm: the row was not held
  (8,966 minutes against a 45-minute TTL); it hid the real blocker, a terminal
  lifecycle, behind a transient-sounding one; and ITS REMEDY WOULD ALSO FAIL —
  "re-claim with it VERBATIM" is refused on a terminal row regardless of who
  runs it. Same signature as the `stale_claim` case in this file family: a
  refusal that names the wrong cause AND prescribes a remedy that cannot work.

  AND IT TEACHES A WRONG SOCIAL MOVE, WHICH NO OTHER ARM DOES: it sends a lane
  to ask another lane for a row nobody holds.

  THE FIX FAILS CLOSED. `claim_lease_live?/1` can only ever downgrade somebody
  from holder to residue, so an unparseable or absent timestamp is treated as
  LIVE — a parse bug here must never hand one lane another lane's row. The
  fail-closed arms below are the ones that catch a fix written to fail open.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content.Document
  alias BarkparkWeb.TasksController

  @lease_seconds Application.compile_env(:barkpark, :task_lease_ttl_seconds, 2700)

  defp ago(seconds),
    do: DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()

  defp doc(content), do: %Document{content: content}

  defp row(opts) do
    base = %{"lifecycle_status" => Keyword.get(opts, :status, "open")}

    case Keyword.get(opts, :claim) do
      {worker, ts} ->
        Map.put(base, "claim", %{"worker" => worker, "epoch" => 1, "ts_iso" => ts})

      _ ->
        base
    end
  end

  describe "the paired refusals — one difference, and it must not flip the reason" do
    test "a terminal row whose stale map names the CALLER reports the lifecycle" do
      content = row(status: "cancelled", claim: {"me", ago(@lease_seconds * 200)})
      out = TasksController.not_ready_arm(doc(content), "me")

      assert out.arm == "not_claimable_status"
      assert out.message =~ "lifecycle_status is \"cancelled\""
    end

    test "a terminal row whose stale map names ANOTHER worker reports the SAME lifecycle" do
      content = row(status: "cancelled", claim: {"lead-instruments", ago(@lease_seconds * 200)})
      out = TasksController.not_ready_arm(doc(content), "me")

      # BEFORE THE FIX this returned arm "held_by_other" with a message opening
      # "held by lead-instruments — nobody else can claim it", hiding the
      # permanent blocker behind a name. This is the arm that reds if it returns.
      assert out.arm == "not_claimable_status",
             "a six-day-dead claim map must not mask a terminal lifecycle, got: #{inspect(out)}"

      assert out.message =~ "lifecycle_status is \"cancelled\""
    end
  end

  describe "the message names the residue AND the blocker" do
    test "the stale map is reported as residue, with its age and the lease it outlived" do
      content = row(status: "done", claim: {"lead-instruments", ago(@lease_seconds * 200)})
      out = TasksController.not_ready_arm(doc(content), "me")

      assert out.stale_claim_map == true
      assert out.message =~ "STALE claim map naming lead-instruments"
      assert out.message =~ "nobody holds this row and there is no one to ask"
      assert out.message =~ "minute lease"

      # The permanent blocker must survive the addition: a fix that stops saying
      # "held by" and leaves the caller without the lifecycle reason has MOVED
      # the confusion rather than removed it.
      assert out.message =~ "lifecycle_status is \"done\""
    end

    test "a row with no stale map says nothing about one" do
      out = TasksController.not_ready_arm(doc(row(status: "done")), "me")
      assert out.stale_claim_map == false
      refute out.message =~ "STALE claim map"
    end
  end

  describe "a genuinely held row still says so" do
    test "a LIVE claim by another worker still returns held_by_other, wording unchanged" do
      content = row(status: "open", claim: {"worker-A", ago(60)})
      out = TasksController.not_ready_arm(doc(content), "me")

      assert out.arm == "held_by_other"
      assert out.held_by == "worker-A"
      assert out.message =~ "held by worker-A — nobody else can claim it"
    end

    test "a claim just INSIDE the lease is live; just OUTSIDE it is residue" do
      inside = row(status: "open", claim: {"worker-A", ago(@lease_seconds - 60)})
      assert TasksController.not_ready_arm(doc(inside), "me").arm == "held_by_other"

      outside = row(status: "open", claim: {"worker-A", ago(@lease_seconds + 60)})
      out = TasksController.not_ready_arm(doc(outside), "me")

      refute out.arm == "held_by_other",
             "a lease expired by 60s must not read as a holder, got: #{inspect(out)}"
    end
  end

  describe "liveness fails CLOSED — it may only downgrade a holder, never invent one" do
    test "an unparseable ts_iso is treated as LIVE" do
      content = row(status: "open", claim: {"worker-A", "not-a-timestamp"})
      out = TasksController.not_ready_arm(doc(content), "me")

      assert out.arm == "held_by_other",
             "an unparseable timestamp must keep the protective behaviour — a parse bug " <>
               "must never hand one lane another lane's row"
    end

    test "a claim with NO ts_iso is treated as LIVE" do
      content = %{"lifecycle_status" => "open", "claim" => %{"worker" => "worker-A"}}
      assert TasksController.not_ready_arm(doc(content), "me").arm == "held_by_other"
    end
  end
end
