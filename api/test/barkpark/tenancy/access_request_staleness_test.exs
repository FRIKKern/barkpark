defmodule Barkpark.Tenancy.AccessRequestStalenessTest do
  @moduledoc """
  `AccessRequestStaleness.stale?/2` on built structs: no DB, so each case is
  the rule itself (task-018e79d8734a1b08). The seat stamp decides, not the
  role and not the clock. Each case fails on the earlier role + timestamp rule.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Tenancy.{AccessRequest, AccessRequestStaleness, Membership}

  @asked ~U[2026-11-19 10:00:00.000000Z]
  @earlier ~U[2026-11-19 09:00:00.000000Z]
  @later ~U[2026-11-19 11:00:00.000000Z]
  @stamp "6f2b1f4e-6a59-4c2e-9a39-0a7d1c7f1a01"
  @other_stamp "6f2b1f4e-6a59-4c2e-9a39-0a7d1c7f1a02"

  defp role_request(stamp) do
    %AccessRequest{
      workspace_id: Ecto.UUID.generate(),
      from_role: "viewer",
      seat_change: stamp,
      inserted_at: @asked
    }
  end

  defp seat(stamp, at),
    do: %Membership{role: "viewer", seat_change: stamp, inserted_at: at, updated_at: at}

  test "a seat written since the ask is stale, even with the same role and older timestamps" do
    assert AccessRequestStaleness.stale?(role_request(@stamp), seat(@other_stamp, @earlier))
  end

  test "the seat with the stamp the request recorded is fresh, whatever its timestamps" do
    refute AccessRequestStaleness.stale?(role_request(@stamp), seat(@stamp, @later))
  end

  test "a row for a missing workspace is stale once its asker holds a seat" do
    ghost = %AccessRequest{workspace_id: nil, inserted_at: @asked}
    assert AccessRequestStaleness.stale?(ghost, seat(@stamp, @earlier))
  end
end
