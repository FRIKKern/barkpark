defmodule BarkparkWeb.Studio.ChatModeSteerUnsupportedTest do
  @moduledoc """
  task-9ae8a0c89d9209b5: the /plan and /autopilot builtins and the header mode
  toggle reach `change_mode/2`, which steered a live session and matched
  `{:ok, request_id}` on the answer. A live managed codex session answers a
  mode steer `{:error, {:unsupported_steer, _}}` (PR #26293: its app-server
  has no request that changes a running thread's approval policy), so the
  match raised and the chat page crashed.

  The runtime here is the REAL codex adapter and Session over the hermetic
  app-server fake (`test/fixtures/codex_app_server/fake_app_server.py`); only
  the binary, its args and the readiness probe are swapped, so the steer answer
  is the one production gives.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.TestTmp

  @admin_token "chat-mode-steer-unsupported-admin-token"
  @fake_app_server Path.expand("../../../fixtures/codex_app_server/fake_app_server.py", __DIR__)

  defmodule NullTitleAdapter do
    def post(_url, _body, _headers), do: {:error, :disabled_in_tests}
  end

  defmodule NullTitleCli do
    def run(_binary, _args), do: {:error, :disabled_in_tests}
  end

  # The real codex adapter, started on the fake app-server.
  defmodule FakeAppServerCodex do
    @behaviour Barkpark.StudioChat.Runtime.Adapter

    alias Barkpark.StudioChat.Runtime.Codex

    def start(opts), do: Codex.start(fake(opts))
    def resume(opts), do: Codex.resume(fake(opts))
    defdelegate send_turn(runtime, content), to: Codex
    defdelegate steer(runtime, command), to: Codex
    defdelegate interrupt(runtime), to: Codex
    defdelegate answer_approval(runtime, approval_id, decision), to: Codex
    defdelegate close(runtime), to: Codex
    defdelegate capabilities(), to: Codex
    defdelegate worker_id(session_id), to: Codex
    defdelegate task_hands(runtime), to: Codex
    def readiness(_opts), do: %{binary: true, authed?: true}
    def enabled?, do: true

    defp fake(opts) do
      Map.merge(opts, %{
        binary: Application.fetch_env!(:barkpark, :mode_steer_test_fake_binary),
        args: [
          "--scenario",
          "normal",
          "--log",
          Application.fetch_env!(:barkpark, :mode_steer_test_log)
        ],
        timeout_ms: :infinity
      })
    end
  end

  setup %{conn: conn} do
    Barkpark.ChatSessionResidue.purge!()

    {:ok, _} =
      Auth.create_token(
        @admin_token,
        "chat admin",
        "production",
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    log = TestTmp.path("mode_steer_unsupported_#{System.unique_integer([:positive])}.jsonl")

    prev = %{
      claude_chat: Application.get_env(:barkpark, :claude_chat),
      public_demo_studio: Application.get_env(:barkpark, :public_demo_studio),
      studio_chat_runtime_adapters: Application.get_env(:barkpark, :studio_chat_runtime_adapters)
    }

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    Application.put_env(
      :barkpark,
      :studio_chat_runtime_adapters,
      Map.put(prev.studio_chat_runtime_adapters || %{}, :codex, FakeAppServerCodex)
    )

    Application.put_env(:barkpark, :mode_steer_test_fake_binary, @fake_app_server)
    Application.put_env(:barkpark, :mode_steer_test_log, log)
    Application.put_env(:barkpark, :studio_chat_title_http_adapter, NullTitleAdapter)
    Application.put_env(:barkpark, :studio_chat_title_cli, NullTitleCli)

    on_exit(fn ->
      if Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
        for {_, pid, _, _} <-
              DynamicSupervisor.which_children(Barkpark.StudioChat.RuntimeSupervisor),
            is_pid(pid),
            do: DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)
      end

      for {key, val} <- prev do
        if is_nil(val),
          do: Application.delete_env(:barkpark, key),
          else: Application.put_env(:barkpark, key, val)
      end

      for key <- ~w(mode_steer_test_fake_binary mode_steer_test_log
                    studio_chat_title_http_adapter studio_chat_title_cli)a,
          do: Application.delete_env(:barkpark, key)

      File.rm(log)
    end)

    {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token}), log: log}
  end

  defp lv_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp await(fun, tries \\ 200) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && await(fun, tries - 1)
    end
  end

  # A live managed codex session: pick codex before the first send, send one
  # turn, and wait until the fake app-server has the turn/start on its stdin.
  defp live_codex_session!(conn, log) do
    {:ok, view, _html} = live(conn, "/studio/chat")
    render_change(element(view, ~s(form[phx-change=set-provider])), %{"provider" => "codex"})
    render_submit(element(view, "form[phx-submit=send]"), %{"message" => "codex turn one"})

    assert await(fn -> is_map(lv_assigns(view)[:session]) end),
           "the codex session did not come up"

    assert await(fn -> File.exists?(log) and File.read!(log) =~ "turn/start" end)
    view
  end

  for builtin <- ["/plan", "/autopilot"] do
    test "#{builtin} on a live codex session keeps the page and says the mode cannot change",
         %{conn: conn, log: log} do
      view = live_codex_session!(conn, log)
      mode_before = lv_assigns(view)[:mode]
      sid = lv_assigns(view)[:store_session_id]

      html =
        render_submit(element(view, "form[phx-submit=send]"), %{"message" => unquote(builtin)})

      assert Process.alive?(view.pid)
      # As it renders: HTML-escaped ("can&#39;t").
      assert html =~
               "This Codex session can&#39;t change its permission mode while it runs."

      # Nothing moved: the selector, the pending switch and the saved row all
      # still hold the mode the session runs in.
      assert lv_assigns(view)[:mode] == mode_before
      assert lv_assigns(view)[:pending_mode] == nil
      assert StudioChat.get_session(sid).mode == mode_before

      # And nothing went to the app-server: a mode steer has no request there.
      refute File.read!(log) =~ "turn/steer"
    end
  end
end
