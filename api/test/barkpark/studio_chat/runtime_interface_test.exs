defmodule Barkpark.StudioChat.RuntimeInterfaceTest do
  use ExUnit.Case, async: false

  alias Barkpark.StudioChat.Runtime

  defmodule FakeAdapter do
    @behaviour Runtime.Adapter

    def start(opts), do: notify({:start, opts}, {:ok, :fake_runtime})
    def resume(opts), do: notify({:resume, opts}, {:ok, :fake_runtime})
    def send_turn(runtime, content), do: notify({:send_turn, runtime, content}, :ok)
    def steer(runtime, command), do: notify({:steer, runtime, command}, {:ok, "steer-1"})
    def interrupt(runtime), do: notify({:interrupt, runtime}, {:ok, "interrupt-1"})

    def answer_approval(runtime, approval_id, decision),
      do: notify({:answer_approval, runtime, approval_id, decision}, :ok)

    def close(runtime), do: notify({:close, runtime}, :ok)
    def readiness(_opts), do: %{binary: true, authed?: true}
    def capabilities, do: %{modes: ["plan"], models: [], efforts: []}

    defp notify(message, result) do
      send(Process.get(:runtime_test_pid), message)
      result
    end
  end

  setup do
    previous = Application.get_env(:barkpark, :studio_chat_runtime_adapters)
    Application.put_env(:barkpark, :studio_chat_runtime_adapters, %{claude: FakeAdapter})
    Process.put(:runtime_test_pid, self())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :studio_chat_runtime_adapters, previous),
        else: Application.delete_env(:barkpark, :studio_chat_runtime_adapters)
    end)

    :ok
  end

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

  test "provider routing preserves the complete managed lifecycle" do
    assert {:ok, :fake_runtime} = Runtime.open("claude", %{resume: false, marker: :fresh})
    assert_receive {:start, %{marker: :fresh}}

    assert {:ok, :fake_runtime} = Runtime.open("claude", %{resume: true, marker: :resume})
    assert_receive {:resume, %{marker: :resume}}

    assert :ok = Runtime.send_turn("claude", :fake_runtime, "hello")
    assert_receive {:send_turn, :fake_runtime, "hello"}

    assert {:ok, "steer-1"} = Runtime.steer("claude", :fake_runtime, %{mode: "plan"})
    assert_receive {:steer, :fake_runtime, %{mode: "plan"}}

    assert {:ok, "interrupt-1"} = Runtime.interrupt("claude", :fake_runtime)
    assert_receive {:interrupt, :fake_runtime}

    assert :ok = Runtime.answer_approval("claude", :fake_runtime, "approval-1", :allow)
    assert_receive {:answer_approval, :fake_runtime, "approval-1", :allow}

    assert :ok = Runtime.close("claude", :fake_runtime)
    assert_receive {:close, :fake_runtime}
  end

  test "adapter-specific runtime references expose monitoring and provider identity" do
    pid = self()
    runtime = %{runtime: pid, provider_session_id: "thread-1"}

    assert Runtime.runtime_pid(runtime) == pid
    assert Runtime.alive?(runtime)
    assert Runtime.provider_session_id(runtime) == "thread-1"
  end
end
