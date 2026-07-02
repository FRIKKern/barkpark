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

  # `?limit[]=5` / `?limit[a]=b` reach parse_int as a list/map — the catch-all
  # must fall to the default instead of a FunctionClauseError 500 on the
  # ready/index/graph endpoints `bp task ready` and friends depend on.
  describe "parse_int/2 non-binary (array/map) values fall to the default" do
    test "list value falls to default" do
      assert Params.parse_int(["5"], 10) == 10
    end

    test "map value falls to default" do
      assert Params.parse_int(%{"a" => "1"}, 10) == 10
    end
  end

  # parse_limit clamps into [1, max] so a negative LIMIT can't reach Postgres and
  # an oversized one can't fan out the corpus; a nil default passes through.
  describe "parse_limit/3 clamps into [1, max]" do
    test "in-range value is returned as-is" do
      assert Params.parse_limit("25", 1000, 1000) == 25
    end

    test "negative value floors to 1" do
      assert Params.parse_limit("-1", 1000, 1000) == 1
    end

    test "oversized value ceils to max" do
      assert Params.parse_limit("999999999", 1000, 1000) == 1000
    end

    test "nil default passes through unclamped" do
      assert Params.parse_limit(nil, nil, 1000) == nil
    end

    test "non-binary value falls to default, then nil passes through" do
      assert Params.parse_limit(["5"], nil, 1000) == nil
    end
  end
end
