defmodule BarkparkWeb.TasksController.ParamsTest do
  # Pure Ecto.Query builders — no DB, no app boot required.
  use ExUnit.Case, async: true

  alias Barkpark.Content.Document
  alias BarkparkWeb.TasksController.Params

  # Array-style query params (?type[]=task) arrive as lists. Each filter
  # builder must fail soft (no filter) instead of raising a FunctionClauseError
  # → unhandled 500 on the index endpoint `bp task ready`/`list` hits.
  describe "array-style (non-binary) filter values fail soft" do
    test "maybe_filter_type/2 does not raise on a list value" do
      assert Params.maybe_filter_type(Document, ["task"])
    end

    test "maybe_filter_kind/2 does not raise on a list value" do
      assert Params.maybe_filter_kind(Document, ["goal"])
    end

    test "maybe_filter_lifecycle/2 does not raise on a list value" do
      assert Params.maybe_filter_lifecycle(Document, ["open"])
    end

    test "maybe_filter_parent/2 does not raise on a list value" do
      assert Params.maybe_filter_parent(Document, ["x"])
    end

    test "maybe_filter_parent_id/2 does not raise on a list value" do
      assert Params.maybe_filter_parent_id(Document, ["x"])
    end

    test "maybe_filter_label/2 does not raise on a list value" do
      assert Params.maybe_filter_label(Document, ["x"])
    end
  end

  # parse_limit/3 is the ONE clamp for every task-list limit (ready/index/prime):
  # floor 1, ceil `cap`, but a missing param with a nil default stays nil (the
  # caller's own default). Guards `?limit=-1` (Postgres negative-LIMIT 500) and
  # `?limit=<huge>` (unbounded fetch).
  describe "parse_limit/3" do
    test "nil param + nil default passes nil through (unclamped default)" do
      assert Params.parse_limit(nil, nil, 200) == nil
    end

    test "nil param falls back to a non-nil default (clamped)" do
      assert Params.parse_limit(nil, 10, 100) == 10
    end

    test "a negative value floors at 1" do
      assert Params.parse_limit("-1", nil, 200) == 1
      assert Params.parse_limit("-5", 1000, 1000) == 1
    end

    test "an over-cap value ceils at cap" do
      assert Params.parse_limit("999999999", nil, 200) == 200
      assert Params.parse_limit("100000000", 1000, 1000) == 1000
    end

    test "a normal in-range value is unchanged" do
      assert Params.parse_limit("42", nil, 200) == 42
      assert Params.parse_limit("50", 1000, 1000) == 50
    end
  end
end
