defmodule Barkpark.StudioChat.Runtime.CodexTaskHandsTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.StudioChat.Runtime
  alias Barkpark.StudioChat.Runtime.Codex
  alias Barkpark.Tenancy

  @fake_app_server Path.expand("../../../fixtures/codex_app_server/fake_app_server.py", __DIR__)

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
end
