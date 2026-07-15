defmodule Barkpark.StudioChat.Runtime.CodexTaskHandsTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.StudioChat.Runtime
  alias Barkpark.StudioChat.Runtime.Codex
  alias Barkpark.StudioChat.Runtime.RemoteSecrets
  alias Barkpark.Tenancy

  @fake_app_server Path.expand("../../../fixtures/codex_app_server/fake_app_server.py", __DIR__)

  defmodule RemoteDirectory do
    @behaviour Runtime.HostDirectory

    def resolve(workspace_id, "host-1") do
      {:ok,
       %{
         id: "host-1",
         workspace_id: workspace_id,
         approved_roots: [System.tmp_dir!()],
         capabilities: %{
           "providers" => %{
             "codex" => %{
               "installed" => true,
               "auth_ready" => true,
               "operations" => ~w(send_turn steer interrupt answer_approval close),
               "task_hands" => true
             }
           }
         }
       }}
    end
  end

  defmodule RemoteDispatch do
    @behaviour Runtime.RemoteDispatch

    def dispatch(_host, command, _opts) do
      send(
        Application.fetch_env!(:barkpark, :remote_task_hands_test_pid),
        {:remote_command, command}
      )

      {:ok, %{lease_id: Ecto.UUID.generate()}}
    end
  end

  test "managed Codex receives session-scoped Barkpark MCP task hands" do
    suffix = System.unique_integer([:positive])
    {:ok, workspace} = Tenancy.create_workspace(%{slug: "codex-hands-#{suffix}", name: "Codex"})

    {:ok, minter} =
      Auth.create_token(
        "codex-hands-minter-#{suffix}",
        "Codex task minter",
        "production",
        ["read", "write"],
        workspace.id
      )

    session_id = Ecto.UUID.generate()
    log = Path.join(System.tmp_dir!(), "codex_task_hands_#{suffix}.jsonl")
    on_exit(fn -> File.rm(log) end)

    assert {:ok, runtime} =
             Codex.start(%{
               binary: @fake_app_server,
               args: ["--scenario", "normal", "--log", log],
               sink: self(),
               session_id: session_id,
               workspace_id: workspace.id,
               minter: minter,
               timeout_ms: 500
             })

    assert Codex.task_hands(runtime) == :minted
    assert Runtime.worker_id("codex", session_id) == "codex-chat-#{session_id}"

    wire = File.read!(log)
    assert wire =~ ~s("mcp_servers")
    assert wire =~ ~s("barkpark")
    assert wire =~ ~s("BARKPARK_WORKER_ID")
    refute wire =~ "bpcs_"

    token = Repo.get_by!(ApiToken, label: "claude-session #{session_id}")
    assert is_nil(token.revoked_at)
    assert :ok = Codex.close(runtime)
    assert Repo.get!(ApiToken, token.id).revoked_at
  end

  test "registered Codex receives fenced Task hands without retaining the raw token in its ref" do
    suffix = System.unique_integer([:positive])

    {:ok, workspace} =
      Tenancy.create_workspace(%{slug: "remote-codex-hands-#{suffix}", name: "Remote Codex"})

    {:ok, minter} =
      Auth.create_token(
        "remote-codex-hands-minter-#{suffix}",
        "Remote Codex task minter",
        "production",
        ["read", "write"],
        workspace.id
      )

    Application.put_env(:barkpark, :remote_task_hands_test_pid, self())
    on_exit(fn -> Application.delete_env(:barkpark, :remote_task_hands_test_pid) end)

    session_id = Ecto.UUID.generate()

    assert {:ok, %Runtime.RemoteRef{} = runtime} =
             Runtime.open("codex", %{
               session_id: session_id,
               execution_target: "registered_host",
               execution_host_id: "host-1",
               workspace_id: workspace.id,
               host_directory: RemoteDirectory,
               remote_dispatch: RemoteDispatch,
               minter: minter,
               developer_instructions: "Be Task obsessed",
               mode: "plan",
               session_opts: %{model: "gpt-5.6-sol", effort: "high", bypass_armed: false}
             })

    assert Runtime.task_hands("codex", runtime) == :minted
    assert is_binary(runtime.task_secret_id)
    refute inspect(runtime) =~ "bpcs_"

    assert :ok = Runtime.send_turn("codex", runtime, "work the task")
    assert_receive {:remote_command, command}
    assert command.operation == :send_turn
    assert command.payload.task_env["BARKPARK_API_TOKEN"] =~ "bpcs_"
    assert command.payload.task_env["BARKPARK_WORKER_ID"] == "codex-chat-#{session_id}"
    assert command.payload.task_env["BARKPARK_API_URL"] == BarkparkWeb.Endpoint.url()
    assert command.payload.developer_instructions == "Be Task obsessed"
    assert command.payload.mode == "plan"
    assert command.payload.model == "gpt-5.6-sol"
    assert command.payload.effort == "high"
    refute Map.has_key?(command.payload, :bypass_armed)

    token = Repo.get_by!(ApiToken, label: "claude-session #{session_id}")
    assert is_nil(token.revoked_at)
    assert :ok = Runtime.close("codex", runtime)
    assert_receive {:remote_command, %{operation: :close}}
    assert Repo.get!(ApiToken, token.id).revoked_at
    assert is_nil(RemoteSecrets.fetch(runtime.task_secret_id))
  end
end
