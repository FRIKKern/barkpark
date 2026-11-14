defmodule BarkparkWeb.Studio.TmuxStrippedAdminTest do
  @moduledoc """
  An open Studio host terminal follows the rule a fresh mount follows
  (task-7160addac27a6434).

  `/studio/tmux` mounts behind two gates: the `:admin` live_session (a token
  holds `admin` and its admin seat) and `HostExecutionGate.instance_principal?/1`.
  The per-event re-check asked only the second. A Default-workspace admin token
  whose `admin` permission was taken away kept typing into the open terminal:
  its home membership row in Default (role `admin`) still made it an instance
  principal, while a fresh mount by the same token was refused.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo

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
      session: "tmux-stripped-test",
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

  defp mint!(ws_id) do
    raw = "tmux-stripped-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "tmux stripped", "production", @admin, ws_id)
    {raw, token}
  end

  defp open(conn, session), do: live(init_test_session(conn, session), "/studio/tmux")

  # Mount and start the PTY.
  defp open_terminal(conn, session) do
    {:ok, view, _html} = open(conn, session)
    render_hook(view, "term-init", %{"cols" => 80, "rows" => 24})
    assert_receive :fake_spawn
    view
  end

  defp type(view), do: render_hook(view, "term-input", %{"d" => Base.encode64("id\n")})

  # No product path edits a minted token's permissions; the row is changed
  # directly, the way an operator with database access would.
  defp strip_admin!(%ApiToken{id: id}) do
    {1, _} =
      Repo.update_all(from(t in ApiToken, where: t.id == ^id),
        set: [permissions: ["read", "write"]]
      )
  end

  defp assert_ended(view) do
    assert {:error, {:redirect, %{to: "/studio"}}} = type(view)
    refute_received {:fake_write, _}
  end

  defp assert_types(view) do
    assert is_binary(type(view))
    assert_receive {:fake_write, "id\n"}
  end

  test "a Default admin token stripped of admin stops typing into the open terminal", ctx do
    {raw, token} = mint!(ctx.default_ws.id)
    view = open_terminal(ctx.conn, %{"api_token" => raw})
    assert_types(view)

    strip_admin!(token)

    # A fresh mount is refused; the open view is refused the same way a revoked
    # or expired token is.
    assert {:error, {:redirect, %{to: "/studio"}}} = open(ctx.conn, %{"api_token" => raw})
    assert_ended(view)
  end

  test "allowlist armed: a named token stripped of admin stops typing too", ctx do
    {raw, token} = mint!(ctx.ws_b.id)
    Application.put_env(:barkpark, :operator_token_ids, [token.id])
    view = open_terminal(ctx.conn, %{"api_token" => raw})

    strip_admin!(token)

    assert_ended(view)
  end

  test "controls: untouched admin tokens keep typing", ctx do
    for ws_id <- [ctx.default_ws.id, nil] do
      {raw, _token} = mint!(ws_id)
      view = open_terminal(ctx.conn, %{"api_token" => raw})
      assert_types(view)
      assert_types(view)
    end
  end

  test "control: a Default-admin account session (no token) keeps typing", ctx do
    {:ok, user} =
      Barkpark.Accounts.register_user(%{
        email: "tmux-stripped-#{Ecto.UUID.generate()}@example.com",
        password: "correct-horse-battery-staple-42"
      })

    {:ok, _} =
      Barkpark.Tenancy.Auth.create_membership(ctx.default_ws.id, user.id, "admin", "user")

    {:ok, session} = Barkpark.Accounts.create_user_session_token(user)

    view = open_terminal(ctx.conn, %{"user_session" => session})
    assert_types(view)
    assert_types(view)
  end

  test "control: allowlist armed, a named admin token keeps typing; arming without it ends it",
       ctx do
    {raw, token} = mint!(ctx.ws_b.id)
    Application.put_env(:barkpark, :operator_token_ids, [token.id])
    view = open_terminal(ctx.conn, %{"api_token" => raw})
    assert_types(view)

    Application.put_env(:barkpark, :operator_token_ids, ["another-token-id"])
    assert_ended(view)
  end
end
