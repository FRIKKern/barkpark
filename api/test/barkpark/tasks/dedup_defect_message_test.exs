defmodule Barkpark.Tasks.DedupDefectMessageTest do
  @moduledoc """
  The task dedup gate's rescue used to launder a code DEFECT into an OUTAGE.

  Every exception raised inside `fetch_candidates/2` became
  `{:degraded, reason_phrase(e, timeout)}`, logged at `:warning`, and
  `degraded_message/1` then told the filer to "Retry, or resend with
  content.dedup_bypass: true" — advice that is correct for a slow database and
  actively harmful for a bug in Barkpark: it teaches the filer to disable the
  duplicate gate permanently for a defect nobody will ever report.

  These tests drive BOTH classes through the real gate and pin the message, the
  remedy, the log LEVEL and the telemetry event for each.
  """
  # `async: true` IS LOAD-BEARING. `DataCase` puts the sandbox in SHARED mode for
  # an async: false case, and a shared connection is exactly what the bare-spawn
  # infra injector below borrows — under `async: false` that fetch SUCCEEDS and
  # every outage assertion reads `right: :ok` (observed: 4 vacuous failures).
  use Barkpark.DataCase, async: true

  import ExUnit.CaptureLog

  alias Barkpark.Tasks.Dedup

  @dataset "production"

  defp attrs(doc_id) do
    %{
      "doc_id" => doc_id,
      "title" => "Rate limiting the mutate controller",
      "content" => %{
        "kind" => "task",
        "description" => "the mutate controller has no rate limit at all"
      }
    }
  end

  # CODE fault injector, and an honest one: an INTEGER dataset is a contract
  # violation IN THIS MODULE — `maybe_filter_dataset/2` guards `is_binary`, so
  # the query build raises `FunctionClauseError` inside `fetch_candidates/2`,
  # which is precisely the class the split exists to name. The workspace id is a
  # real UUID so `candidate_workspace/1` resolves and the failure happens at the
  # scan, not at the scoping step (whose own degraded reason is a binary).
  defp code_class_refusal do
    Dedup.check_new_task("task", attrs("defect-probe"), 12_345, nil,
      workspace_id: Ecto.UUID.generate()
    )
  end

  # INFRA fault injector, copied from `dedup_wall_test.exs`: a BARE `spawn` owns
  # no ExUnit sandbox connection and cannot borrow one, so the first `Repo` call
  # inside it raises a `DBConnection` error at the real seam. `Task.async/1` and
  # `Sandbox.checkin/1` both look equivalent and are both vacuous here — they
  # let the fetch SUCCEED.
  defp infra_class_refusal do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      send(
        parent,
        {ref,
         Dedup.check_new_task("task", attrs("outage-probe"), @dataset, nil,
           workspace_id: Ecto.UUID.generate()
         )}
      )
    end)

    receive do
      {^ref, result} -> result
    after
      5_000 -> flunk("the un-sandboxed fetch never answered — the injector did not fire")
    end
  end

  describe "preconditions — both injectors reach the degraded path" do
    test "the code-class injector refuses, and refuses as a code error" do
      # Not `:ok` (gate passed), not `{:duplicate_task, _}` (gate ran): the only
      # shape that proves the rescue answered.
      assert {:error, {:dedup_unavailable, message}} = code_class_refusal()
      assert message =~ "FunctionClauseError", "the injected class is not the one we named"
    end

    test "the infra-class injector refuses, and NOT as a code error" do
      assert {:error, {:dedup_unavailable, message}} = infra_class_refusal()
      refute message =~ "FunctionClauseError"
      assert message =~ "DBConnection", "the injector raised something else entirely"
    end
  end

  describe "one door, two messages" do
    test "a code-class failure reads as a DEFECT; an infra one reads as an outage" do
      assert {:error, {:dedup_unavailable, defect}} = code_class_refusal()
      assert {:error, {:dedup_unavailable, outage}} = infra_class_refusal()

      # RED before the split: BOTH were "task dedup gate could not complete: the
      # backlog scan failed (<Mod>). … resend with content.dedup_bypass: true …"
      # — the module name in parentheses was the only difference.
      assert defect =~ "hit a DEFECT, not an outage"
      assert defect =~ "bug in Barkpark (FunctionClauseError)"
      refute outage =~ "DEFECT"
      assert outage =~ "could not complete: the backlog scan"
      refute defect == outage

      # Both are still fail-CLOSED refusals — the split changed what the
      # sentence SAYS, never whether the create was let through.
      assert defect =~ "REFUSED rather than filed unchecked"
      assert outage =~ "REFUSED rather than filed unchecked"
      assert defect =~ "no duplicate check ran"
      assert outage =~ "no duplicate check ran"
    end

    test "the DEFECT message never offers content.dedup_bypass; the outage message still does" do
      assert {:error, {:dedup_unavailable, defect}} = code_class_refusal()
      assert {:error, {:dedup_unavailable, outage}} = infra_class_refusal()

      # The bypass turns a bug into a permanently-disabled gate. Only the outage
      # arm may name it; `refute defect =~ "dedup_bypass"` is the whole point.
      refute defect =~ "dedup_bypass"
      assert outage =~ "content.dedup_bypass: true"
    end
  end

  describe "the log level is part of the message" do
    test "a code-class failure logs at :error with a DEFECT prefix" do
      # `level: :error` captures ONLY error-and-above, so a defect still logged
      # at :warning would leave this capture EMPTY — the level is asserted here,
      # not eyeballed.
      error_only = capture_log([level: :error], fn -> code_class_refusal() end)

      assert error_only =~ "Tasks.Dedup DEFECT (not an outage): candidate fetch failed"
      assert error_only =~ "FunctionClauseError"
    end

    test "an infra-class failure logs the degraded line at :warning" do
      # WHY THIS TEST MAKES NO ABSENCE CLAIM. `capture_log` mutes and
      # captures the whole Logger DEVICE, so under `async: true` a module
      # running beside this one can only ADD lines to what we read. Added lines
      # can only turn a `refute ... =~` red, which makes the absence claim a
      # flake whose cause lives in another file. A PRESENCE assert is sound
      # under exactly the same concurrency: a foreign line cannot make a
      # present line absent. (`async: true` is load-bearing here — see the
      # moduledoc: `async: false` shares the sandbox connection and the
      # bare-spawn infra injector then SUCCEEDS — so going synchronous is not
      # available as the remedy either.)
      #
      # The half this test used to claim by absence is not lost, it is claimed
      # SOUNDLY somewhere better: `refute outage =~ "DEFECT"` in "a code-class
      # failure reads as a DEFECT; an infra one reads as an outage" asserts it
      # against the RETURNED message, a process-local value no concurrent
      # module can write to.
      assert capture_log([level: :warning], fn -> infra_class_refusal() end) =~
               "Tasks.Dedup degraded: candidate fetch failed"
    end
  end

  describe "telemetry" do
    test "a code-class failure emits [:barkpark, :tasks, :dedup, :defect] with the exception" do
      handler = "tasks-dedup-defect-#{System.unique_integer([:positive])}"
      parent = self()

      :ok =
        :telemetry.attach(
          handler,
          [:barkpark, :tasks, :dedup, :defect],
          fn event, measurements, meta, _ ->
            send(parent, {:defect_event, event, measurements, meta})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, {:dedup_unavailable, _}} = code_class_refusal()

      assert_receive {:defect_event, [:barkpark, :tasks, :dedup, :defect], %{count: 1},
                      %{exception: FunctionClauseError, where: "candidate fetch failed"}}

      # The infra arm is an outage, not a defect: no event at all.
      assert {:error, {:dedup_unavailable, _}} = infra_class_refusal()
      refute_receive {:defect_event, _, _, _}, 100
    end
  end
end
