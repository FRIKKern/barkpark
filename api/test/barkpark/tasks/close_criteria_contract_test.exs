defmodule Barkpark.Tasks.CloseCriteriaContractTest do
  @moduledoc """
  The close CRITERIA input contract, pinned at the two layers that can drift
  apart — the parser that enforces it and the manifest that documents it.

  gh-2314's live half: `bp task get` prints acceptance criteria as
  `{"criterion", "met", "evidence"}` and the close parser only accepted
  `{"index", "met", "evidence"}`. An agent that pasted the rubric it had just
  read got a 400 and — per the row — reached for a direct document mutation
  instead. So the contract now admits BOTH dialects, and this file asserts:

    1. `Params.parse_criteria/1` accepts each dialect, refuses a MIXED list, and
       refuses a text-keyed met-flip with no evidence — all before any document
       is read.
    2. The served manifest's `task close --set` summary teaches the SAME shapes
       and names the SAME refusal tokens the server can actually emit — proved
       by looking each token up in `Params.criteria_hint/2` rather than by
       trusting the prose.

  Pure: no app, no DB. The transactional half (text→index resolution,
  `criterion_not_found` / `criterion_ambiguous`, atomicity) lives in
  `close_test.exs` and `tasks_controller_test.exs`, which have a document.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Tasks
  alias BarkparkWeb.TasksController.Params

  describe "parse_criteria/1 — the two dialects" do
    test "an indexed entry is unchanged: guard optional here, enforced at merge time" do
      assert {:ok, [%{"index" => 0, "met" => true, "evidence" => "PR #1", "criterion" => "A"}]} =
               Params.parse_criteria([
                 %{"index" => 0, "met" => true, "evidence" => "PR #1", "criterion" => "A"}
               ])

      # An index with no text still PARSES — `merge_criteria` is what refuses it
      # (`:criterion_text_required`), so the refusal covers every write path and
      # not just the HTTP one.
      assert {:ok, [%{"index" => 3, "met" => true}]} =
               Params.parse_criteria([%{"index" => 3, "met" => true}])
    end

    test "a text-keyed rubric row parses with NO index — that is the whole point" do
      assert {:ok, [%{"criterion" => "the rubric shape is accepted", "met" => true} = entry]} =
               Params.parse_criteria([
                 %{
                   "criterion" => "the rubric shape is accepted",
                   "met" => true,
                   "evidence" => "PR #14400"
                 }
               ])

      assert entry["evidence"] == "PR #14400"
      refute Map.has_key?(entry, "index"), "the parser must not invent an index"
    end

    test "a text-keyed met-flip with absent, empty, or blank evidence is refused" do
      for evidence <- [nil, "", "   "] do
        entry =
          %{"criterion" => "unproven", "met" => true}
          |> then(fn e -> if evidence, do: Map.put(e, "evidence", evidence), else: e end)

        assert {:error, :invalid_criteria, msg} = Params.parse_criteria([entry])
        assert msg =~ "evidence"
      end

      # met=false needs no evidence — an honest unmet row costs nothing to send,
      # which is what makes pasting the whole rubric back possible.
      assert {:ok, [%{"criterion" => "unproven", "met" => false}]} =
               Params.parse_criteria([%{"criterion" => "unproven", "met" => false}])
    end

    test "one command, one dialect: a mixed list is refused" do
      assert {:error, :invalid_criteria, msg} =
               Params.parse_criteria([
                 %{"index" => 0, "met" => false},
                 %{"criterion" => "B", "met" => false}
               ])

      assert msg =~ "mixes two shapes"

      # An entry carrying BOTH keys is the indexed dialect with its mandatory
      # guard — not a mix, and not refused.
      assert {:ok, [_, _]} =
               Params.parse_criteria([
                 %{"index" => 0, "criterion" => "A", "met" => true, "evidence" => "x"},
                 %{"index" => 1, "met" => false}
               ])
    end

    test "an entry naming its row by neither key is refused, and says both ways in" do
      assert {:error, :invalid_criteria, msg} = Params.parse_criteria([%{"met" => true}])
      assert msg =~ "index"
      assert msg =~ "criterion"

      # An empty criterion is no key at all (the same reasoning as `guarded?/1`
      # in Tasks.Internal: a guard only guards when it has words).
      assert {:error, :invalid_criteria, _} =
               Params.parse_criteria([%{"criterion" => "", "met" => false}])
    end
  end

  describe "manifest help ↔ server behaviour parity" do
    setup do
      close = Enum.find(Tasks.cli_commands(), &(&1[:id] == "task.close"))

      assert close, "the tasks plugin must declare the task.close verb"

      set = Enum.find(close[:flags] || [], &(&1[:name] == "set"))
      assert set, "task close must declare the --set flag"

      %{summary: set[:summary]}
    end

    test "the --set help teaches BOTH accepted shapes", %{summary: summary} do
      # The indexed dialect, with its text guard.
      assert summary =~ ~s|"index":0|
      assert summary =~ "criterion_text_required"

      # The rubric dialect: an example with a criterion and no index at all.
      assert summary =~ ~s|{\"criterion\":\"<the exact stored wording>\"|
      assert summary =~ "ONE SHAPE PER COMMAND"
    end

    test "every refusal the help names is a refusal the server can actually emit",
         %{summary: summary} do
      # Each token below is only allowed in the help because `criteria_hint/2`
      # answers for it — i.e. the server has a real reason by that name with a
      # message of its own. A token the server cannot produce would be a lie
      # that no other test could catch.
      for reason <- [
            :criterion_text_required,
            :criteria_mismatch,
            :criterion_not_found,
            :criterion_ambiguous
          ] do
        token = Atom.to_string(reason)

        assert summary =~ token,
               "the --set help must name the #{token} refusal"

        assert is_binary(Params.criteria_hint(reason, :close)),
               "#{token} is documented in the manifest but has no server-side hint"
      end
    end

    test "the text-keyed hints teach the fix, not just the refusal" do
      # not_found → copy the wording verbatim. ambiguous → use the indexed shape.
      assert Params.criteria_hint(:criterion_not_found, :close) =~ "EXACT"
      assert Params.criteria_hint(:criterion_ambiguous, :close) =~ ~s|"index"|
    end
  end
end
