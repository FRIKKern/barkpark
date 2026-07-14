defmodule Barkpark.ChatHosts.RuntimeMatrixTest do
  use ExUnit.Case, async: false

  alias Barkpark.StudioChat.Runtime
  alias Barkpark.StudioChat.Runtime.Command

  defmodule Adapter do
    @behaviour Runtime.Adapter
    def start(opts), do: {:ok, {:managed, opts[:provider] || opts["provider"]}}
    def resume(opts), do: {:ok, opts}
    def send_turn(_, _), do: :ok
    def steer(_, _), do: :ok
    def interrupt(ref), do: {:ok, ref}
    def answer_approval(_, _, _), do: :ok
    def close(_), do: :ok
    def readiness(_), do: %{ready: true}
    def capabilities, do: %{}
  end

  defmodule Directory do
    @behaviour Runtime.HostDirectory
    def resolve("ws-1", "host-1"), do: {:ok, %{id: "host-1", workspace_id: "ws-1"}}
  end

  defmodule Dispatch do
    @behaviour Runtime.RemoteDispatch
    def dispatch(host, command, _opts), do: {:ok, {:registered_host, host.id, command.provider}}
  end

  setup do
    old = Application.get_env(:barkpark, :studio_chat_runtime_adapters)

    Application.put_env(:barkpark, :studio_chat_runtime_adapters, %{
      claude: Adapter,
      codex: Adapter
    })

    on_exit(fn ->
      if old,
        do: Application.put_env(:barkpark, :studio_chat_runtime_adapters, old),
        else: Application.delete_env(:barkpark, :studio_chat_runtime_adapters)
    end)
  end

  test "managed or registered execution remains independent of Claude or Codex provider" do
    for provider <- ~w(claude codex), target <- ~w(managed registered_host) do
      command = %Command{
        operation: :start,
        provider: provider,
        session_id: Ecto.UUID.generate(),
        payload: %{provider: provider}
      }

      result =
        Runtime.dispatch(target, provider, command,
          workspace_id: "ws-1",
          execution_host_id: "host-1",
          host_directory: Directory,
          remote_dispatch: Dispatch
        )

      expected =
        if target == "managed",
          do: {:ok, {:managed, provider}},
          else: {:ok, {:registered_host, "host-1", provider}}

      assert result == expected
    end
  end
end
