defmodule Barkpark.ChatHosts.ProtocolTest do
  use ExUnit.Case, async: true

  alias Barkpark.ChatHosts.Protocol

  test "cursor reconciliation is ordered, idempotent, and fenced" do
    state = Protocol.new("lease-1", 7, 0)

    assert {:ok, state} = Protocol.accept(state, "lease-1", 7, 1, "event-1")
    assert {:duplicate, ^state} = Protocol.accept(state, "lease-1", 7, 1, "event-1")
    assert {:error, :cursor_gap} = Protocol.accept(state, "lease-1", 7, 3, "event-3")
    assert {:error, :stale_fence} = Protocol.accept(state, "lease-1", 6, 2, "event-2")
    assert {:ok, _state} = Protocol.accept(state, "lease-1", 7, 2, "event-2")
  end

  test "a cursor replay with a different idempotency key fails closed" do
    state = Protocol.new("lease-1", 1, 0)
    assert {:ok, state} = Protocol.accept(state, "lease-1", 1, 1, "event-1")
    assert {:error, :cursor_conflict} = Protocol.accept(state, "lease-1", 1, 1, "other")
  end
end
