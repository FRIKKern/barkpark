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
    def resolve("ws-1", "host-1") do
      {:ok,
       %{
         id: "host-1",
         workspace_id: "ws-1",
         capabilities: %{
           "providers" => %{
             "claude" => ready_provider(),
             "codex" => ready_provider()
           }
         }
       }}
    end

    defp ready_provider do
      %{
        "installed" => true,
        "auth_ready" => true,
        "operations" => ~w(send_turn steer interrupt answer_approval close),
        "task_hands" => true
      }
    end
  end

  defmodule Dispatch do
    @behaviour Runtime.RemoteDispatch
    def dispatch(host, command, _opts), do: {:ok, {:registered_host, host.id, command.provider}}
  end

  defmodule NotReadyDirectory do
    @behaviour Runtime.HostDirectory

    def resolve("ws-1", "host-1") do
      {:ok,
       %{
         id: "host-1",
         workspace_id: "ws-1",
         capabilities: %{
           "providers" => %{"codex" => %{"installed" => true, "auth_ready" => false}}
         }
       }}
    end
  end

  defmodule LifecycleDispatch do
    @behaviour Runtime.RemoteDispatch

    def dispatch(host, command, _opts) do
      {:ok, %{lease_id: "#{host.id}:#{command.operation}", provider: command.provider}}
    end
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

  test "registered-host lifecycle never opens a managed provider process" do
    for provider <- ~w(claude codex) do
      assert {:ok, %Runtime.RemoteRef{} = ref} =
               Runtime.open(provider, %{
                 session_id: "session-#{provider}",
                 execution_target: "registered_host",
                 execution_host_id: "host-1",
                 workspace_id: "ws-1",
                 host_directory: Directory,
                 remote_dispatch: LifecycleDispatch,
                 resume: false
               })

      assert ref.provider == provider
      assert is_nil(ref.lease_id)
      assert Runtime.alive?(ref)
      assert :ok = Runtime.send_turn(provider, ref, "hello")

      steer = if provider == "codex", do: %{content: "focus"}, else: %{mode: "plan"}
      assert {:ok, steer_id} = Runtime.steer(provider, ref, steer)
      assert is_binary(steer_id)

      assert {:ok, request_id} = Runtime.interrupt(provider, ref)
      assert is_binary(request_id)

      assert :ok = Runtime.answer_approval(provider, ref, "approval-1", :allow)

      assert :ok = Runtime.close(provider, ref)
    end
  end

  test "registered host fails closed when the selected provider is not authenticated" do
    assert {:error, {:provider_not_ready, "codex"}} =
             Runtime.open("codex", %{
               session_id: "session-codex",
               execution_target: "registered_host",
               execution_host_id: "host-1",
               workspace_id: "ws-1",
               host_directory: NotReadyDirectory,
               remote_dispatch: LifecycleDispatch
             })
  end

  test "registered host fails closed when its chat runtime predates bidirectional controls" do
    assert {:error, {:provider_protocol_incompatible, "codex"}} =
             Runtime.open("codex", %{
               session_id: "session-codex",
               execution_target: "registered_host",
               execution_host_id: "host-1",
               workspace_id: "ws-1",
               host_directory: Barkpark.ChatHosts.RuntimeMatrixTest.LegacyDirectory,
               remote_dispatch: LifecycleDispatch
             })
  end

  defmodule LegacyDirectory do
    @behaviour Runtime.HostDirectory

    def resolve("ws-1", "host-1") do
      {:ok,
       %{
         id: "host-1",
         workspace_id: "ws-1",
         capabilities: %{
           "providers" => %{"codex" => %{"installed" => true, "auth_ready" => true}}
         }
       }}
    end
  end
end
