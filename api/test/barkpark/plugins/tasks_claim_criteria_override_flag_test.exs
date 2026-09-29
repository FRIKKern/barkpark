defmodule Barkpark.Plugins.TasksClaimCriteriaOverrideFlagTest do
  @moduledoc """
  The criteria-unstated refusal prints its own way through:

      To claim anyway, on the record: --set criteria_unstated_override="<why …>"

  The server honours that key (`tasks_controller.ex` reads it flat AND under
  `set`; `Tasks.Claim.override_reason/1` accepts it). The CLI did not: `bp` is
  manifest-driven, `task.claim` declared only `resources` and
  `observed_rail_rev`, and so `bp task claim <id> <w> --set
  criteria_unstated_override=… --yes` died with

      bp: unknown flag --set for task claim

  before a request was ever built. The server's own remedy was unreachable from
  the server's own CLI, and the rows it was written for — orphan drafts with no
  criteria, which cannot be claimed and therefore cannot be cancelled — stayed
  stuck.

  These tests bind the printed remedy to the manifest that has to serve it, so
  removing the declaration reds rather than silently re-stranding the rows.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Tasks
  alias BarkparkWeb.TasksController.Params

  defp claim_command do
    Enum.find(Tasks.cli_commands(), &(&1.id == "task.claim")) ||
      flunk("task.claim is absent from Tasks.cli_commands/0")
  end

  defp flag(cmd, name), do: Enum.find(cmd.flags, &(&1.name == name))

  describe "task.claim declares the flag its refusal advertises" do
    test "a `set` flag exists, repeatable, string-typed" do
      set = flag(claim_command(), "set")

      assert set,
             "task.claim declares no `set` flag, so `bp task claim … --set …` is refused by " <>
               "the CLI before any request is built"

      assert set.type == "string"
      assert set.repeatable == true
    end

    test "the `set` summary names criteria_unstated_override" do
      set = flag(claim_command(), "set")
      assert set.summary =~ "criteria_unstated_override"
    end

    test "every --set key the refusal message advertises is reachable through task.claim" do
      msg = Params.criteria_unstated_message("drafts.task-aa11e844afc01a63", "w-1")

      advertised =
        Regex.scan(~r/--set ([a-z_]+)=/, msg)
        |> Enum.map(fn [_, key] -> key end)
        |> Enum.uniq()

      # Control: the message really does advertise a --set key. An empty list
      # would make the assertion below vacuous.
      assert "criteria_unstated_override" in advertised

      set = flag(claim_command(), "set")

      assert set,
             "the refusal advertises #{inspect(advertised)} but task.claim declares no `set` flag"

      for key <- advertised do
        assert set.summary =~ key,
               "the refusal advertises --set #{key}= but task.claim's `set` flag never names it"
      end
    end

    test "the pre-existing claim flags are untouched" do
      cmd = claim_command()
      assert flag(cmd, "resources")
      assert flag(cmd, "observed_rail_rev")
    end
  end
end
