defmodule Barkpark.Tenancy.AccessRequestStalenessTest do
  @moduledoc """
  `AccessRequestStaleness.stale?/2` on built structs: no DB, so each case is
  the rule itself (task-018e79d8734a1b08).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Tenancy.{AccessRequest, AccessRequestStaleness, Membership}

  @asked ~U[2026-11-19 10:00:00.000000Z]
  @earlier ~U[2026-11-19 09:00:00.000000Z]
  @later ~U[2026-11-19 11:00:00.000000Z]

  defp request(from_role) do
    %AccessRequest{workspace_id: Ecto.UUID.generate(), from_role: from_role, inserted_at: @asked}
  end

  defp seat(role, inserted_at, updated_at),
    do: %Membership{role: role, inserted_at: inserted_at, updated_at: updated_at}

  test "an untouched seat holding the recorded role is fresh" do
    refute AccessRequestStaleness.stale?(request("viewer"), seat("viewer", @earlier, @earlier))
  end

  test "a seat re-made with the same role after the ask is stale" do
    assert AccessRequestStaleness.stale?(request("viewer"), seat("viewer", @later, @later))
  end

  test "a role moved A -> B -> A after the ask is stale" do
    assert AccessRequestStaleness.stale?(request("viewer"), seat("viewer", @earlier, @later))
  end

  test "another role, or no seat, is stale for a role request" do
    assert AccessRequestStaleness.stale?(request("viewer"), seat("member", @earlier, @earlier))
    assert AccessRequestStaleness.stale?(request("viewer"), nil)
  end

  test "a seat request is fresh without a seat and stale with one" do
    refute AccessRequestStaleness.stale?(request(nil), nil)
    assert AccessRequestStaleness.stale?(request(nil), seat("member", @earlier, @earlier))
  end

  test "a request for a missing workspace is never stale" do
    ghost = %AccessRequest{workspace_id: nil, from_role: nil, inserted_at: @asked}
    refute AccessRequestStaleness.stale?(ghost, seat("member", @later, @later))
  end
end
