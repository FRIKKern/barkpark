defmodule Barkpark.Tasks.DispatchabilityTest do
  @moduledoc """
  task-52f4f3aff99c64d5 — `bp task ready` handed out `task-fb4fb869490b4213`,
  a 359-child epic seal, as a PRIORITY 0 slice. Nothing in the ready card said
  it was not work.

  This pins the RULE. The rendered card is pinned next door in
  `BarkparkWeb.TasksController.BriefDispatchMarkerTest`, which quotes both
  cards side by side.

  MUTATION PROOF (both arms recorded on the task):

    * delete the `live > 0` clause so every parent answers `"undecided"` —
      "a parent with live children is DELEGATED" reds.
    * widen the leaf clause to `total >= 0` (i.e. classify everything) —
      "a leaf is not classified at all" reds, which is the negative arm.

  The rule reads ONLY the parent edge. It is not a list of known umbrella ids
  and it never looks at a title or a criterion — measured on a live 1,000-row
  ready page, a case-insensitive `seal` over criterion text matches 23 rows
  and most are ordinary slices about `seal-predicate.mjs` / `tooling/grip/seal.mjs`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Dispatchability

  describe "classify/2 — the positive arm" do
    test "a parent with live children is DELEGATED, at any magnitude" do
      # task-fb4fb869490b4213's real shape, read from the live ledger
      # 2026-09-07: 359 children, 71 of them not done/cancelled.
      assert Dispatchability.classify(359, 71) == "delegated"

      # and the smallest possible one — the rule is not thresholded, because a
      # threshold is a number nobody could defend.
      assert Dispatchability.classify(1, 1) == "delegated"
    end
  end

  describe "classify/2 — the refusal" do
    test "children that are ALL terminal are UNDECIDED, never silently dispatchable" do
      # chat-local-cloud-context-w3 on the same live page: 3 children, 3 done,
      # 1 of its own 3 criteria met. That is equally a seal-ready epic and a
      # row with real residual work, and the difference lives in prose this
      # rule does not read. Saying so is the point.
      assert Dispatchability.classify(3, 0) == "undecided"
      assert Dispatchability.classify(359, 0) == "undecided"
    end
  end

  describe "classify/2 — the negative arm" do
    test "a leaf is not classified at all" do
      refute Dispatchability.classify(0, 0)
      # A leaf stays a leaf even if a caller hands it a nonsense live count.
      refute Dispatchability.classify(0, 4)
    end

    test "an unmeasured or malformed count never invents a class" do
      refute Dispatchability.classify(nil, nil)
      refute Dispatchability.classify(nil, 7)
      refute Dispatchability.classify(-1, 3)
      refute Dispatchability.classify("359", 71)
    end
  end

  describe "terminal_statuses/0" do
    test "is exactly done|cancelled — everything else, absent included, is live" do
      assert Dispatchability.terminal_statuses() == ["done", "cancelled"]

      # The claimable set the queue admits must be disjoint from terminal, or
      # a live child would be counted dead and its parent read seal-ready.
      for status <- Barkpark.Tasks.Validation.claimable_statuses() do
        refute status in Dispatchability.terminal_statuses()
      end

      # Every non-terminal lifecycle value is live by construction.
      live =
        Barkpark.Tasks.Validation.lifecycle_statuses() --
          Dispatchability.terminal_statuses()

      assert Enum.sort(live) ==
               Enum.sort(~w(open in_progress blocked considering researching))
    end
  end
end
