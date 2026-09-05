defmodule BarkparkWeb.TasksController.ParamsTest do
  # Pure Ecto.Query builders — no DB, no app boot required.
  use ExUnit.Case, async: true

  alias Barkpark.Content.Document
  alias Barkpark.Content.Scope
  alias BarkparkWeb.TasksController.Params

  # LABELS ON THE BRIEF CARD (task-14eac58b39fd3692).
  #
  # The brief card is what `bp task ready` serves. Before this it carried no
  # `labels` key at all, so a row already labelled `landed:pr-NNNNN@sha` looked
  # identical on the wire to one that never shipped — and a census that
  # filtered ready cards by label returned a confident ZERO over 1,658 rows,
  # because the field could never be present. Measured 2026-09-05: 21 of those
  # rows carried a landed label, nine at zero criteria met.
  describe "render_doc/2 :brief — labels" do
    defp brief(content) do
      Params.render_doc(
        %Document{
          doc_id: "t1",
          title: "a task",
          content: content,
          updated_at: ~N[2026-09-05 10:00:00]
        },
        :brief
      )
    end

    test "a row's labels ride the brief card" do
      card = brief(%{"labels" => ["landed-on-main", "landed:pr-15505@a5b2ff3c67"]})

      assert card.labels == ["landed-on-main", "landed:pr-15505@a5b2ff3c67"]
    end

    test "ADDITIVE: a card with no labels is unchanged — the key is absent, not empty" do
      # The brief card is a deliberate payload diet, so a new key must not
      # appear on rows that have nothing to put in it.
      refute Map.has_key?(brief(%{}), :labels)
      refute Map.has_key?(brief(%{"labels" => []}), :labels)
      refute Map.has_key?(brief(%{"labels" => nil}), :labels)
    end

    test "a non-list labels value fails soft rather than raising" do
      # Same fail-soft law as the filter builders below: a malformed stored
      # value must not turn a list read into a 500.
      refute Map.has_key?(brief(%{"labels" => "landed-on-main"}), :labels)
      refute Map.has_key?(brief(%{"labels" => %{"a" => 1}}), :labels)
    end
  end

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

  # Scope unification (fail-closed nil): the list/prime/events tenancy helpers
  # route through the ONE shared `Content.Scope.scope_to_workspace/3` — the same
  # helper the ready-queue and claim paths use — so the tasks resource has a
  # single nil-scope rule (fail CLOSED → zero rows), not three divergent ones.
  # These are structural equalities: both sides compile down to the identical
  # `where(query, …)` call inside `Content.Scope`, so the query structs match.
  describe "workspace scoping unified through Content.Scope (fail-closed nil)" do
    test "maybe_filter_workspace/2 with nil no longer passes through — it fails CLOSED" do
      q = Params.maybe_filter_workspace(Document, nil)
      # The old behaviour returned the bare schema unchanged (fail-OPEN → all
      # tenants). Now it is a fail-closed query with a boolean `false` clause.
      refute q == Document
      assert %Ecto.Query{wheres: [%Ecto.Query.BooleanExpr{}]} = q
    end

    test "maybe_filter_workspace/2 with nil == Scope.scope_to_workspace(_, nil, nil)" do
      assert Params.maybe_filter_workspace(Document, nil) ==
               Scope.scope_to_workspace(Document, nil, nil)
    end

    test "maybe_filter_workspace/2 with a real workspace == Scope workspace-only scope" do
      assert Params.maybe_filter_workspace(Document, "ws-1") ==
               Scope.scope_to_workspace(Document, "ws-1", nil)
    end

    test "maybe_filter_event_workspace/2 with nil fails CLOSED via the same helper" do
      assert Params.maybe_filter_event_workspace(Document, nil) ==
               Scope.scope_to_workspace(Document, nil, nil)
    end

    test "maybe_filter_event_workspace/2 with a real workspace == Scope workspace-only scope" do
      assert Params.maybe_filter_event_workspace(Document, "ws-1") ==
               Scope.scope_to_workspace(Document, "ws-1", nil)
    end
  end
end
