defmodule Barkpark.Plugins.OnixEdit.Export.StatusPillTest do
  @moduledoc """
  Phase 8 WI5 — exhaustive guard against the Phase 7 drift where two
  separate copies of the pill-bucket mapping lived in `BookEditor` and
  `BokbasenLive`. The 5-bucket palette over 9 lifecycle states is now
  defined exactly once in `Barkpark.Plugins.OnixEdit.Export.StatusPill`;
  this module pins both `color_class/1` and `label/1` for every state
  the worker can persist plus the `nil` / unknown fallbacks.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Plugins.OnixEdit.Export.StatusPill

  describe "color_class/1" do
    test "gray bucket — :pending and :staging" do
      for state <- ["pending", "staging"] do
        assert StatusPill.color_class(state) == "bp-pill-gray"
        assert StatusPill.color_class(String.to_atom(state)) == "bp-pill-gray"
      end
    end

    test "blue bucket — :staged and :polling" do
      for state <- ["staged", "polling"] do
        assert StatusPill.color_class(state) == "bp-pill-blue"
        assert StatusPill.color_class(String.to_atom(state)) == "bp-pill-blue"
      end
    end

    test "green bucket — :accepted" do
      assert StatusPill.color_class("accepted") == "bp-pill-green"
      assert StatusPill.color_class(:accepted) == "bp-pill-green"
    end

    test "red bucket — :rejected" do
      assert StatusPill.color_class("rejected") == "bp-pill-red"
      assert StatusPill.color_class(:rejected) == "bp-pill-red"
    end

    test "orange bucket — :failed, :cancelled, :cannot_cancel" do
      for state <- ["failed", "cancelled", "cannot_cancel"] do
        assert StatusPill.color_class(state) == "bp-pill-orange"
        assert StatusPill.color_class(String.to_atom(state)) == "bp-pill-orange"
      end
    end

    test "nil falls back to gray" do
      assert StatusPill.color_class(nil) == "bp-pill-gray"
    end

    test "unknown atom or string falls back to gray" do
      assert StatusPill.color_class(:something_else) == "bp-pill-gray"
      assert StatusPill.color_class("not-a-real-state") == "bp-pill-gray"
      assert StatusPill.color_class("") == "bp-pill-gray"
    end
  end

  describe "label/1" do
    test "labels are space-separated and capitalised" do
      assert StatusPill.label("pending") == "Pending"
      assert StatusPill.label("staging") == "Staging"
      assert StatusPill.label("staged") == "Staged"
      assert StatusPill.label("polling") == "Polling"
      assert StatusPill.label("accepted") == "Accepted"
      assert StatusPill.label("rejected") == "Rejected"
      assert StatusPill.label("failed") == "Failed"
      assert StatusPill.label("cancelled") == "Cancelled"
      assert StatusPill.label("cannot_cancel") == "Cannot cancel"
    end

    test "atom inputs are accepted and labelled identically to binaries" do
      for state <- [
            :pending,
            :staging,
            :staged,
            :polling,
            :accepted,
            :rejected,
            :failed,
            :cancelled,
            :cannot_cancel
          ] do
        assert StatusPill.label(state) == StatusPill.label(Atom.to_string(state))
      end
    end

    test "nil → empty string (caller skips render)" do
      assert StatusPill.label(nil) == ""
    end

    test "unknown atom is humanised the same way as a known one" do
      # The helper does not distinguish "known" from "unknown" labels —
      # both go through underscore-replace + capitalise. The bucket
      # mapping in `color_class/1` is the gate; `label/1` is purely
      # cosmetic.
      assert StatusPill.label(:never_heard_of_it) == "Never heard of it"
    end

    test "empty string → empty string" do
      assert StatusPill.label("") == ""
    end
  end
end
