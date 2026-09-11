defmodule Barkpark.Tasks.SchemaAdjudicationTripleTest do
  @moduledoc """
  PDS wave 29 — "disposition and reopen_trigger are schema-invisible".

  The adjudication triple (`disposition`, `reopen_trigger`,
  `disposition_rerun`) has PERSISTED since wave 24 and is fenced at birth by
  `Content.Writer.ensure_task_born_adjudicated/5`, but it was never DECLARED:
  `Tasks.task_schema/1` returned 30 field names and none of them was
  `disposition`, while a create carrying all three read every one back. Every
  schema-derived surface — the Studio form, the export shape, the SDK types,
  `bp schema get task` — was therefore blind to three live keys.

  THIS FILE IS THE LOCK, and the lock is the point. A declaration that
  hand-copies `~w(open parked closed)` beside a validator that owns the same
  list is an UNLOCKED MIRROR: the two drift the day a fourth term lands, and
  nothing reds. So the schema does not restate the vocabulary — it CALLS
  `Barkpark.Tasks.Stage`, the module the birth fence itself screens against
  (`term not in Stage.dispositions()`), for both the field NAMES and the
  `options` list. These tests decode the schema the way a read surface does
  and assert that identity, so replacing either call with a literal — or
  changing one word on one side — fails here.

  WAVE 29 FOLLOW-UP — THE FOURTH KEY. `Stage.durable_reason_key/0`
  (`disposition_reason`) is the durable WHY, written by the same verb in the
  same CAS update and deliberately spared by `TtlSweeper.apply_lapse/1`. It was
  the fourth undeclared key: measured before the declaration landed,
  `task_schema/1` returned 33 field names and none of them was
  `disposition_reason`, while a create carrying it read it straight back. It is
  now locked here by the same rule — the NAME is read from `Stage`, never
  retyped, so removing the declaration or diverging the string reds below.

  What this file deliberately does NOT assert: that the declaration ENFORCES
  anything. `select` is a v1 leaf, the write contract is still
  `Writer.ensure_task_born_adjudicated/5`, and its three refusal branches are
  proven by `test/barkpark/content/task_birth_fence_test.exs`.
  """

  use Barkpark.DataCase, async: true

  alias Barkpark.Tasks
  alias Barkpark.Tasks.Stage

  defp fields_by_name do
    Tasks.task_schema().fields |> Map.new(&{&1["name"], &1})
  end

  # The four durable adjudication keys, each named by Stage's own accessor so
  # this list cannot drift from the declaration it checks.
  defp adjudication_keys do
    [
      Stage.disposition_key(),
      Stage.reopen_trigger_key(),
      Stage.disposition_rerun_key(),
      Stage.durable_reason_key()
    ]
  end

  describe "the adjudication keys are declared" do
    test "all four keys appear as task schema fields, named by Stage's own key accessors" do
      names = Tasks.task_schema().fields |> Enum.map(& &1["name"])

      for key <- adjudication_keys() do
        assert key in names,
               "#{key} is undeclared — a schema-derived surface cannot see it (#{inspect(names)})"
      end
    end

    test "each carries a group that exists, or it renders on NO Studio tab" do
      group_names = Tasks.task_schema().groups |> Enum.map(& &1["name"])
      fields = fields_by_name()

      for key <- adjudication_keys() do
        assert fields[key]["group"] in group_names
      end
    end

    test "the keys sit in `work`, not `close` — a parked row is NOT terminal" do
      # The close group hides behind `lifecycle_status in [done, cancelled]`.
      # Seating the adjudication there would hide it on exactly the rows that
      # carry it: a parked task is open-lifecycle by construction.
      fields = fields_by_name()

      for key <- adjudication_keys() do
        assert fields[key]["group"] == "work"
      end
    end
  end

  describe "the vocabulary is SOURCED from the birth fence, not mirrored beside it" do
    test "disposition options are IDENTICAL to Stage.dispositions/0" do
      # The mutation this test exists to catch: replace `Stage.dispositions()`
      # in schema.ex with a literal list, or change one word in either place.
      # Either edit breaks the identity and reds here.
      field = fields_by_name()[Stage.disposition_key()]

      assert field["type"] == "select"
      assert field["options"] == Stage.dispositions()
    end

    test "the hollow-park nudge's exempt terms are the DERIVED complement" do
      rule =
        Tasks.task_schema().cross_validations
        |> Enum.find(&(&1["name"] == "parked_needs_reopen_trigger"))

      assert rule, "the hollow-park nudge is missing"
      assert rule["level"] == "warning", "the API is the single ENFORCING writer, not the form"
      assert rule["fields"] == [Stage.reopen_trigger_key()]

      exempt =
        rule["rule"]["any"]
        |> Enum.find(&(&1["operator"] == "in"))
        |> Map.fetch!("value")

      assert exempt == Stage.dispositions() -- Stage.trigger_required_dispositions()

      refute Enum.any?(Stage.trigger_required_dispositions(), &(&1 in exempt)),
             "a term that OWES a reopen trigger must not be exempted from the nudge"
    end

    test "reopen_trigger is revealed by exactly the trigger-requiring terms" do
      field = fields_by_name()[Stage.reopen_trigger_key()]

      assert field["visibleWhen"] == %{
               "field" => Stage.disposition_key(),
               "operator" => "in",
               "value" => Stage.trigger_required_dispositions()
             }
    end

    test "every declared vocabulary word is one the birth fence would ACCEPT" do
      # The end-to-end statement of the lock, independent of HOW the schema
      # gets its list: no declared option may be a term `Stage.dispositions/0`
      # (and therefore `ensure_task_born_adjudicated/5`) would 422.
      options = fields_by_name()[Stage.disposition_key()]["options"]

      assert options != []

      for term <- options do
        assert term in Stage.dispositions(),
               "the schema offers #{inspect(term)}, which the birth fence refuses"
      end

      for term <- Stage.dispositions() do
        assert term in options,
               "the birth fence accepts #{inspect(term)}, which the schema never offers"
      end
    end
  end

  describe "the durable reason is declared and is NOT gated on a disposition term" do
    test "disposition_reason is declared under the name Stage owns" do
      # THE MUTATION THIS CATCHES, direction 1: delete the declaration from
      # schema.ex. THE MUTATION IT CATCHES, direction 2: retype the name as a
      # literal that diverges from `Stage.durable_reason_key/0` (e.g.
      # "disposition_note") — the schema then declares a key nothing writes,
      # and the key Stage DOES write stays invisible.
      names = Tasks.task_schema().fields |> Enum.map(& &1["name"])

      assert Stage.durable_reason_key() in names,
             "#{Stage.durable_reason_key()} is undeclared — a schema-derived surface cannot " <>
               "see the durable WHY, though Stage persists it (#{inspect(names)})"
    end

    test "it is free text, not a select — a reason is prose, not a vocabulary" do
      field = fields_by_name()[Stage.durable_reason_key()]

      assert field["type"] == "text"
      refute Map.has_key?(field, "options")
    end

    test "it carries NO visibleWhen, unlike the rerun one field over" do
      # `Stage.stage/3` routes `:note` on EVERY stageable target, including
      # `-> open`, so a row can carry a reason with no `disposition` term at
      # all. Copying `disposition_rerun`'s `visibleWhen` onto this field would
      # hide it on exactly those rows — so the ASYMMETRY is asserted, not the
      # presence of one more `visibleWhen`.
      fields = fields_by_name()

      refute Map.has_key?(fields[Stage.durable_reason_key()], "visibleWhen"),
             "the durable reason must not be gated on a disposition term — Stage writes it " <>
               "on stages that set no term"

      assert fields[Stage.disposition_rerun_key()]["visibleWhen"] == %{
               "field" => Stage.disposition_key(),
               "operator" => "non_empty"
             }
    end

    test "the four keys are four DISTINCT declarations, not one field counted twice" do
      names = Tasks.task_schema().fields |> Enum.map(& &1["name"])
      declared = Enum.filter(names, &(&1 in adjudication_keys()))

      assert Enum.sort(declared) == Enum.sort(adjudication_keys())
      assert length(Enum.uniq(declared)) == 4
    end
  end
end
