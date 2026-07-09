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

  # A successful result frame whose context occupancy is `input` tokens against a
  # 200k window — drives the header ring to `input / 200000`.
  defp big_result(input) do
    %{
      "type" => "result",
      "subtype" => "success",
      "total_cost_usd" => 0.01,
      "usage" => %{
        "input_tokens" => input,
        "output_tokens" => 0,
        "cache_read_input_tokens" => 0,
        "cache_creation_input_tokens" => 0
      },
      "modelUsage" => %{"claude-opus-4" => %{"contextWindow" => 200_000}}
    }
  end

  # Establish a LIVE session whose subprocess does NOT loop our control frames
  # back. Plain `cat` echoes every control_request, and our own dispatch answers
  # each with an error control_response that `cat` echoes AGAIN — minting a
  # spurious EMPTY set_mode ack that races the ack under test (with the real
  # binary there is no such loopback). `cat >/dev/null` keeps stdin open (port
  # alive) and stays silent, so the only acks the LV sees are the ones the test
  # injects — exactly the shape the Session forwards from the real CLI.
  defp spawn_silent_session(view) do
    Application.put_env(:barkpark, :claude_chat,
      enabled: true,
      command: {"sh", ["-c", "cat >/dev/null"]}
    )

    render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
    send(view.pid, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})
    refute session_pid(view) == nil
    :ok
  end

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

    # Single-writer honesty (charter D20): when another tab adopts this session,
    # the Session sends {:claude_chat_detached}. The composer must be REPLACED by
    # an honest banner — never left live to spawn a second `claude --resume`
    # writer — with a Take-over affordance to re-acquire it.
    test "a detach notice freezes the composer behind a take-over banner", %{view: view} do
      send(view.pid, {:claude_chat_detached})
      html = render(view)

      assert html =~ "open in another tab"
      assert html =~ "Take over here"
      assert html =~ ~s(phx-click="take_over")
      # the send form is gone while detached — no path to a second writer
      refute has_element?(view, "form[phx-submit=send]")
    end

    test "take over dismisses the banner and restores the composer", %{view: view} do
      send(view.pid, {:claude_chat_detached})
      refute has_element?(view, "form[phx-submit=send]")

      render_click(element(view, "button[phx-click=take_over]"))

      assert has_element?(view, "form[phx-submit=send]")
      # the banner + its button are gone (the persisted system line still quotes
      # the phrase, so assert the control element, not raw text)
      refute has_element?(view, "button[phx-click=take_over]")
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

    # ── context-headroom ring (charter D19) ─────────────────────────────────

    test "the header ring is hollow (honest unknown) before any result", %{view: view} do
      # A fresh mount has no context snapshot — no fake arc, an em-dash, and a
      # title that names the unknown.
      html = render(view)
      assert html =~ "Context window unknown until the first result"
      refute html =~ "stroke-dasharray"
    end

    test "a result frame fills the ring geometry-first + shows cost", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})

      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "result",
           "subtype" => "success",
           "total_cost_usd" => 0.05,
           "usage" => %{
             "input_tokens" => 60_000,
             "output_tokens" => 4_000,
             "cache_read_input_tokens" => 0,
             "cache_creation_input_tokens" => 0
           },
           "modelUsage" => %{"claude-opus-4" => %{"contextWindow" => 200_000}}
         }}
      )

      html = render(view)
      # 64000 / 200000 = 32% — the arc length IS the ratio (geometry encodes it).
      assert html =~ "stroke-dasharray"
      assert html =~ "32%"
      # 32% is below 70% → the ok token, never warn/danger.
      assert html =~ "var(--ok)"
      assert html =~ "Context: 64000 / 200000 tokens"
      assert html =~ "$0.0500"
    end

    test "reopening a stored session shows its last-known headroom", %{view: view} do
      id = seed_session("resumed chat")

      # A near-full window (185k / 200k = 93%) — the danger ramp.
      {:ok, _} =
        StudioChat.record_result_metrics(id, %{input_tokens: 185_000, context_window: 200_000})

      html = render_patch(view, "/studio/chat/#{id}")

      assert html =~ "93%"
      assert html =~ "var(--danger)"
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

    # ── control acks: the UI never lies about a mode switch (scc-w2/w3, D17/D23) ──
    #
    # The ack is now correlated by request_id — the LV records the minted id in
    # `:pending_mode`, so a test reads it from assigns to forge a matching ack.

    defp pending_mode_req(view), do: lv_assigns(view)[:pending_mode][:req]

    test "a confirmed mode echo keeps the switch and posts no revert line", %{view: view} do
      spawn_silent_session(view)

      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "default"})
      rid = pending_mode_req(view)
      # the CLI echoes back exactly the mode we asked for → confirmed
      send(view.pid, {:claude_chat_control, :set_mode, rid, %{"mode" => "default"}})

      html = render(view)
      assert html =~ "ask to act"
      refute html =~ "Couldn't switch permission mode"
      # confirmed = persisted: the store's mode is the ACKED value (D23), and the
      # pending marker is cleared.
      assert lv_assigns(view)[:pending_mode] == nil
      assert StudioChat.get_session(store_id(view)).mode == "default"
    end

    test "an empty mode echo reverts the optimistic selector + posts an honest line",
         %{view: view} do
      spawn_silent_session(view)

      # optimistic switch to acceptEdits…
      html =
        render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "acceptEdits"})

      assert html =~ "auto-accept edits"
      rid = pending_mode_req(view)

      # …but the CLI's ack carries an EMPTY response (the silent-no-op trap, D12):
      # we must NOT trust subtype:success, so the switch reverts to plan.
      send(view.pid, {:claude_chat_control, :set_mode, rid, %{}})
      html = render(view)
      assert html =~ "switch permission mode"
      assert html =~ "plan (read-only)"
      # revert persists too: the store never keeps a mode the CLI refused.
      assert StudioChat.get_session(store_id(view)).mode == "plan"
    end

    test "a mismatched mode echo reverts to the prior mode", %{view: view} do
      spawn_silent_session(view)

      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "acceptEdits"})
      rid = pending_mode_req(view)
      # the CLI reports a DIFFERENT mode than we asked → the switch did not take
      send(view.pid, {:claude_chat_control, :set_mode, rid, %{"mode" => "plan"}})

      html = render(view)
      assert html =~ "switch permission mode"
      assert html =~ "plan (read-only)"
    end

    test "a stale ack from a superseded rapid switch is ignored (no mis-revert)",
         %{view: view} do
      spawn_silent_session(view)

      # rapid double switch: acceptEdits (req A) then default (req B) before any ack
      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "acceptEdits"})
      rid_a = pending_mode_req(view)
      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "default"})
      rid_b = pending_mode_req(view)
      refute rid_a == rid_b

      # req A's ack lands LATE echoing acceptEdits. Value-matching (the wave-2 bug)
      # would see echo "acceptEdits" != current "default" and MIS-REVERT. By
      # request_id it is stale (B superseded it) → ignored, mode stays default.
      send(view.pid, {:claude_chat_control, :set_mode, rid_a, %{"mode" => "acceptEdits"}})
      html = render(view)
      assert html =~ "ask to act"
      refute html =~ "Couldn't switch permission mode"

      # req B's ack then confirms default honestly.
      send(view.pid, {:claude_chat_control, :set_mode, rid_b, %{"mode" => "default"}})
      html = render(view)
      assert html =~ "ask to act"
      refute html =~ "Couldn't switch permission mode"
      assert lv_assigns(view)[:pending_mode] == nil
      assert StudioChat.get_session(store_id(view)).mode == "default"
    end

    # ── compaction is visible, not a silent ring reset (scc-w3, D27) ──────────

    test "an auto compact_boundary posts an honest ephemeral system line", %{view: view} do
      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "system",
           "subtype" => "compact_boundary",
           "compact_metadata" => %{"trigger" => "auto", "pre_tokens" => 152_000}
         }}
      )

      html = render(view)
      assert html =~ "compacted automatically"
      assert html =~ "152000"
    end

    test "a manual compact_boundary names the manual trigger", %{view: view} do
      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "system",
           "subtype" => "compact_boundary",
           "compact_metadata" => %{"trigger" => "manual", "pre_tokens" => 90_000}
         }}
      )

      assert render(view) =~ "compacted manually"
    end

    test "after compaction a smaller result frame shrinks the ring (SET, never summed)",
         %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})

      # a near-full window pre-compaction: 180k / 200k = 90%
      send(view.pid, {:claude_chat_event, big_result(180_000)})
      html = render(view)
      assert html =~ "90%"

      # the CLI compacts…
      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "system",
           "subtype" => "compact_boundary",
           "compact_metadata" => %{"trigger" => "auto", "pre_tokens" => 180_000}
         }}
      )

      # …and the NEXT turn reports far fewer context tokens. Because the snapshot
      # is SET (not summed), the ring shrinks to the post-compaction reality. If
      # someone regressed the formula to `inc:`, 180k+40k would clamp at 100% and
      # this refute would fail — the guard.
      send(view.pid, {:claude_chat_event, big_result(40_000)})
      html = render(view)
      assert html =~ "20%"
      refute html =~ "90%"
    end

    # ── Stopping… cannot wedge (scc-w2, D18) ──────────────────────────────

    test "a wedged interrupt times out, force-closes, and frees the composer", %{view: view} do
      Application.put_env(:barkpark, :studio_chat_interrupt_timeout_ms, 60)
      on_exit(fn -> Application.delete_env(:barkpark, :studio_chat_interrupt_timeout_ms) end)

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      render_click(element(view, ~s(button[phx-click=stop_turn])))
      assert render(view) =~ "stopping"

      # NO terminal result arrives — the CLI wedged. The timeout must fire.
      Process.sleep(180)
      html = render(view)
      assert html =~ "offline"
      assert html =~ "force-closed"
      # the composer is usable again — Stop is gone, Send is back
      assert has_element?(view, ~s(form[phx-submit=send] button[type=submit]))
      refute has_element?(view, ~s(form[phx-submit=send] button[phx-click=stop_turn]))
    end

    test "a result arriving before the timeout makes the timer a no-op", %{view: view} do
      Application.put_env(:barkpark, :studio_chat_interrupt_timeout_ms, 60)
      on_exit(fn -> Application.delete_env(:barkpark, :studio_chat_interrupt_timeout_ms) end)

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      render_click(element(view, ~s(button[phx-click=stop_turn])))

      # the interrupt result lands FIRST → back to ready
      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "result",
           "subtype" => "error_during_execution",
           "terminal_reason" => "aborted_streaming"
         }}
      )

      assert render(view) =~ "ready"

      # let the (now stale) timer fire — it must NOT flip offline
      Process.sleep(180)
      html = render(view)
      refute html =~ "offline"
      assert html =~ "ready"
    end

    # ── extracted teardown is idempotent (scc-w2, D18) ────────────────────

    test "a close-then-DOWN double fire does not duplicate the offline system line",
         %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      pid = session_pid(view)

      send(view.pid, {:claude_chat_exit, 2})
      # the DOWN that follows the process death — teardown already ran, so this
      # must find no matching session pid and no-op (never a second system line)
      send(view.pid, {:DOWN, make_ref(), :process, pid, :normal})

      html = render(view)
      count = html |> String.split("Send a message to resume it") |> length() |> Kernel.-(1)
      assert count == 1
      assert html =~ "offline"
    end

    test "a bare process DOWN (no exit frame) runs the honest teardown", %{view: view} do
      # a live turn with a pending approval, then a crash surfacing ONLY as DOWN
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "act"})
      pid = session_pid(view)

      send(
        view.pid,
        {:claude_chat_permission,
         %{
           request_id: "req-down",
           tool_name: "Bash",
           input: %{},
           title: nil,
           decision_reason: nil
         }}
      )

      send(view.pid, {:DOWN, make_ref(), :process, pid, :killed})
      html = render(view)

      assert html =~ "offline"
      assert html =~ "ended unexpectedly"
      # the pending approval is force-canceled, never a dead button
      assert html =~ "✗ canceled"
      assert has_element?(view, ~s(form[phx-submit=send] button[type=submit]))
    end

    test "an unknown stale event does not crash the LiveView", %{view: view} do
      render_hook(view, "totally-unknown-event", %{})
      send(view.pid, {:claude_chat_event, %{"type" => "mystery"}})
      assert Process.alive?(view.pid)
    end
  end

  # Charter D25: images ride the turn — paste/drop into the composer, base64 on
  # the wire, D6-clean data-URI replay. The paste/drop hook is JS (bp-chat-
  # composer.js); the server half is exercised through LiveViewTest's
  # file_input/render_upload, which drives the SAME allow_upload the hook feeds.
  describe "image attachments (charter D25)" do
    setup %{conn: conn} do
      enable_fake_chat()

      dir =
        Path.join(System.tmp_dir!(), "bp_chat_live_attach_#{System.unique_integer([:positive])}")

      prev = Application.get_env(:barkpark, StudioChat)
      Application.put_env(:barkpark, StudioChat, attachments_dir: dir)

      on_exit(fn ->
        File.rm_rf(dir)
        if prev, do: Application.put_env(:barkpark, StudioChat, prev)
      end)

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      {:ok, view: view, conn: conn}
    end

    test "the composer wires the paste/drop hook + a hidden file input", %{view: view} do
      assert has_element?(view, "form#chat-composer-form[phx-hook=ChatComposer]")
      assert has_element?(view, "input[type=file]")
    end

    test "an uploaded image lands an attachment chip with a remove button", %{view: view} do
      avatar =
        file_input(view, "#chat-composer-form", :attachments, [
          %{name: "shot.png", content: "PNGBYTES", type: "image/png"}
        ])

      html = render_upload(avatar, "shot.png")
      assert html =~ "shot.png"
      assert has_element?(view, "button[phx-click=cancel_upload]")
    end

    test "an oversize image is rejected with an honest inline error", %{view: view} do
      big = :binary.copy(<<7>>, 3_000_001)

      avatar =
        file_input(view, "#chat-composer-form", :attachments, [
          %{name: "big.png", content: big, type: "image/png"}
        ])

      html =
        case render_upload(avatar, "big.png") do
          {:error, _} -> render(view)
          rendered when is_binary(rendered) -> rendered
        end

      assert html =~ "larger than 3 MB"
    end

    test "sending an image stores a pointer (no base64 in the DB), renders inline, no /media route",
         %{view: view} do
      avatar =
        file_input(view, "#chat-composer-form", :attachments, [
          %{name: "pic.png", content: "PNGDATA", type: "image/png"}
        ])

      render_upload(avatar, "pic.png")

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "look at this"})

      # Two-phase send (D24): the submit diff carries only the instant text
      # echo; the image bubble lands in the {:dispatch_send} diff — a render
      # roundtrip drains it.
      html = render(view)

      # Live bubble inlines the image server-side as a data-URI — never /media.
      assert html =~ "data:image/png;base64,#{Base.encode64("PNGDATA")}"
      assert html =~ "look at this"
      refute html =~ "/media/files"

      sid = store_id(view)

      user_msg =
        sid |> StudioChat.list_messages() |> Enum.find(&(&1.role == "user"))

      assert [ptr] = user_msg.metadata["attachments"]
      assert ptr["media_type"] == "image/png"
      assert ptr["sha256"] == :sha256 |> :crypto.hash("PNGDATA") |> Base.encode16(case: :lower)
      assert ptr["byte_size"] == byte_size("PNGDATA")
      # the jsonb pointer carries NO base64 / bytes
      refute Map.has_key?(ptr, "data")
      refute Map.has_key?(ptr, "bytes")
    end

    test "replay inlines the stored image as a data-URI, server-side (no route)", %{conn: conn} do
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})
      {:ok, ptr} = StudioChat.store_attachment(id, "REPLAYBYTES", "image/png")

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "user",
          source_markdown: "recall this",
          metadata: %{"attachments" => [attachment_json(ptr)]}
        })

      {:ok, _view, html} = live(conn, "/studio/chat/#{id}")

      assert html =~ "data:image/png;base64,#{Base.encode64("REPLAYBYTES")}"
      refute html =~ "/media/files"
    end

    test "a replayed image whose file is gone renders an honest placeholder, never crashes",
         %{conn: conn} do
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "user",
          source_markdown: "was an image",
          metadata: %{
            "attachments" => [
              %{
                "path" => "#{id}/deadbeef",
                "media_type" => "image/png",
                "sha256" => "deadbeef",
                "byte_size" => 3
              }
            ]
          }
        })

      {:ok, view, html} = live(conn, "/studio/chat/#{id}")

      assert html =~ "attachment missing"
      refute html =~ "data:image/png;base64,"
      assert Process.alive?(view.pid)
    end
  end

  defp attachment_json(ptr) do
    %{
      "path" => ptr.path,
      "media_type" => ptr.media_type,
      "sha256" => ptr.sha256,
      "byte_size" => ptr.byte_size
    }
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

    test "switching mode on a reopened (no-live) session persists so reopen shows it",
         %{conn: conn} do
      sid = seed_session("Modey")
      assert StudioChat.get_session(sid).mode == "plan"

      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
      # reopen did NOT spawn — this is the no-live-session set-mode branch
      assert session_pid(view) == nil

      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "acceptEdits"})

      # the store row carries the switch (not its stale creation mode)…
      assert StudioChat.get_session(sid).mode == "acceptEdits"

      # …so a fresh reopen shows it in the selector + drives the next spawn's mode
      {:ok, view2, _html2} = live(conn, "/studio/chat/#{sid}")
      assert lv_assigns(view2)[:mode] == "acceptEdits"
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

  describe "the sidebar as a managed resource list (rename/archive/delete, wave 2)" do
    setup %{conn: conn} do
      enable_fake_chat()
      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    test "each row carries a kebab menu (role=menu, menuitems) with Rename/Archive/Delete",
         %{conn: conn} do
      sid = seed_session("Managed chat")
      {:ok, view, _html} = live(conn, "/studio/chat")

      # the menu is closed until the kebab is toggled
      refute has_element?(view, ~s([data-test-id="chat-session-menu-list-#{sid}"]))

      html = render_click(element(view, ~s([data-test-id="chat-session-menu-#{sid}"])))
      assert html =~ ~s(role="menu")
      assert has_element?(view, ~s([data-test-id="chat-session-rename-#{sid}"][role="menuitem"]))
      assert has_element?(view, ~s([data-test-id="chat-session-archive-#{sid}"][role="menuitem"]))
      assert has_element?(view, ~s([data-test-id="chat-session-delete-#{sid}"][role="menuitem"]))
    end

    test "inline rename commits via submit, persists title_source human, and survives the AI titler",
         %{conn: conn} do
      sid = seed_session("Original")
      {:ok, view, _html} = live(conn, "/studio/chat")

      render_click(element(view, ~s([data-test-id="chat-session-menu-#{sid}"])))
      render_click(element(view, ~s([data-test-id="chat-session-rename-#{sid}"])))
      # the inline editor is now open on this row
      assert has_element?(view, ~s([data-test-id="chat-session-rename-input-#{sid}"]))

      render_submit(element(view, "form[phx-submit=session-rename]"), %{
        "title" => "My renamed chat"
      })

      s = StudioChat.get_session(sid)
      assert s.title == "My renamed chat"
      # rename/2 pins human — the AI titler must not clobber it (charter D13)
      assert s.title_source == "human"
      assert :noop = StudioChat.maybe_set_ai_title(sid, "AI would pick this")
      assert StudioChat.get_session(sid).title == "My renamed chat"
      # the sidebar reflects the new title, editor closed
      html = render(view)
      assert html =~ "My renamed chat"
      refute has_element?(view, ~s([data-test-id="chat-session-rename-input-#{sid}"]))
    end

    test "blur COMMITS the rename (the sheet-tab divergence)", %{conn: conn} do
      sid = seed_session("Before blur")
      {:ok, view, _html} = live(conn, "/studio/chat")

      render_click(element(view, ~s([data-test-id="chat-session-menu-#{sid}"])))
      render_click(element(view, ~s([data-test-id="chat-session-rename-#{sid}"])))

      render_blur(element(view, ~s([data-test-id="chat-session-rename-input-#{sid}"])), %{
        "value" => "Committed by blur"
      })

      assert StudioChat.get_session(sid).title == "Committed by blur"
    end

    test "a blank rename is a no-op, never a wipe", %{conn: conn} do
      sid = seed_session("Keep me")
      {:ok, view, _html} = live(conn, "/studio/chat")

      render_click(element(view, ~s([data-test-id="chat-session-menu-#{sid}"])))
      render_click(element(view, ~s([data-test-id="chat-session-rename-#{sid}"])))
      render_submit(element(view, "form[phx-submit=session-rename]"), %{"title" => "   "})

      assert StudioChat.get_session(sid).title == "Keep me"
    end

    test "Escape cancels the rename without touching the title", %{conn: conn} do
      sid = seed_session("Unchanged")
      {:ok, view, _html} = live(conn, "/studio/chat")

      render_click(element(view, ~s([data-test-id="chat-session-menu-#{sid}"])))
      render_click(element(view, ~s([data-test-id="chat-session-rename-#{sid}"])))
      assert has_element?(view, ~s([data-test-id="chat-session-rename-input-#{sid}"]))

      render_keydown(element(view, ~s([data-test-id="chat-session-rename-input-#{sid}"])), %{
        "key" => "Escape"
      })

      refute has_element?(view, ~s([data-test-id="chat-session-rename-input-#{sid}"]))
      assert StudioChat.get_session(sid).title == "Unchanged"
    end

    test "deleting the ON-SCREEN session push_patches to /studio/chat and lands on new-chat",
         %{conn: conn} do
      sid = seed_session("Open + doomed")
      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
      assert store_id(view) == sid

      render_click(element(view, ~s([data-test-id="chat-session-menu-#{sid}"])))
      render_click(element(view, ~s([data-test-id="chat-session-delete-#{sid}"])))

      assert_patched(view, "/studio/chat")
      # the single source of truth reset to the clean new-chat state
      assert store_id(view) == nil
      assert session_pid(view) == nil
      # gone from the DB and from the sidebar
      assert StudioChat.get_session(sid) == nil
      refute render(view) =~ "Open + doomed"
    end

    test "archiving the ON-SCREEN session push_patches to /studio/chat", %{conn: conn} do
      sid = seed_session("Open + archived")
      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")

      render_click(element(view, ~s([data-test-id="chat-session-menu-#{sid}"])))
      render_click(element(view, ~s([data-test-id="chat-session-archive-#{sid}"])))

      assert_patched(view, "/studio/chat")
      assert store_id(view) == nil
      # archived, not deleted — the row leaves the active sidebar but survives
      assert StudioChat.get_session(sid).archived_at != nil
      refute render(view) =~ "Open + archived"
    end

    test "deleting a BACKGROUND session leaves the open session untouched", %{conn: conn} do
      open = seed_session("Stays open")
      victim = seed_session("Background victim")
      {:ok, view, _html} = live(conn, "/studio/chat/#{open}")
      assert store_id(view) == open

      render_click(element(view, ~s([data-test-id="chat-session-menu-#{victim}"])))
      render_click(element(view, ~s([data-test-id="chat-session-delete-#{victim}"])))

      # no navigation — the open session is intact
      assert store_id(view) == open
      assert StudioChat.get_session(victim) == nil
      html = render(view)
      refute html =~ "Background victim"
      assert html =~ "Stays open"
    end

    test "the Show-archived toggle reveals the archived shelf and its unarchive action",
         %{conn: conn} do
      _active = seed_session("Active one")
      shelved = seed_session("Shelved one")
      StudioChat.archive_session(shelved)

      {:ok, view, html} = live(conn, "/studio/chat")
      # the active list shows only the non-archived session
      assert html =~ "Active one"
      refute html =~ "Shelved one"

      html = render_click(element(view, ~s([data-test-id="chat-archived-toggle"])))
      # now the shelf is shown: archived session visible, active hidden
      assert html =~ "Shelved one"
      refute html =~ "Active one"

      # its menu offers Unarchive (not Archive)
      render_click(element(view, ~s([data-test-id="chat-session-menu-#{shelved}"])))
      assert has_element?(view, ~s([data-test-id="chat-session-unarchive-#{shelved}"]))
      refute has_element?(view, ~s([data-test-id="chat-session-archive-#{shelved}"]))

      render_click(element(view, ~s([data-test-id="chat-session-unarchive-#{shelved}"])))
      assert StudioChat.get_session(shelved).archived_at == nil
    end

    test "an archived session opened by URL still replays and offers unarchive", %{conn: conn} do
      sid = seed_session_with_history()
      StudioChat.archive_session(sid)

      {:ok, view, html} = live(conn, "/studio/chat/#{sid}")
      # archived is not deleted — the history replays and the session loads
      assert store_id(view) == sid
      assert html =~ "prev question"

      # the sidebar defaults to the active shelf (the open archived row isn't in it),
      # but flipping to the archived shelf surfaces it with an Unarchive action
      render_click(element(view, ~s([data-test-id="chat-archived-toggle"])))
      render_click(element(view, ~s([data-test-id="chat-session-menu-#{sid}"])))
      assert has_element?(view, ~s([data-test-id="chat-session-unarchive-#{sid}"]))
    end

    test "the empty archived shelf teaches instead of showing nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")
      html = render_click(element(view, ~s([data-test-id="chat-archived-toggle"])))
      assert html =~ "No archived chats"
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
         %{
           request_id: "req-live",
           tool_name: "Write",
           input: %{},
           title: nil,
           decision_reason: nil
         }}
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

  describe "reopen of a live session adopts it (registry-aware, charter D22)" do
    setup %{conn: conn} do
      enable_fake_chat()
      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    # Drive a tab to a LIVE session (fresh send spawns the registered `cat`
    # process) that carries one PERSISTED pending approval — the exact shape a
    # second tab must NOT trample.
    defp start_live_session_with_pending(conn, request_id) do
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "act"})
      sid = store_id(view)
      owner = session_pid(view)

      send(
        view.pid,
        {:claude_chat_permission,
         %{
           request_id: request_id,
           tool_name: "Bash",
           input: %{"command" => "ls"},
           title: "Allow Bash?",
           decision_reason: nil
         }}
      )

      render(view)
      {view, sid, owner}
    end

    test "a second tab ADOPTS the running process — it does not spawn a second writer",
         %{conn: conn} do
      {_viewA, sid, owner} = start_live_session_with_pending(conn, "req-adopt")
      assert is_pid(owner) and Process.alive?(owner)

      {:ok, viewB, _html} = live(conn, "/studio/chat/#{sid}")

      # tab B took over the SAME process (no `claude --resume` second writer),
      # so the CLI transcript keeps a single owner.
      assert session_pid(viewB) == owner
    end

    test "the old tab is detached (honest banner, composer frozen) when the new tab adopts",
         %{conn: conn} do
      {viewA, sid, _owner} = start_live_session_with_pending(conn, "req-detach")

      {:ok, _viewB, _html} = live(conn, "/studio/chat/#{sid}")

      await(fn -> lv_assigns(viewA)[:detached] == true end)
      assert lv_assigns(viewA)[:status] == :detached
      # the take-over banner replaces the composer (no second-writer path)
      render(viewA)
      assert has_element?(viewA, "button[phx-click=take_over]")
      refute has_element?(viewA, "form[phx-submit=send]")
    end

    test "the store never lies on reopen-of-live: the pending approval stays pending and answerable",
         %{conn: conn} do
      {_viewA, sid, _owner} = start_live_session_with_pending(conn, "req-answer")

      # the ask really is pending in the store before the second tab opens
      assert StudioChat.get_session(sid).pending_approvals == 1

      {:ok, viewB, html} = live(conn, "/studio/chat/#{sid}")

      # NOT cancelled — the live owner can still resolve it, so the card replays
      # as an answerable approval (never the ✗ canceled terminal state)
      refute html =~ "✗ canceled"
      assert has_element?(viewB, ~s(button[phx-click=approve][phx-value-rid=req-answer]))
      assert StudioChat.get_session(sid).pending_approvals == 1

      row = StudioChat.list_messages(sid) |> Enum.find(&(&1.role == "approval"))
      assert row.metadata["approval_status"] == "pending"

      # …and answering THROUGH the adopted pid resolves it end-to-end
      render_click(element(viewB, ~s(button[phx-click=approve][phx-value-rid=req-answer])))

      approval = StudioChat.list_messages(sid) |> Enum.find(&(&1.role == "approval"))
      assert approval.metadata["approval_status"] == "allowed"
      assert StudioChat.get_session(sid).pending_approvals == 0
    end

    test "reopen of a session with NO live owner still cancel-persists its dangling approval",
         %{conn: conn} do
      # seeded row, never spawned → the registry holds no owner for this id
      sid = seed_session_with_pending_approval("req-dead")
      assert [] = Registry.lookup(Barkpark.StudioChat.SessionRegistry, sid)
      assert StudioChat.get_session(sid).pending_approvals == 1

      {:ok, view, html} = live(conn, "/studio/chat/#{sid}")

      # display-only (no spawn) AND the dangling ask is honestly canceled
      assert session_pid(view) == nil
      assert html =~ "✗ canceled"
      refute has_element?(view, ~s(button[phx-click=approve][phx-value-rid=req-dead]))
      assert StudioChat.get_session(sid).pending_approvals == 0
    end

    test "re-navigating to the session you already own does not re-adopt or self-detach",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      sid = store_id(view)
      owner = session_pid(view)
      assert is_pid(owner)
      # a fresh send is mid-turn — the live state we must NOT clobber
      assert lv_assigns(view)[:status] == :thinking

      # patch to our OWN url again: handle_params' store_session_id == sid
      # short-circuit keeps the live pid untouched — no load_stored_session, so
      # no adopt, no self-detach, no replay that would drop the live turn.
      render_patch(view, "/studio/chat/#{sid}")

      assert session_pid(view) == owner
      assert lv_assigns(view)[:status] == :thinking
      refute lv_assigns(view)[:detached]
    end

    test "a send after the live owner died never holds a dead session pid (no phantom, not stuck)",
         %{conn: conn} do
      {view, sid, owner} = start_live_session_with_pending(conn, "req-gone")

      # the owner dies; our DOWN handler tears the tab down to an honest offline
      Process.exit(owner, :kill)
      await(fn -> lv_assigns(view)[:status] == :offline end)
      before = StudioChat.get_session(sid).message_count

      # sending again lazy-resumes: the registry reaped the dead entry, so
      # start_session heals to a FRESH process that really receives the message —
      # the adopt-a-corpse guard means the LiveView NEVER holds a dead session
      # pid, so no user turn is echoed against the void.
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "still there?"})

      # invariant across BOTH honest branches (registry heals to a fresh resume,
      # or the guard refuses a dead incumbent): the LiveView NEVER holds a dead
      # session pid, and it never shows :thinking without a live session — so a
      # user turn is never echoed against the void.
      sp = session_pid(view)
      refute is_pid(sp) and not Process.alive?(sp)
      refute lv_assigns(view)[:status] == :thinking and not (is_pid(sp) and Process.alive?(sp))
      # at most one NEW user row (the real resend) — never a phantom double-write
      assert StudioChat.get_session(sid).message_count in [before, before + 1]
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

  # ── send is instant and never loses your words (optimistic echo, D24) ──────
  describe "send: optimistic echo + restore-on-failure (charter D24)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      {:ok, view: view, conn: conn}
    end

    test "the user bubble lands in the FIRST diff, before phase 2 runs", %{view: view} do
      # Arm a dispatch FAILURE so the echo can't be riding on a successful
      # spawn/persist: it must already be on screen from phase 1, which returns
      # before the deferred {:dispatch_send} ever runs.
      Application.put_env(:barkpark, :public_demo_studio, true)

      html =
        render_submit(element(view, "form[phx-submit=send]"), %{"message" => "did you get this"})

      # This is the phase-1 render (the handle_event reply) — the words + the
      # working status are here INSTANTLY, before any subprocess work.
      assert html =~ "did you get this"
      assert html =~ "working"
      assert html =~ ~s(data-role="user")
    end

    test "a spawn failure withdraws the echo, restores the words verbatim, and leaves no orphan message row",
         %{view: view} do
      # Deterministic hard failure: disable AFTER mount so the lazy spawn returns
      # {:error, :disabled} in phase 2 (the create/spawn 'session nil' path).
      Application.put_env(:barkpark, :public_demo_studio, true)

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "keep my words"})
      # let phase 2 (the deferred {:dispatch_send}) run
      _ = render(view)

      # the optimistic user bubble is withdrawn (no stranded row that never sent)…
      refute has_element?(view, ~s([data-role="user"]))
      # …the words are handed back to the composer VERBATIM (server-bound value)…
      assert has_element?(view, ~s(input#chat-composer[value="keep my words"]))
      # …an honest line explains why, and we are NOT stuck thinking…
      assert render(view) =~ "not enabled on this host"
      assert lv_assigns(view)[:status] == :offline
      refute turn_active_status?(view)

      # …and NO orphan chat_messages row was persisted (persist is gated on a
      # dispatched frame — the session row exists but carries zero messages).
      sid = store_id(view)
      assert is_binary(sid)
      assert StudioChat.list_messages(sid) == []
    end

    test "the composer is server-bound: value tracks the draft while typing and clears on send",
         %{view: view} do
      # phx-change keeps the server draft in step; the input renders it as value=
      render_change(element(view, "form[phx-submit=send]"), %{"message" => "half typed"})
      assert has_element?(view, ~s(input#chat-composer[value="half typed"]))

      # a send clears the composer — the input value is no longer the typed text
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "half typed"})
      refute has_element?(view, ~s(input#chat-composer[value="half typed"]))
    end

    test "a DISPATCHED send whose persist is rejected keeps the echo and stays CLEARED (no double-send)",
         %{conn: conn} do
      sid = seed_session("Doomed store")
      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")

      # Delete the row so the post-dispatch append hits the terminal {:error} of
      # do_append (a vanished-session FK). A true concurrent seq-conflict cannot
      # be forced on one sandbox connection; this exercises the SAME exhaustion
      # branch of persist_user_message with a deterministic {:error}.
      Barkpark.Repo.delete!(StudioChat.get_session(sid))

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "resend me"})
      _ = render(view)

      # The model DID get the turn (cat dispatched it), so the echo STAYS…
      assert has_element?(view, ~s([data-role="user"]))
      html = render(view)
      assert html =~ "resend me"
      # …the honest warn line fires…
      assert html =~ "could not be saved"
      # …and the composer stays CLEARED — restoring here would DOUBLE-SEND.
      refute has_element?(view, ~s(input#chat-composer[value="resend me"]))
    end

    test "reopening after an optimistically-echoed send shows exactly ONE user bubble",
         %{conn: conn, view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "just once"})
      sid = store_id(view)
      # finish the turn cleanly
      send(view.pid, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})
      render(view)

      # Reopen in a fresh mount — replay rebuilds SOLELY from the store, so the
      # optimistic echo is replaced by the one persisted row (never doubled).
      {:ok, view2, _html} = live(conn, "/studio/chat/#{sid}")
      html2 = render(view2)
      assert html2 =~ "just once"
      assert count_substring(html2, ~s(data-role="user")) == 1
    end
  end

  # Is the on-screen chat in a turn-active state (thinking/interrupting)?
  defp turn_active_status?(view), do: lv_assigns(view)[:status] in [:thinking, :interrupting]

  defp count_substring(haystack, needle), do: length(String.split(haystack, needle)) - 1

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
