defmodule Barkpark.StudioChat.RuntimeInterfaceTest do
  use ExUnit.Case, async: true

  alias Barkpark.StudioChat.Runtime

  test "the frozen adapter lifecycle is explicit" do
    callbacks = Runtime.Adapter.behaviour_info(:callbacks)

    assert {:start, 1} in callbacks
    assert {:resume, 1} in callbacks
    assert {:send_turn, 2} in callbacks
    assert {:steer, 2} in callbacks
    assert {:interrupt, 1} in callbacks
    assert {:answer_approval, 3} in callbacks
    assert {:close, 1} in callbacks
    assert {:readiness, 1} in callbacks
    assert {:capabilities, 0} in callbacks
  end

  test "normalized events retain correlation, ordering, durability, and native metadata" do
    assert %Runtime.Event{
             provider: "claude",
             session_id: "barkpark-session",
             provider_session_id: "native-session",
             turn_id: "turn-1",
             item_id: "item-1",
             sequence: 7,
             idempotency_key: "event-7",
             durability: :durable,
             kind: :completed,
             approval_id: "approval-1",
             terminal_state: :completed,
             error: nil,
             native: %{"type" => "result"}
           } = %Runtime.Event{
             provider: "claude",
             session_id: "barkpark-session",
             provider_session_id: "native-session",
             turn_id: "turn-1",
             item_id: "item-1",
             sequence: 7,
             idempotency_key: "event-7",
             durability: :durable,
             kind: :completed,
             approval_id: "approval-1",
             terminal_state: :completed,
             native: %{"type" => "result"}
           }
  end

  test "host directory and remote dispatcher expose narrow registered-host seams" do
    assert {:resolve, 2} in Runtime.HostDirectory.behaviour_info(:callbacks)
    assert {:dispatch, 3} in Runtime.RemoteDispatch.behaviour_info(:callbacks)
  end
end
