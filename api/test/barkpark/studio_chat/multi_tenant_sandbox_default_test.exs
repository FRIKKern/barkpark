defmodule Barkpark.StudioChat.MultiTenantSandboxDefaultTest do
  @moduledoc """
  OWNER RULING 2026-10-03 #3 (task-6ca882967fd95dda): ratifies #20928 (only
  an instance principal reaches host execution) AND makes the sandboxed
  `:cloud` chat profile the DEFAULT for workspace sessions on a multi-tenant
  instance. An explicit choice — the global `:execution_profile` config or a
  workspace's own setting — still decides; instance-global (`nil`-owned)
  sessions are untouched; a single-tenant instance keeps the host default.

  `async: false`: the `:claude_chat` config is node-global Application env.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.StudioChat.HostExecution
  alias Barkpark.StudioChat.Provider.Claude
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Workspace

  setup do
    prev = Application.get_env(:barkpark, :claude_chat, [])
    on_exit(fn -> Application.put_env(:barkpark, :claude_chat, prev) end)
    Application.put_env(:barkpark, :claude_chat, Keyword.delete(prev, :execution_profile))
    :ok
  end

  defp workspace!(tag) do
    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "#{tag}-#{System.unique_integer([:positive])}", name: tag})

    ws
  end

  defp profile(ws_id),
    do:
      Claude.execution_profile(Claude.resolve_workspace_execution_profile(%{workspace_id: ws_id}))

  test "multi-tenant, nothing chosen: a workspace session runs sandboxed" do
    ws = workspace!("tenant")
    assert Tenancy.multi_tenant?()
    assert profile(ws.id) == :cloud
    refute HostExecution.host_exec?("claude", ws.id)
  end

  test "an instance-global (nil-owned) session keeps the host profile" do
    _ = workspace!("tenant")
    assert profile(nil) == :self_hosted
  end

  test "an explicit global :execution_profile still decides" do
    ws = workspace!("tenant")
    Application.put_env(:barkpark, :claude_chat, execution_profile: :self_hosted)
    assert profile(ws.id) == :self_hosted
  end

  test "a workspace's own explicit setting still decides" do
    ws = workspace!("tenant")
    {:ok, ws} = Tenancy.set_workspace_chat_settings(ws, %{"execution_profile" => "self_hosted"})
    assert profile(ws.id) == :self_hosted
  end

  test "single-tenant: the lone workspace keeps the host default" do
    ws = workspace!("solo")
    Repo.delete_all(from(w in Workspace, where: w.id != ^ws.id))
    refute Tenancy.multi_tenant?()
    assert profile(ws.id) == :self_hosted
  end
end
