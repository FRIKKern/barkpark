defmodule BarkparkWeb.Studio.TmuxTenantAdminTest do
  @moduledoc """
  The Studio host terminal and an `admin` token of a TENANT workspace
  (task-4c44ce414f7d4a72).

  With the operator allowlist unset, `HostExecutionGate.instance_principal?/1`
  said yes to ANY token carrying `admin`, whatever its workspace: a tenant-B
  admin token in a Studio session mounted `/studio/tmux`, spawned the PTY and
  typed into it. The instance principal is now the admin token of the Default
  workspace or of no workspace (the legacy operator), or a Default seat. With
  the allowlist armed nothing changes.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.HostExecutionGate

  @admin ["read", "write", "admin"]
  @env_keys [:tmux_console, :public_demo_studio, :operator_emails, :operator_token_ids]

  defmodule FakePty do
    def spawn(_file, _args, _opts) do
      rec = Application.get_env(:barkpark, :fake_pty_recorder)
      if is_pid(rec), do: send(rec, :fake_spawn)
      {:ok, %{recorder: rec}}
    end

    def write(%{recorder: rec}, data) do
      if is_pid(rec), do: send(rec, {:fake_write, data})
      :ok
    end

    def resize(_pty, _cols, _rows), do: :ok
    def kill(_pty, _signal), do: :ok
  end

  setup %{conn: conn} do
    {default_ws, _} = ensure_default_scope!()
    prev = Map.new(@env_keys, &{&1, Application.get_env(:barkpark, &1)})

    Application.put_env(:barkpark, :tmux_console,
      enabled: true,
      backend: FakePty,
      session: "tmux-tenant-test",
      command: {"cat", []}
    )

    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [])
    Application.put_env(:barkpark, :fake_pty_recorder, self())

    on_exit(fn ->
      for {key, val} <- prev do
        if is_nil(val),
          do: Application.delete_env(:barkpark, key),
          else: Application.put_env(:barkpark, key, val)
      end

      Application.delete_env(:barkpark, :fake_pty_recorder)
    end)

    %{conn: conn, default_ws: default_ws, ws_b: create_workspace!()}
  end

  defp mint!(perms, ws_id) do
    raw = "tmux-tenant-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "tmux tenant", "production", perms, ws_id)
    {raw, token}
  end

  defp open(conn, raw), do: live(init_test_session(conn, %{"api_token" => raw}), "/studio/tmux")

  # Mount, start the PTY, type. True when the keystrokes reached the PTY.
  defp types_into_host?(conn, raw) do
    {:ok, view, html} = open(conn, raw)
    assert html =~ ~s(phx-hook="TmuxTerminal")
    render_hook(view, "term-init", %{"cols" => 80, "rows" => 24})
    assert_receive :fake_spawn
    render_hook(view, "term-input", %{"d" => Base.encode64("id\n")})
    assert_receive {:fake_write, "id\n"}
    true
  end

  describe "allowlist unset" do
    for {name, extra} <- [{"without chat", []}, {"with chat", ["chat"]}] do
      test "a tenant admin token (#{name}) does not get the host terminal", ctx do
        {raw, token} = mint!(@admin ++ unquote(extra), ctx.ws_b.id)

        refute HostExecutionGate.instance_principal?(token)
        assert {:error, {:redirect, %{to: "/studio"}}} = open(ctx.conn, raw)
        refute_received :fake_spawn
      end
    end

    test "controls: the Default-workspace and the no-workspace admin token keep it", ctx do
      for ws_id <- [ctx.default_ws.id, nil] do
        {raw, token} = mint!(@admin, ws_id)
        assert HostExecutionGate.instance_principal?(token)
        assert types_into_host?(ctx.conn, raw)
      end
    end

    test "controls: the Default seats are as before", ctx do
      {_, default_chat} = mint!(["read", "chat"], ctx.default_ws.id)
      assert HostExecutionGate.instance_principal?(default_chat)

      {_, seated} = mint!(@admin, ctx.ws_b.id)
      {:ok, _} = TenancyAuth.create_membership(ctx.default_ws.id, seated.id, "admin")
      assert HostExecutionGate.instance_principal?(seated)

      {_, tenant_chat} = mint!(["read", "chat"], ctx.ws_b.id)
      refute HostExecutionGate.instance_principal?(tenant_chat)
    end

    test "no Default workspace: a tenant admin token is not the operator, a no-workspace one is",
         ctx do
      import Ecto.Query, only: [from: 2]
      {_, tenant} = mint!(@admin, ctx.ws_b.id)
      {_, legacy} = mint!(@admin, nil)

      Barkpark.Repo.update_all(from(w in Barkpark.Tenancy.Workspace, where: w.is_default),
        set: [is_default: false]
      )

      Barkpark.Tenancy.DefaultScopeCache.invalidate()
      on_exit(&Barkpark.Tenancy.DefaultScopeCache.invalidate/0)
      assert Barkpark.Tenancy.get_default_workspace() == nil

      refute HostExecutionGate.instance_principal?(tenant)
      assert HostExecutionGate.instance_principal?(legacy)
    end
  end

  describe "allowlist armed: unchanged" do
    test "a tenant admin token the allowlist names gets the terminal; a Default one outside it does not",
         ctx do
      {named_raw, named} = mint!(@admin, ctx.ws_b.id)
      {other_raw, _} = mint!(@admin, ctx.default_ws.id)
      Application.put_env(:barkpark, :operator_token_ids, [named.id])

      assert types_into_host?(ctx.conn, named_raw)
      assert {:error, {:redirect, %{to: "/studio"}}} = open(ctx.conn, other_raw)
    end
  end
end
