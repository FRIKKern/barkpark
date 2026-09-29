defmodule Barkpark.AuditBestEffortTest do
  @moduledoc """
  The shared best-effort audit helper, `Barkpark.Audit.emit_best_effort/2`
  (era-bl-audit-swallow-unify): whatever `emit/1` does — succeed, return an
  error, raise, throw or exit — the helper returns `:ok` and never propagates.
  Its callers are locked end to end in `Barkpark.AuditBestEffortCallersTest`.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Audit

  @ws Ecto.UUID.generate()

  test "a successful emit writes its row and returns :ok" do
    assert :ok ==
             Audit.emit_best_effort(%{category: "auth", action: "logout", workspace_id: @ws})

    assert [%{action: "logout"}] = Audit.list_for_workspace(@ws)
  end

  test "an emit that returns {:error, _} is discarded: :ok, no row" do
    # A category outside the vocabulary fails the changeset → emit/1 returns
    # {:error, changeset}.
    assert {:error, _} = Audit.emit(%{category: "not-a-category", action: "x", workspace_id: @ws})

    assert :ok ==
             Audit.emit_best_effort(%{category: "not-a-category", action: "x", workspace_id: @ws})

    assert Audit.list_for_workspace(@ws) == []
  end

  test "an emit that raises is swallowed" do
    # emit/1 is guarded on is_map/1, so a non-map raises FunctionClauseError
    # from inside the helper's body — the real emit, not an injected one.
    assert_raise FunctionClauseError, fn -> Audit.emit(:not_a_map) end
    assert :ok == Audit.emit_best_effort(:not_a_map)

    assert :ok == Audit.emit_best_effort(%{}, fn _ -> raise "audit bus down" end)
  end

  test "an emit that throws is swallowed" do
    assert :ok == Audit.emit_best_effort(%{}, fn _ -> throw(:audit_bus_down) end)
  end

  test "an emit that exits is swallowed (pool checkout death arrives as an exit)" do
    assert :ok == Audit.emit_best_effort(%{}, fn _ -> exit(:audit_bus_down) end)
  end
end
