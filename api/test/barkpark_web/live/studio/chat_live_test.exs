defmodule BarkparkWeb.Studio.ChatLiveTest do
  @moduledoc """
  Server-half behavior of the Studio Claude chat. The subprocess command is
  overridden via config (`cat` echo — no real `claude`), and stream-json
  events are driven by sending `{:claude_chat_event, …}` straight to the
  LiveView, exactly the shape the Session forwards.

  Wave 1 (studio-claude-chat) inverts the eager-spawn mount: mount lays out the
  chrome + session sidebar and spawns NOTHING; `handle_params/3` is the single
  source of truth; a subprocess starts lazily only on the first send. The tests
  below assert that inversion explicitly (a history-only assertion is vacuous if
  mount eagerly respawns), and prove the resume flag end-to-end through an
  argv-echo `:binary` fake (never the `:command` override — charter D9).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias BarkparkWeb.Studio.ClaudeChat

  @admin_token "chat-admin-test-token"
  @junior_token "chat-junior-test-token"

  # The result handler fire-and-forgets an AI title task (scc-w1-ai-title).
  # These null seams keep every chat test hermetic AND instant: no Anthropic
  # HTTP (even when the host env carries ANTHROPIC_API_KEY), no real `claude`
  # one-shot (15s budget) — the titler falls straight to the derived title.
  defmodule NullTitleAdapter do
    def post(_url, _body, _headers), do: {:error, :disabled_in_tests}
  end

  defmodule NullTitleCli do
    def run(_binary, _args), do: {:error, :disabled_in_tests}
  end

  setup %{conn: conn} do
    {:ok, _} =
      Auth.create_token(@admin_token, "chat admin", "production", ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior_token, "chat junior", "production", ["read"])

    Application.put_env(:barkpark, :studio_chat_title_http_adapter, NullTitleAdapter)
    Application.put_env(:barkpark, :studio_chat_title_cli, NullTitleCli)

    on_exit(fn ->
      Application.delete_env(:barkpark, :studio_chat_title_http_adapter)
      Application.delete_env(:barkpark, :studio_chat_title_cli)
    end)

    {:ok, conn: conn}
  end

  defp enable_fake_chat do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

    # `cat` echoes our own NDJSON back; the LiveView ignores echoed "user"
    # events, so tests drive assistant/result events directly.
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)
  end

  # An argv-echo fake wired as the `:binary` (NOT the `:command` override, which
  # bypasses build_args and would make the flag assertion vacuous — D9). It keeps
  # the CLI's default_args and records its OWN argv (the real `build_args`
  # output) to a marker file on spawn, so the test can prove `--session-id` vs
  # `--resume` reached the subprocess without depending on stdout render timing.
  # Returns the marker path.
  defp enable_argv_echo_chat do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

    suffix = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "bp-argv-echo-#{suffix}.sh")
    marker = Path.join(System.tmp_dir!(), "bp-argv-marker-#{suffix}.txt")

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$@" > #{marker}
    cat
    """)

    File.chmod!(path, 0o755)

    Application.put_env(:barkpark, :claude_chat, enabled: true, binary: path)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      File.rm(path)
      File.rm(marker)

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    marker
  end

  defp read_marker(path, tries \\ 80) do
    cond do
      File.exists?(path) -> File.read!(path)
      tries <= 0 -> flunk("argv marker was never written by the fake binary: #{path}")
      true -> Process.sleep(25) && read_marker(path, tries - 1)
    end
  end

  # Poll an async condition (fire-and-forget title task) to a verdict.
  defp await(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries <= 0 -> flunk("condition never became true")
      true -> Process.sleep(20) && await(fun, tries - 1)
    end
  end

  # LiveView internals — the ONLY honest way to assert "no subprocess started"
  # (a rendered history is identical whether or not mount respawned).
  defp lv_assigns(view), do: :sys.get_state(view.pid).socket.assigns
  defp session_pid(view), do: lv_assigns(view)[:session]
  defp store_id(view), do: lv_assigns(view)[:store_session_id]

  defp seed_session(title, opts \\ []) do
    id = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})
    StudioChat.rename(id, title)
    if status = opts[:status], do: StudioChat.update_status(id, status)
    id
  end

  defp seed_session_with_history do
    id = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})
    {:ok, _} = StudioChat.append_message(id, %{role: "user", source_markdown: "prev question"})

    {:ok, _} =
      StudioChat.append_message(id, %{
        role: "assistant",
        source_markdown: "## Prior answer\n\nSome remembered text."
      })

    id
  end

  # A stored session whose LAST message is an approval left "pending" — the shape
  # a crash or a tab-close leaves behind. Reopen must render it as the honest
  # terminal state (canceled), never a live card no one can resolve.
  defp seed_session_with_pending_approval(request_id) do
    id = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})
    {:ok, _} = StudioChat.append_message(id, %{role: "user", source_markdown: "do a thing"})

    {:ok, _} =
      StudioChat.append_message(id, %{
        role: "approval",
        source_markdown: "Allow Bash?",
        metadata: %{
          "request_id" => request_id,
          "tool_name" => "Bash",
          "input" => %{"command" => "ls"},
          "approval_status" => "pending"
        }
      })

    id
  end

  describe "gate" do
    test "disabled → mount redirects even for an admin", %{conn: conn} do
      Application.put_env(:barkpark, :claude_chat, enabled: false)
      on_exit(fn -> Application.put_env(:barkpark, :claude_chat, enabled: false) end)

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/chat")
    end

    test "enabled but no admin token → admin on_mount redirects", %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/chat")
    end

    test "enabled but token lacks admin → redirects", %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @junior_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/chat")
    end

    test "the :session_id route inherits the same admin gate", %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @junior_token})

      assert {:error, {:redirect, %{to: "/studio"}}} =
               live(conn, "/studio/chat/#{Ecto.UUID.generate()}")
    end

    test "public-demo host hard-refuses even an admin", %{conn: conn} do
      enable_fake_chat()
      Application.put_env(:barkpark, :public_demo_studio, true)

      refute BarkparkWeb.Studio.ClaudeChat.enabled?()

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      assert {:error, {:redirect, %{to: "/studio"}}} = live(conn, "/studio/chat")
    end
  end

  describe "mermaid hook wiring regression guard" do
    # The papers reader had the engine + hook; the Studio layout did not — so
    # chat `diagram` blocks rendered as raw source. This guards the exact
    # three-part wiring (engine script, hook asset, Hooks registration) the
    # same way the TmuxTerminal guard does.
    test "root layout loads the mermaid engine AND the PaperMermaid hook" do
      root = File.read!("lib/barkpark_web/layouts/root.html.heex")

      assert root =~ "mermaid.min.js",
             "root.html.heex must load the mermaid engine, else chat diagrams are raw text"

      assert root =~ "/assets/bp-paper-mermaid.js",
             "root.html.heex must load the PaperMermaid hook asset"

      assert root =~ "Hooks.PaperMermaid",
             "root.html.heex must register PaperMermaid in the LiveSocket Hooks map"

      assert File.exists?("priv/static/assets/bp-paper-mermaid.js")
    end
  end

  describe "the args seam (build_args, charter D9)" do
    test "threads --session-id for a fresh session and --resume for a reopen" do
      fresh = ClaudeChat.build_args("plan", %{session_id: "uuid-1", resume: false})
      assert "--session-id" in fresh
      assert "uuid-1" in fresh
      refute "--resume" in fresh

      resumed = ClaudeChat.build_args("plan", %{session_id: "uuid-1", resume: true})
      assert "--resume" in resumed
      assert "uuid-1" in resumed
      refute "--session-id" in resumed

      # No session opts → neither flag (back-compat).
      bare = ClaudeChat.build_args("plan", %{})
      refute "--session-id" in bare
      refute "--resume" in bare
    end
  end

  describe "enabled + admin" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, html} = live(conn, "/studio/chat")
      {:ok, view: view, html: html}
    end

    # Mount no longer spawns (the eager-spawn contract is inverted): the tab is
    # a new-chat empty state, the composer is enabled immediately, and NO
    # subprocess exists until the first send.
    test "mount is a new-chat state with an enabled composer and no subprocess", %{view: view} do
      assert render(view) =~ "new chat"
      refute has_element?(view, "input[name=message][disabled]")
      refute has_element?(view, "button[type=submit][disabled]")
      assert session_pid(view) == nil
      assert store_id(view) == nil
    end

    test "renders the composer and the chat tab in the top menu", %{html: html} do
      assert html =~ ~s(phx-submit="send")
      assert html =~ ~s(phx-hook="PaperMermaid")
      assert html =~ ~s(href="/studio/chat")
      assert html =~ "studio-tab active"
    end

    test "sending a message renders the user bubble and goes to working", %{view: view} do
      html = render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hei Claude"})
      assert html =~ "hei Claude"
      assert html =~ "working"
    end

    test "an empty message is ignored", %{view: view} do
      html = render_submit(element(view, "form[phx-submit=send]"), %{"message" => "   "})
      refute html =~ "working"
    end

    test "init event surfaces the model in the header", %{view: view} do
      send(
        view.pid,
        {:claude_chat_event, %{"type" => "system", "subtype" => "init", "model" => "opus-x"}}
      )

      assert render(view) =~ "opus-x"
    end

    test "text deltas stream into an in-progress bubble", %{view: view} do
      send(view.pid, {:claude_chat_event, stream_delta("Hel")})
      send(view.pid, {:claude_chat_event, stream_delta("lo!")})
      assert render(view) =~ "Hello!"
    end

    test "completed blocks render as components BEFORE the message finishes", %{view: view} do
      send(view.pid, {:claude_chat_event, stream_delta("## Findings\n")})
      send(view.pid, {:claude_chat_event, stream_delta("\nstill typing")})

      html = render(view)
      # the finished heading block is already paper-rendered mid-stream…
      assert html =~ "Findings"
      refute html =~ "## Findings"
      # …while the unfinished tail stays plain text with the cursor
      assert html =~ "still typing"
      assert html =~ "▌"
    end

    test "an unclosed fence shows a skeleton, never half-rendered source", %{view: view} do
      send(view.pid, {:claude_chat_event, stream_delta("```mermaid\ngraph TD\n")})
      send(view.pid, {:claude_chat_event, stream_delta("\n\nA-->B")})

      html = render(view)
      # boundary must not advance into the open fence — and the forming
      # diagram shows as its dedicated skeleton, not raw source noise
      assert html =~ ~s(data-skel="diagram")
      assert html =~ "rendering diagram"
      refute html =~ "graph TD"
    end

    test "each forming component gets its dedicated skeleton", %{view: view} do
      checks = [
        {~s(```portabledoc\n[{"type":"chart","kind":"bars"), "chart"},
        {~s(```portabledoc\n[{"type":"stats","items":[), "stats"},
        {~s(```portabledoc\n[{"type":"callout","tone"), "callout"},
        {~s(```elixir\nIO.puts), "code"},
        {"| Name | N |\n| --- |", "table"},
        {"> important note about", "callout"}
      ]

      for {tail, kind} <- checks do
        # reset the stream between probes via a completed message
        send(
          view.pid,
          {:claude_chat_event,
           %{
             "type" => "assistant",
             "message" => %{"content" => [%{"type" => "text", "text" => "."}]}
           }}
        )

        send(view.pid, {:claude_chat_event, stream_delta(tail)})
        html = render(view)
        assert html =~ ~s(data-skel="#{kind}"), "expected #{kind} skeleton for #{inspect(tail)}"
      end
    end

    test "at most ONE skeleton renders at a time, even with multiple fence starts", %{view: view} do
      # a completed mini-fence followed by an open one: fence count is odd, the
      # classifier keys on the LAST fence — exactly one skeleton may render
      send(
        view.pid,
        {:claude_chat_event, stream_delta("```elixir\n:ok\n```\n```mermaid\ngraph TD\n")}
      )

      html = render(view)
      occurrences = html |> String.split("data-skel=") |> length() |> Kernel.-(1)
      assert occurrences == 1, "expected exactly one skeleton, got #{occurrences}"
      assert html =~ ~s(data-skel="diagram")
    end

    test "skeleton shapes use the primary fill, never the invisible border tone", %{view: view} do
      send(view.pid, {:claude_chat_event, stream_delta("```mermaid\ngraph")})
      html = render(view)
      assert html =~ "bp-skel-shape"
      # regression: dark-theme --border-muted is an 11%-lightness gray — shapes
      # filled with it are invisible. The stylesheet must key on the primary
      # token (no literal fallback — the studio-literal-check gate forbids it).
      assert html =~ "background: var(--primary"
      refute html =~ "background: var(--border-muted"
    end

    test "prose before a forming component still streams as text", %{view: view} do
      send(
        view.pid,
        {:claude_chat_event, stream_delta("Here is the diagram:\n```mermaid\ngraph")}
      )

      html = render(view)
      assert html =~ "Here is the diagram:"
      assert html =~ ~s(data-skel="diagram")
    end

    test "the skeleton yields to the real component when the block completes", %{view: view} do
      send(
        view.pid,
        {:claude_chat_event, stream_delta(~s(```portabledoc\n[{"type":"divider"}]))}
      )

      assert render(view) =~ "data-skel"

      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{"type" => "text", "text" => ~s(```portabledoc\n[{"type":"divider"}]\n```)}
             ]
           }
         }}
      )

      html = render(view)
      refute html =~ "data-skel"
      assert html =~ "bp-paper-surface"
    end

    test "the complete assistant message supersedes the streamed preview", %{view: view} do
      send(view.pid, {:claude_chat_event, stream_delta("Hel")})

      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{"content" => [%{"type" => "text", "text" => "Hello, final."}]}
         }}
      )

      html = render(view)
      assert html =~ "Hello, final."
      refute html =~ "▌"
    end

    test "assistant markdown renders through the paper engine", %{view: view} do
      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{
                 "type" => "text",
                 "text" =>
                   "## Findings\n\nSome **bold** truth.\n\n```portabledoc\n[{\"type\":\"callout\",\"tone\":\"success\",\"content\":[{\"type\":\"text\",\"value\":\"native block\"}]}]\n```"
               }
             ]
           }
         }}
      )

      html = render(view)
      assert html =~ "bp-paper-surface"
      assert html =~ "Findings"
      assert html =~ "native block"
      # markdown syntax must not leak through as literal text
      refute html =~ "**bold**"
      refute html =~ "## Findings"
    end

    test "model HTML in a reply is escaped, never executed", %{view: view} do
      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [%{"type" => "text", "text" => "hi <script>alert(1)</script>"}]
           }
         }}
      )

      refute render(view) =~ "<script>alert(1)"
    end

    test "tool_use blocks render as dim activity lines", %{view: view} do
      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "name" => "Read",
                 "input" => %{"file_path" => "/etc/hosts"}
               }
             ]
           }
         }}
      )

      html = render(view)
      assert html =~ "Read"
      assert html =~ "/etc/hosts"
    end

    test "a result event returns the chat to ready with usage in the footer", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})

      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "result",
           "subtype" => "success",
           "duration_ms" => 1500,
           "total_cost_usd" => 0.0123
         }}
      )

      html = render(view)
      assert html =~ "ready"
      assert html =~ "1.5s"
    end

    test "an error result surfaces a system line", %{view: view} do
      send(
        view.pid,
        {:claude_chat_event, %{"type" => "result", "subtype" => "error_during_execution"}}
      )

      assert render(view) =~ "error_during_execution"
    end

    test "subprocess exit flips the chat offline with a system line", %{view: view} do
      send(view.pid, {:claude_chat_exit, 1})
      html = render(view)
      assert html =~ "offline"
      assert html =~ "exit 1"
    end

    test "a permission ask renders an approval card; Allow resolves it", %{view: view} do
      # approvals only happen inside a live turn — spawn one first
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "act"})

      send(
        view.pid,
        {:claude_chat_permission,
         %{
           request_id: "req-7",
           tool_name: "Write",
           input: %{"file_path" => "/opt/x.txt"},
           title: "Claude wants to write /opt/x.txt",
           decision_reason: nil
         }}
      )

      html = render(view)
      assert html =~ "Allow Write?"
      assert html =~ "Claude wants to write /opt/x.txt"
      assert html =~ ~s(phx-click="approve")

      html = render_click(element(view, ~s(button[phx-click=approve][phx-value-rid=req-7])))
      assert html =~ "✓ allowed"
      refute html =~ "Allow Write?"
    end

    test "Deny resolves the card as denied", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "act"})

      send(
        view.pid,
        {:claude_chat_permission,
         %{request_id: "req-8", tool_name: "Bash", input: %{}, title: nil, decision_reason: nil}}
      )

      html = render_click(element(view, ~s(button[phx-click=deny][phx-value-rid=req-8])))
      assert html =~ "✗ denied"
    end

    test "a stale approval click after resolution is a no-op", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "act"})

      send(
        view.pid,
        {:claude_chat_permission,
         %{request_id: "req-9", tool_name: "Bash", input: %{}, title: nil, decision_reason: nil}}
      )

      render_click(element(view, ~s(button[phx-click=approve][phx-value-rid=req-9])))
      # second click on the (now gone) card — drive the event directly
      render_hook(view, "deny", %{"rid" => "req-9"})
      html = render(view)
      assert html =~ "✓ allowed"
      refute html =~ "✗ denied"
    end

    test "switching mode steers the LIVE session in place (no respawn, no teardown)",
         %{view: view} do
      # spawn is lazy now — establish a live subprocess, then finish the turn
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      send(view.pid, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})
      pid_before = session_pid(view)
      refute pid_before == nil

      html = render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "default"})
      # the mode change is recorded honestly with the friendly label…
      assert html =~ "Permission mode → ask to act"
      assert html =~ "ask to act"
      # …and the session is steered in place, never respawned or torn down —
      # the old context-destroying respawn path is gone (charter D12).
      refute html =~ "New session started"
      assert session_pid(view) == pid_before
      assert html =~ "ready"
    end

    test "mode change with no live session just updates the selector", %{view: view} do
      html = render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "default"})
      refute html =~ "New session started"
      assert html =~ "ask to act"
      assert session_pid(view) == nil
    end

    test "mode selector clamps junk to plan (no-op when already plan)", %{view: view} do
      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "bypassPermissions"})

      html = render(view)
      refute html =~ "Permission mode → bypass"
      assert html =~ "plan (read-only)"
    end

    # ── honest turn outcomes (scc-w1-honest-turns) ───────────────────────

    test "while a turn runs, Stop replaces Send (attribute-level, not disabled)", %{view: view} do
      # render_submit bypasses the disabled attribute, so assert on the button
      # IDENTITY, not on disabled: the submit button is GONE, Stop is present.
      refute has_element?(view, ~s(form[phx-submit=send] button[phx-click=stop_turn]))
      assert has_element?(view, ~s(form[phx-submit=send] button[type=submit]))

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})

      assert has_element?(view, ~s(form[phx-submit=send] button[phx-click=stop_turn]))
      refute has_element?(view, ~s(form[phx-submit=send] button[type=submit]))
    end

    test "there is no send queue — a submit while a turn runs is a server-side no-op",
         %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "first turn"})
      # render_submit bypasses the missing submit button, so this proves the
      # SERVER refuses the overlapping send, not just the hidden button.
      html = render_submit(element(view, "form[phx-submit=send]"), %{"message" => "second turn"})
      refute html =~ "second turn"
      assert html =~ "first turn"
    end

    test "Stop interrupts the turn; the interrupted result keeps the session live", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      render_click(element(view, ~s(button[phx-click=stop_turn])))
      assert render(view) =~ "stopping"

      # the interrupt lands as error_during_execution + aborted_streaming…
      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "result",
           "subtype" => "error_during_execution",
           "terminal_reason" => "aborted_streaming"
         }}
      )

      html = render(view)
      # …but it reads as an interrupt, never a failure, and the session lives on
      assert html =~ "Interrupted"
      refute html =~ "ended with an error"
      assert html =~ "ready"
      assert has_element?(view, ~s(form[phx-submit=send] button[type=submit]))
    end

    test "an aborted_streaming result reads as interrupted even without a prior Stop",
         %{view: view} do
      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "result",
           "subtype" => "error_during_execution",
           "terminal_reason" => "aborted_streaming"
         }}
      )

      html = render(view)
      assert html =~ "Interrupted"
      refute html =~ "ended with an error"
    end

    test "a genuine error result still surfaces as an error (not interrupted)", %{view: view} do
      # no interrupt_requested, no aborted_streaming → a real failure
      send(
        view.pid,
        {:claude_chat_event, %{"type" => "result", "subtype" => "error_max_turns"}}
      )

      html = render(view)
      assert html =~ "ended with an error"
      assert html =~ "error_max_turns"
      refute html =~ "Interrupted"
    end

    test "a subprocess crash force-cancels every pending approval to ✗ canceled", %{view: view} do
      send(
        view.pid,
        {:claude_chat_permission,
         %{
           request_id: "req-crash",
           tool_name: "Bash",
           input: %{"command" => "rm -rf /tmp/x"},
           title: nil,
           decision_reason: nil
         }}
      )

      assert has_element?(view, ~s(button[phx-click=approve][phx-value-rid=req-crash]))

      send(view.pid, {:claude_chat_exit, 1})
      html = render(view)

      # POSITIVELY assert the cancellation, then refute the live buttons — a
      # dead Allow/Deny post-exit would be a button that lies.
      assert html =~ "✗ canceled"
      refute has_element?(view, ~s(button[phx-click=approve][phx-value-rid=req-crash]))
      refute has_element?(view, ~s(button[phx-click=deny][phx-value-rid=req-crash]))
      assert html =~ "offline"
    end

    test "an unknown stale event does not crash the LiveView", %{view: view} do
      render_hook(view, "totally-unknown-event", %{})
      send(view.pid, {:claude_chat_event, %{"type" => "mystery"}})
      assert Process.alive?(view.pid)
    end
  end

  describe "sessions become a place (persistence + resume, S3)" do
    setup %{conn: conn} do
      enable_fake_chat()
      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    test "the sidebar teaches when there are no sessions yet", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/chat")
      assert html =~ "No chats yet"
      assert html =~ "remembered agent workspace"
    end

    test "the sidebar lists sessions recency-desc with tokenized status pills", %{conn: conn} do
      older = seed_session("Older chat")
      # nudge recency so the ordering is deterministic
      StudioChat.update_status(older, "active")
      Process.sleep(5)
      _newer = seed_session("Newer chat", status: "working")

      {:ok, _view, html} = live(conn, "/studio/chat")

      assert html =~ "Older chat"
      assert html =~ "Newer chat"
      # recency-desc: the more-recently-active session appears first in the DOM
      {newer_at, _} = :binary.match(html, "Newer chat")
      {older_at, _} = :binary.match(html, "Older chat")
      assert newer_at < older_at
      # tokenized lifecycle pills (never the undefined .bp-pill)
      assert html =~ "badge-chat-working"
      refute html =~ "bp-pill"
    end

    test "reopening a stored session replays its history with NO spawn", %{conn: conn} do
      sid = seed_session_with_history()
      {:ok, view, html} = live(conn, "/studio/chat/#{sid}")

      # the persisted history is on screen, assistant markdown re-rendered
      # through the paper engine (heading text, not raw markdown syntax)
      assert html =~ "prev question"
      assert html =~ "Prior answer"
      assert html =~ "bp-paper-surface"
      # the transcript rendered the heading as HTML, not as literal source
      refute html =~ "## Prior answer"

      # …and NOTHING was spawned (the vacuous-green trap: a rendered history is
      # identical whether or not mount respawned — assert the assign directly)
      assert session_pid(view) == nil
      assert store_id(view) == sid
    end

    test "a fresh send mints a session, patches to its url, and persists the user message",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")
      assert session_pid(view) == nil

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hello there"})

      sid = store_id(view)
      assert is_binary(sid)
      assert_patched(view, "/studio/chat/#{sid}")

      # the user message is persisted (source markdown, D7)
      roles = StudioChat.list_messages(sid) |> Enum.map(&{&1.role, &1.source_markdown})
      assert {"user", "hello there"} in roles
    end

    test "streaming deltas never write to the store; completion does", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "start"})
      sid = store_id(view)
      # the user send persisted exactly one row
      assert StudioChat.get_session(sid).message_count == 1

      # streaming deltas must NOT touch the store
      send(view.pid, {:claude_chat_event, stream_delta("partial ")})
      send(view.pid, {:claude_chat_event, stream_delta("answer")})
      render(view)
      assert StudioChat.get_session(sid).message_count == 1

      # the completed assistant message persists (on the message boundary)
      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{"content" => [%{"type" => "text", "text" => "done"}]}
         }}
      )

      render(view)
      assert StudioChat.get_session(sid).message_count == 2
    end

    test "a result frame records usage metrics onto the session", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "measure me"})
      sid = store_id(view)

      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "result",
           "subtype" => "success",
           "duration_ms" => 900,
           "total_cost_usd" => 0.02,
           "usage" => %{"input_tokens" => 111, "output_tokens" => 22}
         }}
      )

      render(view)
      s = StudioChat.get_session(sid)
      assert s.input_tokens == 111
      assert s.output_tokens == 22
      assert_in_delta s.total_cost_usd, 0.02, 0.0001
      assert s.status == "active"
    end

    test "switching sessions via a sidebar patch link keeps the same LiveView pid", %{conn: conn} do
      sid1 = seed_session("Alpha")
      sid2 = seed_session("Beta")

      {:ok, view, _html} = live(conn, "/studio/chat/#{sid1}")
      pid = view.pid
      assert store_id(view) == sid1

      view |> element(~s(a[href="/studio/chat/#{sid2}"])) |> render_click()

      assert view.pid == pid
      assert_patched(view, "/studio/chat/#{sid2}")
      assert store_id(view) == sid2
    end

    test "a missing session id falls back to the new-chat state with a notice", %{conn: conn} do
      ghost = Ecto.UUID.generate()
      {:ok, view, html} = live(conn, "/studio/chat/#{ghost}")
      assert store_id(view) == nil
      assert session_pid(view) == nil
      assert html =~ "No chats yet"
    end

    test "the first successful turn kicks an async AI title that lands in the sidebar",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")

      render_submit(
        element(view, "form[phx-submit=send]"),
        %{"message" => "Refactor the auth layer"}
      )

      sid = store_id(view)
      assert StudioChat.get_session(sid).title_source == "default"

      send(view.pid, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})
      render(view)

      # The titler runs fire-and-forget: with the null API/CLI seams it falls
      # to the derived title, lands via the canonical clobber-guarded store,
      # and the {:chat_title, …} notify refreshes the sidebar.
      await(fn -> StudioChat.get_session(sid).title_source == "ai" end)
      assert StudioChat.get_session(sid).title == "Refactor the auth layer"
      assert render(view) =~ "Refactor the auth layer"
    end
  end

  describe "approvals that survive (persistence + reopen, scc-w2)" do
    setup %{conn: conn} do
      enable_fake_chat()
      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    test "an ask persists a pending row and raises the 'needs you' sidebar pill", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "act"})
      sid = store_id(view)

      send(
        view.pid,
        {:claude_chat_permission,
         %{
           request_id: "req-live",
           tool_name: "Write",
           input: %{"file_path" => "/opt/x"},
           title: "Claude wants to write /opt/x",
           decision_reason: nil
         }}
      )

      html = render(view)
      # the sidebar elevates this session with the warn-toned pending pill…
      assert html =~ "badge-chat-approval"
      assert html =~ "needs you"
      # …and it is PERSISTED, not just in-memory (survives a crash / reopen)
      assert StudioChat.get_session(sid).pending_approvals == 1

      rows = StudioChat.list_messages(sid) |> Enum.filter(&(&1.role == "approval"))
      assert [%{metadata: %{"approval_status" => "pending", "request_id" => "req-live"}}] = rows
    end

    test "resolving an ask clears the persisted pending count and the pill", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "act"})
      sid = store_id(view)

      send(
        view.pid,
        {:claude_chat_permission,
         %{request_id: "req-live", tool_name: "Write", input: %{}, title: nil, decision_reason: nil}}
      )

      render(view)
      assert StudioChat.get_session(sid).pending_approvals == 1

      html = render_click(element(view, ~s(button[phx-click=approve][phx-value-rid=req-live])))
      assert html =~ "✓ allowed"
      # the store agrees with the screen: the terminal state is persisted…
      approval = StudioChat.list_messages(sid) |> Enum.find(&(&1.role == "approval"))
      assert approval.metadata["approval_status"] == "allowed"
      # …and the pending count dropped, so the sidebar pill is no longer "needs you"
      assert StudioChat.get_session(sid).pending_approvals == 0
      refute html =~ "needs you"
    end

    test "reopening a session with a dangling pending approval renders ✗ canceled and persists it",
         %{conn: conn} do
      sid = seed_session_with_pending_approval("req-dangling")
      # the seeded ask really is pending in the store before reopen
      assert StudioChat.get_session(sid).pending_approvals == 1

      {:ok, view, html} = live(conn, "/studio/chat/#{sid}")

      # NO live card no one can resolve — the honest terminal state instead…
      assert html =~ "✗ canceled"
      refute has_element?(view, ~s(button[phx-click=approve][phx-value-rid=req-dangling]))
      refute has_element?(view, ~s(button[phx-click=deny][phx-value-rid=req-dangling]))
      # …and reopen was DISPLAY-only (no spawn — the vacuous-green trap)
      assert session_pid(view) == nil

      # the flip is PERSISTED: reopening again cannot revive the dead card
      assert StudioChat.get_session(sid).pending_approvals == 0

      approval = StudioChat.list_messages(sid) |> Enum.find(&(&1.role == "approval"))
      assert approval.metadata["approval_status"] == "canceled"
    end
  end

  describe "resume flag end-to-end (argv-echo :binary fake, D9)" do
    setup %{conn: conn} do
      marker = enable_argv_echo_chat()
      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token}), marker: marker}
    end

    test "the first send after reopening resumes the CLI with --resume <uuid>",
         %{conn: conn, marker: marker} do
      sid = seed_session_with_history()
      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
      # reopen did not spawn — the resume happens lazily on this send
      assert session_pid(view) == nil

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "continue please"})

      # the fake binary recorded the argv the real build_args produced
      argv = read_marker(marker)
      assert argv =~ "--resume"
      assert argv =~ sid
      refute argv =~ "--session-id"
    end

    test "a fresh send spawns with --session-id (never --resume)",
         %{conn: conn, marker: marker} do
      {:ok, view, _html} = live(conn, "/studio/chat")

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "brand new"})

      sid = store_id(view)
      argv = read_marker(marker)
      assert argv =~ "--session-id"
      assert argv =~ sid
      refute argv =~ "--resume"
    end
  end

  defp stream_delta(text) do
    %{
      "type" => "stream_event",
      "event" => %{
        "type" => "content_block_delta",
        "delta" => %{"type" => "text_delta", "text" => text}
      }
    }
  end
end
