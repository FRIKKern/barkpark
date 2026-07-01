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
end
