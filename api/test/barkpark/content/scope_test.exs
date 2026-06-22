defmodule Barkpark.Content.ScopeTest do
  @moduledoc """
  Unit tests for Barkpark.Content.Scope — the hard-tenant boundary helper.

  Scope is pure query composition (no Repo calls), so we inspect the
  resulting %Ecto.Query{} struct directly.  No DataCase or DB sandbox needed.

  Key contracts under test:

    * nil workspace_id → fail CLOSED (`where: false`, barkpark-s6t1)
    * binary workspace_id, no project → workspace-only WHERE
    * both binary → workspace AND project WHERE
    * scope_to_workspace_global/1 → query returned untouched (explicit opt-in)
    * scope_to_workspace_or_global/3 nil → same as global (back-compat bridge)
    * scope_to_workspace_or_global/3 non-nil → delegates to scope_to_workspace
    * clauses compose: a second scope appends a second where-expr
  """

  use ExUnit.Case, async: true

  import Ecto.Query

  alias Barkpark.Content.Scope

  # A simple base query — no schema required; we only inspect the struct.
  defp base_query, do: from(d in "documents")

  # ---------------------------------------------------------------------------
  # Helper: pull the flat list of BooleanExpr expressions from the query.
  # ---------------------------------------------------------------------------
  defp wheres(%Ecto.Query{wheres: ws}), do: ws

  # ---------------------------------------------------------------------------
  # scope_to_workspace/3 — nil workspace_id → fail CLOSED
  # ---------------------------------------------------------------------------

  describe "scope_to_workspace/3 with nil workspace_id (fail-CLOSED)" do
    test "adds a where: false clause (barkpark-s6t1)" do
      q = Scope.scope_to_workspace(base_query(), nil)
      [expr] = wheres(q)
      assert expr.expr == false
    end

    test "fail-closed regardless of project_id value" do
      q_nil = Scope.scope_to_workspace(base_query(), nil, nil)
      q_proj = Scope.scope_to_workspace(base_query(), nil, "proj-x")
      assert [%{expr: false}] = wheres(q_nil)
      assert [%{expr: false}] = wheres(q_proj)
    end

    test "returns an Ecto.Query (not the raw queryable)" do
      q = Scope.scope_to_workspace(base_query(), nil)
      assert %Ecto.Query{} = q
    end

    test "where: false composes — subsequent where clauses still attach" do
      q =
        base_query()
        |> Scope.scope_to_workspace(nil)
        |> where([d], d.dataset == "production")

      # Two wheres: the fail-closed one PLUS the extra caller where.
      assert length(wheres(q)) == 2
      assert Enum.any?(wheres(q), &(&1.expr == false))
    end
  end

  # ---------------------------------------------------------------------------
  # scope_to_workspace/3 — workspace only
  # ---------------------------------------------------------------------------

  describe "scope_to_workspace/3 with workspace_id, no project_id" do
    test "adds exactly one where clause" do
      q = Scope.scope_to_workspace(base_query(), "ws-abc")
      assert length(wheres(q)) == 1
    end

    test "the clause binds workspace_id" do
      q = Scope.scope_to_workspace(base_query(), "ws-abc")
      [expr] = wheres(q)
      # params carries the bound value with its field name
      assert Enum.any?(expr.params, fn
               {"ws-abc", {_, :workspace_id}} -> true
               _ -> false
             end)
    end

    test "does NOT bind project_id" do
      q = Scope.scope_to_workspace(base_query(), "ws-abc")
      [expr] = wheres(q)
      refute Enum.any?(expr.params, fn
               {_, {_, :project_id}} -> true
               _ -> false
             end)
    end

    test "explicit nil project_id is workspace-only (default arity equivalence)" do
      q_default = Scope.scope_to_workspace(base_query(), "ws-abc")
      q_explicit = Scope.scope_to_workspace(base_query(), "ws-abc", nil)
      assert wheres(q_default) |> length() == 1
      assert wheres(q_explicit) |> length() == 1
      # Both carry the same workspace_id binding
      [d] = wheres(q_default)
      [e] = wheres(q_explicit)
      assert d.params == e.params
    end
  end

  # ---------------------------------------------------------------------------
  # scope_to_workspace/3 — workspace + project
  # ---------------------------------------------------------------------------

  describe "scope_to_workspace/3 with workspace_id AND project_id" do
    test "adds exactly one where clause" do
      q = Scope.scope_to_workspace(base_query(), "ws-abc", "proj-xyz")
      assert length(wheres(q)) == 1
    end

    test "the clause binds both workspace_id and project_id" do
      q = Scope.scope_to_workspace(base_query(), "ws-abc", "proj-xyz")
      [expr] = wheres(q)

      has_ws =
        Enum.any?(expr.params, fn
          {"ws-abc", {_, :workspace_id}} -> true
          _ -> false
        end)

      has_proj =
        Enum.any?(expr.params, fn
          {"proj-xyz", {_, :project_id}} -> true
          _ -> false
        end)

      assert has_ws
      assert has_proj
    end

    test "the combined clause is an :and expression" do
      q = Scope.scope_to_workspace(base_query(), "ws-abc", "proj-xyz")
      [expr] = wheres(q)
      assert expr.op == :and
      # The inner AST node is also an :and (workspace AND project)
      assert match?({:and, _, _}, expr.expr)
    end
  end

  # ---------------------------------------------------------------------------
  # scope_to_workspace_global/1 — deliberate cross-tenant opt-in
  # ---------------------------------------------------------------------------

  describe "scope_to_workspace_global/1" do
    test "returns the query untouched (no wheres added)" do
      q = Scope.scope_to_workspace_global(base_query())
      assert wheres(q) == []
    end

    test "returns the identical query when it already has wheres" do
      already_scoped =
        base_query() |> where([d], d.dataset == "production")

      q = Scope.scope_to_workspace_global(already_scoped)
      # The original where clause is preserved and nothing is added on top.
      assert wheres(q) == wheres(already_scoped)
    end
  end

  # ---------------------------------------------------------------------------
  # scope_to_workspace_or_global/3 — back-compat bridge
  # ---------------------------------------------------------------------------

  describe "scope_to_workspace_or_global/3 with nil workspace_id" do
    test "behaves like global — no wheres added" do
      q = Scope.scope_to_workspace_or_global(base_query(), nil, nil)
      assert wheres(q) == []
    end

    test "nil workspace_id with a non-nil project_id still falls back to global" do
      q = Scope.scope_to_workspace_or_global(base_query(), nil, "proj-xyz")
      assert wheres(q) == []
    end
  end

  describe "scope_to_workspace_or_global/3 with non-nil workspace_id" do
    test "delegates to scope_to_workspace — workspace-only when no project" do
      direct = Scope.scope_to_workspace(base_query(), "ws-abc")
      via_bridge = Scope.scope_to_workspace_or_global(base_query(), "ws-abc", nil)

      assert length(wheres(direct)) == 1
      assert length(wheres(via_bridge)) == 1

      [d] = wheres(direct)
      [b] = wheres(via_bridge)
      assert d.params == b.params
    end

    test "delegates to scope_to_workspace — workspace+project when both given" do
      direct = Scope.scope_to_workspace(base_query(), "ws-abc", "proj-xyz")
      via_bridge = Scope.scope_to_workspace_or_global(base_query(), "ws-abc", "proj-xyz")

      [d] = wheres(direct)
      [b] = wheres(via_bridge)
      assert d.params == b.params
    end
  end

  # ---------------------------------------------------------------------------
  # Composability
  # ---------------------------------------------------------------------------

  describe "composability" do
    test "scope_to_workspace can stack on top of an existing where clause" do
      q =
        base_query()
        |> where([d], d.dataset == "production")
        |> Scope.scope_to_workspace("ws-abc")

      # Two wheres: the dataset filter + the workspace scope
      assert length(wheres(q)) == 2
    end

    test "scope_to_workspace_global preserves pre-existing scopes unchanged" do
      q =
        base_query()
        |> Scope.scope_to_workspace("ws-abc")
        |> Scope.scope_to_workspace_global()

      assert length(wheres(q)) == 1
    end
  end
end
