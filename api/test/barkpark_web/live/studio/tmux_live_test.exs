defmodule BarkparkWeb.Studio.TmuxLiveTest do
  @moduledoc """
  Server-half behavior of the dev-only tmux console. A fake PTY backend is
  injected via config so the whole spawn → input → output → resize path is
  exercised WITHOUT a real tmux or browser: the fake records every call and
  hands back the `on_data` callback the test drives to simulate PTY output.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth

  @admin_token "tmux-admin-test-token"
  @junior_token "tmux-junior-test-token"

  # ── Fake PTY backend ─────────────────────────────────────────────────────
  # Same shape as ExPTY.{spawn,write,resize,kill}. Every call is forwarded to
  # the recorder pid (the test process); `spawn` also ships the on_data/on_exit
  # callbacks so the test can push simulated terminal output.
  defmodule FakePty do
    def spawn(_file, _args, opts) do
      rec = Application.get_env(:barkpark, :fake_pty_recorder)

      if is_pid(rec) do
        send(
          rec,
          {:fake_spawn,
           %{
             on_data: Keyword.get(opts, :on_data),
             on_exit: Keyword.get(opts, :on_exit),
             cols: Keyword.get(opts, :cols),
             rows: Keyword.get(opts, :rows)
           }}
        )
      end

      {:ok, %{recorder: rec}}
    end

    def write(%{recorder: rec}, data) do
      if is_pid(rec), do: send(rec, {:fake_write, data})
      :ok
    end

    def resize(%{recorder: rec}, cols, rows) do
      if is_pid(rec), do: send(rec, {:fake_resize, cols, rows})
      :ok
    end

    def kill(%{recorder: rec}, signal) do
      if is_pid(rec), do: send(rec, {:fake_kill, signal})
      :ok
    end
  end

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "tmux admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "tmux junior", "production", ["read"])
    {:ok, conn: conn}
  end

  defp enable_fake_console do
    prev = Application.get_env(:barkpark, :tmux_console)

    Application.put_env(:barkpark, :tmux_console,
      enabled: true,
      backend: FakePty,
      session: "tmux-test",
      # `cat` exists everywhere → find_executable passes; the fake ignores it.
      command: {"cat", []}
    )

    Application.put_env(:barkpark, :fake_pty_recorder, self())

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :tmux_console, prev),
        else: Application.delete_env(:barkpark, :tmux_console)

      Application.delete_env(:barkpark, :fake_pty_recorder)
    end)
  end

  describe "gate" do
    test "disabled → mount redirects even for an admin", %{conn: conn} do
      Application.put_env(:barkpark, :tmux_console, enabled: false)
      on_exit(fn -> Application.put_env(:barkpark, :tmux_console, enabled: false) end)

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/tmux")
    end

    test "enabled but no admin token → admin on_mount redirects", %{conn: conn} do
      enable_fake_console()
      conn = init_test_session(conn, %{})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/tmux")
    end

    test "enabled but token lacks admin → redirects", %{conn: conn} do
      enable_fake_console()
      conn = init_test_session(conn, %{"api_token" => @junior_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/tmux")
    end
  end

  describe "enabled + admin" do
    setup %{conn: conn} do
      enable_fake_console()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, "/studio/tmux")
      {:ok, view: view, html: html}
    end

    test "renders the terminal hook and lazy-loaded xterm source", %{html: html} do
      assert html =~ ~s(phx-hook="TmuxTerminal")
      assert html =~ "/assets/xterm.bundle.js"
      assert html =~ "tmux-test"
    end

    test "surfaces the tmux tab in the top menu, marked active", %{html: html} do
      assert html =~ ~s(href="/studio/tmux")
      # the other built-in tabs are present too (top-menu integration)
      assert html =~ "Structure"
      assert html =~ "studio-tab active"
    end

    test "term-init spawns the PTY at the reported geometry", %{view: view} do
      render_hook(view, "term-init", %{"cols" => 100, "rows" => 30})
      assert_receive {:fake_spawn, %{cols: 100, rows: 30}}
    end

    test "keystrokes decode base64 and reach the PTY", %{view: view} do
      render_hook(view, "term-init", %{"cols" => 80, "rows" => 24})
      assert_receive {:fake_spawn, _}

      render_hook(view, "term-input", %{"d" => Base.encode64("ls -la\n")})
      assert_receive {:fake_write, "ls -la\n"}
    end

    test "PTY output is base64-pushed back to the client", %{view: view} do
      render_hook(view, "term-init", %{"cols" => 80, "rows" => 24})
      assert_receive {:fake_spawn, %{on_data: on_data}}

      # simulate the PTY emitting bytes (incl. a UTF-8 multibyte char)
      on_data.(FakePty, self(), "total 0\r\né\r\n")

      assert_push_event(view, "term-out", %{d: d})
      assert Base.decode64!(d) == "total 0\r\né\r\n"
    end

    test "resize forwards new geometry to the PTY", %{view: view} do
      render_hook(view, "term-init", %{"cols" => 80, "rows" => 24})
      assert_receive {:fake_spawn, _}

      render_hook(view, "term-resize", %{"cols" => 120, "rows" => 40})
      assert_receive {:fake_resize, 120, 40}
    end

    test "the PTY is spawned only once across repeated term-init", %{view: view} do
      render_hook(view, "term-init", %{"cols" => 80, "rows" => 24})
      assert_receive {:fake_spawn, _}

      render_hook(view, "term-init", %{"cols" => 90, "rows" => 25})
      refute_receive {:fake_spawn, _}, 200
    end

    test "an unknown stale event does not crash the LiveView", %{view: view} do
      render_hook(view, "totally-unknown-event", %{})
      assert Process.alive?(view.pid)
    end
  end
end
