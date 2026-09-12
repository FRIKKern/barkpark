defmodule Barkpark.Tasks.CriteriaShapeSharedTest do
  @moduledoc """
  cdd-criteria-shape-gate — ONE predicate, BOTH doors, ONE fixture list.

  THE DEFECT THIS PINS is not "a door was too permissive". It is that TWO doors
  each carried their own `Enum.all?(list, &is_map/1)` under a message promising
  a `{criterion, met, evidence}` contract neither one checked. The plugin write
  gate (`Plugins.Tasks.eval_criteria/2`) and the document-write path
  (`Tasks.Validation.check_acceptance_criteria/2`) had the identical blind
  spot, which is how `%{"text" => "..."}` reached production six times.

  THE REASON THIS FILE EXISTS AT ALL, rather than two happy suites in two
  places. Two independently-tested copies of a shape rule is an UNLOCKED
  MIRROR: each copy is green, the pair drifts anyway, and nothing anywhere goes
  red when they disagree — the failure is in the RELATIONSHIP, and a test that
  only ever looks at one side cannot see it. So every arm below drives BOTH
  doors from the SAME `@bad_shapes` / `@good_shapes` module attributes. Adding
  a shape to one list arms both doors at once; a future edit that re-localises
  either door's predicate reds here the moment the two answers differ, because
  `both_doors_agree/1` asserts on the AGREEMENT, not on either verdict alone.

  DB-free on purpose: door 2 is a pure function, and door 1 is reached through
  the plugin's own `lifecycle_hooks/0` capture — the same fun the content
  writer invokes — so this pins the real call path without a repo.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Tasks.Validation

  # ── The shared fixtures. ONE list, both doors. ────────────────────────────

  # Shapes that MUST be refused. The first is the exact production shape from
  # the filing: a filer typed `text` where the contract says `criterion` and
  # got a clean 200 back six times.
  @bad_shapes [
    {"the production shape — `text` instead of `criterion`", [%{"text" => "ships the thing"}]},
    {"`text` plus a met flag, the drafts.screenscribe/bp-dataset shape",
     [%{"met" => false, "text" => "ships the thing"}]},
    {"an entry with no keys at all", [%{}]},
    {"a criterion that is not a string", [%{"criterion" => 42}]},
    {"a criterion that is the empty string", [%{"criterion" => ""}]},
    {"a criterion that is only whitespace", [%{"criterion" => "   "}]},
    {"a non-map entry", ["not a map"]},
    {"a non-boolean `met`", [%{"criterion" => "ships", "met" => "yes"}]},
    {"a non-string `evidence`", [%{"criterion" => "ships", "evidence" => ["a", "list"]}]},
    {"a clean entry followed by a dirty one", [%{"criterion" => "clean"}, %{"text" => "dirty"}]}
  ]

  # Shapes that MUST still save. A predicate that refuses everything also stops
  # the six recurring, and is the strictly worse bug — an unmet criterion has
  # no evidence yet, so enforcing the literal triple the old message promised
  # would refuse ordinary rows. Measured on the live corpus (2026-09-07): of
  # 36,287 criteria entries, 362 omit `evidence` and 40 omit `met`.
  @good_shapes [
    {"the full triple", [%{"criterion" => "ships", "met" => true, "evidence" => "PR #1"}]},
    {"a bare criterion, no met and no evidence", [%{"criterion" => "ships"}]},
    {"met false, evidence empty string",
     [%{"criterion" => "ships", "met" => false, "evidence" => ""}]},
    {"an explicit nil evidence", [%{"criterion" => "ships", "met" => true, "evidence" => nil}]},
    {"an explicit nil met", [%{"criterion" => "ships", "met" => nil}]},
    {"an interior newline (stampable, and 4 live rows carry one)",
     [%{"criterion" => "ships the thing\nand proves it"}]},
    {"unknown extra keys are none of this rule's business",
     [%{"criterion" => "ships", "owner" => "lead", "merge_gate" => true}]},
    {"atom keys", [%{criterion: "ships", met: false}]},
    {"an empty list", []},
    {"many well-formed entries",
     [%{"criterion" => "one", "met" => true}, %{"criterion" => "two", "met" => false}]}
  ]

  # ── The two doors, each driven through its REAL entry point. ──────────────

  # Door 2: the document-write path. `Content.create_document/4` and
  # `Content.upsert_document/4` call this before insert/update.
  defp door_validation(criteria) do
    case Validation.validate_task_content(%{
           "kind" => "task",
           "lifecycle_status" => "open",
           "acceptance_criteria" => criteria
         }) do
      :ok -> :accepted
      {:error, %{"acceptance_criteria" => [msg]}} -> {:refused, msg}
      {:error, other} -> {:refused_elsewhere, other}
    end
  end

  # Door 1: the plugin write gate, reached through the plugin's own
  # `lifecycle_hooks/0` — the same captured fun the content writer invokes, so
  # a change that unhooks the gate reds here too.
  defp door_plugin(criteria) do
    %{before_save: [gate | _]} = Barkpark.Plugins.Tasks.lifecycle_hooks()

    payload = %{
      doc: %{
        "type" => "task",
        "title" => "a title, so the title gate is not what refuses",
        "content" => %{"kind" => "task", "acceptance_criteria" => criteria}
      },
      prev_doc: %{title: "prior"}
    }

    case gate.(payload) do
      :ok -> :accepted
      {:halt, msg} -> {:refused, msg}
    end
  end

  # The agreement assertion. This is the arm that catches DRIFT: it fails when
  # the doors disagree, whichever way round, and it is the thing two separate
  # suites can never assert.
  defp both_doors_agree(criteria) do
    v = door_validation(criteria)
    p = door_plugin(criteria)

    assert elem_tag(v) == elem_tag(p),
           """
           THE TWO DOORS DISAGREED — this is the defect class, not a test nit.
             validation door: #{inspect(v)}
             plugin door:     #{inspect(p)}
           Both must call Validation.criteria_violation/1 and nothing else.
           """

    {v, p}
  end

  defp elem_tag(:accepted), do: :accepted
  defp elem_tag({tag, _}), do: tag

  # ── Arms ──────────────────────────────────────────────────────────────────

  describe "the shared predicate is the single source" do
    test "criteria_violation/1 is public and returns nil or a message" do
      assert Validation.criteria_violation([%{"criterion" => "ships"}]) == nil
      assert is_binary(Validation.criteria_violation([%{"text" => "ships"}]))
    end

    test "each door's verdict IS the shared predicate's verdict, on every fixture" do
      for {label, criteria} <- @bad_shapes ++ @good_shapes do
        shared = Validation.criteria_violation(criteria)
        {v, p} = both_doors_agree(criteria)

        expected = if is_nil(shared), do: :accepted, else: :refused

        assert elem_tag(v) == expected, "validation door diverged from the predicate on: #{label}"
        assert elem_tag(p) == expected, "plugin door diverged from the predicate on: #{label}"
      end
    end
  end

  describe "RED FIRST — the production shape is refused at BOTH doors" do
    test "%{\"text\" => ...} is refused, and the refusal names the keys it received" do
      criteria = [%{"text" => "the criterion I meant to write"}]

      {{:refused, vmsg}, {:refused, pmsg}} = both_doors_agree(criteria)

      for msg <- [vmsg, pmsg] do
        # It names the offending index, so the author knows which line.
        assert msg =~ "criterion 0"
        # It names the keys it ACTUALLY received — the whole failure mode is a
        # filer who typed the wrong key and got a 200 back.
        assert msg =~ ~s(keys received: "text")
        # It says WHY `criterion` matters, rather than restating the shape.
        assert msg =~ "CAS"
        assert msg =~ "can never close"
      end
    end

    test "every bad shape is refused at both doors" do
      for {label, criteria} <- @bad_shapes do
        # Bound first, asserted on a boolean. `assert pattern = expr, msg` never
        # reaches its message — the match raises MatchError before assert/2 runs
        # — and the label is the whole point when ten fixtures share one arm.
        {v, p} = both_doors_agree(criteria)

        assert {elem_tag(v), elem_tag(p)} == {:refused, :refused},
               "not refused at both doors: #{label} — got #{inspect(v)} / #{inspect(p)}"
      end
    end

    test "the message names the OFFENDING index, not a constant" do
      criteria = [%{"criterion" => "clean"}, %{"criterion" => "also clean"}, %{"text" => "dirty"}]
      {{:refused, vmsg}, {:refused, pmsg}} = both_doors_agree(criteria)

      for msg <- [vmsg, pmsg] do
        assert msg =~ "criterion 2"
        refute msg =~ "criterion 0"
      end
    end

    test "a bad `met` and a bad `evidence` each get their OWN message" do
      {{:refused, met_msg}, _} = both_doors_agree([%{"criterion" => "ships", "met" => "yes"}])
      assert met_msg =~ "non-boolean `met`"
      assert met_msg =~ "true, false, null, or absent"

      {{:refused, ev_msg}, _} =
        both_doors_agree([%{"criterion" => "ships", "evidence" => ["a"]}])

      assert ev_msg =~ "non-string `evidence`"
    end

    test "a non-map entry reports its index and value, not just \"a non-object entry\"" do
      {{:refused, vmsg}, {:refused, pmsg}} = both_doors_agree([%{"criterion" => "ok"}, 42])

      for msg <- [vmsg, pmsg] do
        assert msg =~ "criterion 1 is not an object"
        assert msg =~ "42"
      end
    end
  end

  describe "POSITIVE CONTROL — a predicate that refuses everything is the worse bug" do
    test "every good shape still saves at both doors" do
      for {label, criteria} <- @good_shapes do
        {v, p} = both_doors_agree(criteria)

        assert {v, p} == {:accepted, :accepted},
               "wrongly refused: #{label} — got #{inspect(v)} / #{inspect(p)}"
      end
    end

    test "an absent acceptance_criteria key is exempt at both doors" do
      assert Validation.validate_task_content(%{"kind" => "task", "lifecycle_status" => "open"}) ==
               :ok

      %{before_save: [gate | _]} = Barkpark.Plugins.Tasks.lifecycle_hooks()

      assert gate.(%{
               doc: %{"type" => "task", "title" => "t", "content" => %{"kind" => "task"}},
               prev_doc: %{title: "prior"}
             }) == :ok
    end

    test "a pure metadata patch carrying no content is exempt at the plugin door" do
      %{before_save: [gate | _]} = Barkpark.Plugins.Tasks.lifecycle_hooks()

      assert gate.(%{doc: %{"type" => "task", "title" => "t"}, prev_doc: %{title: "prior"}}) ==
               :ok
    end

    test "a non-task document passes both doors untouched" do
      %{before_save: [gate | _]} = Barkpark.Plugins.Tasks.lifecycle_hooks()

      assert gate.(%{
               doc: %{
                 "type" => "note",
                 "content" => %{"acceptance_criteria" => [%{"text" => "x"}]}
               }
             }) == :ok
    end
  end

  describe "`worklog` is NOT constrained by the criteria rule" do
    # Tightening the SHARED helper would have been the easy way to write this
    # change, and it would have silently imposed the criteria contract on an
    # unrelated field. `worklog` keeps `check_optional_map_list/3`: any map is
    # a worklog entry. These arms are the fence.
    test "a worklog entry with no `criterion` is fine" do
      assert Validation.validate_task_content(%{
               "kind" => "task",
               "lifecycle_status" => "open",
               "worklog" => [%{"text" => "did a thing"}, %{"note" => "and another"}, %{}]
             }) == :ok
    end

    test "a worklog entry with a non-boolean `met` and a list `evidence` is fine" do
      assert Validation.validate_task_content(%{
               "kind" => "task",
               "lifecycle_status" => "open",
               "worklog" => [%{"met" => "sure", "evidence" => ["a", "list"], "criterion" => 42}]
             }) == :ok
    end

    test "worklog STILL refuses a non-map entry — the generic rule is intact, not removed" do
      assert {:error, %{"worklog" => [msg]}} =
               Validation.validate_task_content(%{
                 "kind" => "task",
                 "lifecycle_status" => "open",
                 "worklog" => ["not a map"]
               })

      assert msg =~ "must be a list of maps"
    end

    test "the SAME entry is refused as a criterion and accepted as a worklog line" do
      # The one arm that proves the two fields are on different contracts
      # rather than merely both green today.
      entry = %{"text" => "did a thing"}

      assert {:refused, _} = door_validation([entry])

      assert Validation.validate_task_content(%{
               "kind" => "task",
               "lifecycle_status" => "open",
               "worklog" => [entry]
             }) == :ok
    end
  end
end
