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
  alias Barkpark.Content
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.PlanPapers
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

    # Recorders are server-owned (wave 4) and outlive the LiveView — reap them
    # at test end so a late frame can't hit the closed sandbox connection.
    on_exit(fn ->
      Barkpark.StudioChat.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

        _ ->
          :ok
      end)
    end)

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

  # Route a frame through the session's REAL Recorder (wave 4, charter D28): it
  # persists the durable outcome and rebroadcasts to every subscribed viewer.
  # The Recorder's PubSub broadcast is a synchronous local send, so once the
  # :sys.get_state roundtrip returns, the frame sits in every viewer's mailbox
  # — the next render(view) drains it deterministically.
  defp send_frame(sid, msg) do
    recorder = Barkpark.StudioChat.Recorder.whereis(sid)
    assert is_pid(recorder), "no live recorder for session #{sid}"
    send(recorder, msg)
    :sys.get_state(recorder)
    :ok
  end

  defp read_marker(path, tries \\ 80) do
    cond do
      File.exists?(path) -> File.read!(path)
      tries <= 0 -> flunk("argv marker was never written by the fake binary: #{path}")
      true -> Process.sleep(25) && read_marker(path, tries - 1)
    end
  end

  # Poll the tee'd stdin capture until a frame of the wanted type appears, then
  # decode it. respond_permission is a cast + port write, so the bytes land
  # asynchronously after render_click returns.
  defp await_wire_frame(path, type, tries \\ 200) do
    frame =
      if File.exists?(path) do
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case Jason.decode(line) do
            {:ok, decoded} -> decoded
            _ -> nil
          end
        end)
        |> Enum.find(&(is_map(&1) and &1["type"] == type))
      end

    cond do
      is_map(frame) -> frame
      tries <= 0 -> flunk("no #{type} frame reached the wire capture: #{path}")
      true -> Process.sleep(20) && await_wire_frame(path, type, tries - 1)
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

  # A stored session whose last message is a proposed-plan row (charter D34),
  # in whatever terminal/pending state a crash or a resolve left behind. Reopen
  # must re-render the card from `metadata.input.plan`, never a bare system line.
  defp seed_session_with_plan(request_id, plan, status) do
    id = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})
    {:ok, _} = StudioChat.append_message(id, %{role: "user", source_markdown: "make a plan"})

    {:ok, _} =
      StudioChat.append_message(id, %{
        role: "plan",
        source_markdown: plan,
        metadata: %{
          "request_id" => request_id,
          "tool_name" => "ExitPlanMode",
          "input" => %{"plan" => plan},
          "approval_status" => status
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
      {:ok, view: view, html: html, conn: conn}
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

    # Keyboard-first affordances are documented UNCONDITIONALLY (charter D42):
    # the footer hint is present on the very first mount, before any turn runs or
    # cost strip appears — a sibling of that conditional strip, never gated on it.
    test "the keyboard footer hint renders on fresh mount, before any turn completes", %{html: html} do
      assert html =~ "esc interrupt"
      assert html =~ "/ commands"
      assert html =~ "↵ send"
      # the cost strip is still conditional — no result yet, so no cost line
      refute html =~ "⏵"
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

    # Server-owned runtime (wave 4, charter D28): tabs are VIEWERS. A second
    # tab on the same session co-views live — both keep their composer (sends
    # serialize through the single Session), and a frame renders in both.
    test "a second tab co-views the same session live", %{view: view, conn: conn} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      sid = store_id(view)

      {:ok, view_b, _html} = live(conn, "/studio/chat/#{sid}")

      # both tabs keep a live composer — no banner, no frozen tab
      assert has_element?(view, "form[phx-submit=send]")
      assert has_element?(view_b, "form[phx-submit=send]")

      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{"content" => [%{"type" => "text", "text" => "both of you see this"}]}
         }}
      )

      assert render(view) =~ "both of you see this"
      assert render(view_b) =~ "both of you see this"
    end

    test "a user send in one tab appears in the other tab's transcript",
         %{view: view, conn: conn} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "first"})
      sid = store_id(view)
      # complete the first turn so the no-send-queue gate frees the composer
      send_frame(sid, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})
      render(view)

      {:ok, view_b, _html} = live(conn, "/studio/chat/#{sid}")

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "cross-tab hello"})
      # phase 2 (dispatch + broadcast) runs on the next roundtrip
      render(view)

      assert render(view_b) =~ "cross-tab hello"
    end

    test "init event surfaces the observed model beside the footer picker", %{view: view} do
      # The observed-model fact moved with the model picker into the composer
      # footer cockpit (charter D44); the standalone header span is gone.
      send(
        view.pid,
        {:claude_chat_event, %{"type" => "system", "subtype" => "init", "model" => "opus-x"}}
      )

      assert render(view) =~ "opus-x"
    end

    test "the attach label's `for` reaches the rendered live_file_input by id", %{view: view} do
      # Charter D44: the image-attach button is a <label for={upload.ref}> and
      # relies on live_file_input rendering id={ref}. That id is LiveView's own
      # convention, not our markup — this guard fails loudly if an LV upgrade
      # changes it (a silently dead attach button otherwise).
      html = render(view)
      assert [_, ref] = Regex.run(~r/<label[^>]*\bfor="([^"]+)"/, html)
      assert html =~ ~s(id="#{ref}")
      assert has_element?(view, ~s(input[type=file][id="#{ref}"]))
    end

    test "text deltas stream into an in-progress bubble", %{view: view} do
      send(view.pid, {:claude_chat_event, stream_delta("Hel")})
      send(view.pid, {:claude_chat_event, stream_delta("lo!")})
      assert render(view) =~ "Hello!"
    end

    # charter D41 — the wire carries no thinking text, so the pulse is a live
    # counter off `system/thinking_tokens` (cumulative `estimated_tokens`).
    test "thinking_tokens frames render a live ✻ pulse with the cumulative count",
         %{view: view} do
      send(view.pid, {:claude_chat_event, thinking_tokens(64)})
      send(view.pid, {:claude_chat_event, thinking_tokens(210)})
      html = render(view)
      assert html =~ "thinking…"
      # the cumulative high-water mark, not a per-frame count
      assert html =~ "~210 tokens"
    end

    test "the pulse settles into a durable 'thought for ~N tokens' line when prose begins",
         %{view: view} do
      send(view.pid, {:claude_chat_event, thinking_tokens(128)})
      assert render(view) =~ "thinking…"

      # the first text delta is the moment thinking gives way to prose
      send(view.pid, {:claude_chat_event, stream_delta("Here")})
      html = render(view)
      refute html =~ "thinking…"
      assert html =~ "thought for ~128 tokens"
    end

    # Forward-compat (charter D41): today `delta.thinking` is always "" so the
    # counter shows; if a future CLI ever populates it, the handler appends the
    # text and shows it in place of the counter.
    test "a non-empty thinking_delta renders the text in place of the counter", %{view: view} do
      send(view.pid, {:claude_chat_event, thinking_tokens(20)})
      assert render(view) =~ "~20 tokens"

      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "stream_event",
           "event" => %{
             "type" => "content_block_delta",
             "delta" => %{"type" => "thinking_delta", "thinking" => "weighing the options"}
           }
         }}
      )

      html = render(view)
      assert html =~ "weighing the options"
      refute html =~ "~20 tokens"
    end

    test "a bout that never counted leaves no pulse and no durable row", %{view: view} do
      send(view.pid, {:claude_chat_event, stream_delta("no prior thought")})
      html = render(view)
      refute html =~ "thinking…"
      refute html =~ "thought for"
    end

    test "a stored thinking row replays as a dim ✻ thought line", %{conn: conn} do
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "thinking",
          source_markdown: "thought for ~90 tokens",
          metadata: %{"tokens" => 90}
        })

      {:ok, _} =
        StudioChat.append_message(id, %{role: "assistant", source_markdown: "the answer"})

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, "/studio/chat/#{id}")
      assert html =~ "thought for ~90 tokens"
      assert html =~ "the answer"
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

    test "the bubble's first block has no top margin (● gutter alignment)", %{view: view} do
      # regression: the paper engine's paragraph top margin pushed the first
      # text line a full line below the ● glyph in the gutter row.
      html = render(view)
      assert html =~ ".bp-paper-surface.bp-chat-md > :first-child"
    end

    test "chat bubbles neutralize the paper PAGE rules (skeleton stays inline)", %{view: view} do
      html = render(view)
      # regression: .bp-paper-surface is the reader PAGE class — its
      # min-height:100% stretched the streaming block viewport-tall and pushed
      # the skeleton to the bottom of the screen. The chat must pin the
      # neutralizer with higher specificity.
      assert html =~ ".bp-paper-surface.bp-chat-md"
      assert html =~ "min-height: 0;"
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

      send_frame(
        store_id(view),
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
      # The composer-footer ring is :sm, so the 9px % label is hidden (charter
      # D44) and the arc dasharray carries the proof: 0.32 × 97.39 = 31.16.
      assert html =~ ~s(stroke-dasharray="31.16 97.39")
      # 32% is below 70% → the ok token, never warn/danger.
      assert html =~ "var(--ok)"
      assert html =~ "Context: 64000 / 200000 tokens"
      # Cost renders from the D37 strip below the footer (the :sm ring passes
      # show_cost=false to avoid double-rendering it).
      assert html =~ "$0.0500"
    end

    test "reopening a stored session shows its last-known headroom", %{view: view} do
      id = seed_session("resumed chat")

      # A near-full window (185k / 200k = 93%) — the danger ramp.
      {:ok, _} =
        StudioChat.record_result_metrics(id, %{input_tokens: 185_000, context_window: 200_000})

      html = render_patch(view, "/studio/chat/#{id}")

      # 185000 / 200000 = 93% — the :sm footer ring hides the % label (charter
      # D44), so the honest title + the danger ramp carry the last-known headroom.
      assert html =~ "Context: 185000 / 200000 tokens"
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

    # ── AskUserQuestion answer form + ExitPlanMode plan card (charter D31/D32) ─

    defp ask_question(view, rid, questions) do
      send(
        view.pid,
        {:claude_chat_permission,
         %{
           request_id: rid,
           tool_name: "AskUserQuestion",
           input: %{"questions" => questions},
           title: nil,
           decision_reason: nil
         }}
      )
    end

    test "an AskUserQuestion ask renders an answer FORM, not an Allow/Deny card",
         %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "help me choose"})

      ask_question(view, "q-1", [
        %{
          "question" => "Which pet?",
          "header" => "Pets",
          "multiSelect" => false,
          "options" => [
            %{"label" => "Cat", "description" => "aloof"},
            %{"label" => "Dog", "description" => "loyal"}
          ]
        }
      ])

      html = render(view)
      assert html =~ "The agent is asking you"
      assert html =~ "Which pet?"
      assert html =~ "Cat"
      assert html =~ "Dog"
      assert html =~ ~s(data-question="q-1")
      assert html =~ ~s(phx-click="question-submit")
      assert html =~ ~s(phx-click="question-toggle")
      # a question is NOT a bare approval card
      refute html =~ "Allow AskUserQuestion?"
    end

    test "selecting a chip and submitting resolves the question as answered",
         %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "choose"})

      ask_question(view, "q-2", [
        %{
          "question" => "Which pet?",
          "multiSelect" => false,
          "options" => [%{"label" => "Cat"}, %{"label" => "Dog"}]
        }
      ])

      render(view)

      render_click(
        element(
          view,
          ~s(button[phx-click=question-toggle][phx-value-qi="0"][phx-value-label="Cat"])
        )
      )

      html =
        render_click(element(view, ~s(button[phx-click=question-submit][phx-value-rid="q-2"])))

      assert html =~ "✓ answered"
      refute html =~ "The agent is asking you"
    end

    test "a multiSelect question accumulates chips (toggle, not replace)", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "choose many"})

      ask_question(view, "q-3", [
        %{
          "question" => "Which pets?",
          "multiSelect" => true,
          "options" => [%{"label" => "Cat"}, %{"label" => "Dog"}]
        }
      ])

      render(view)

      # both chips selected — a multiSelect adds rather than replaces
      render_click(
        element(
          view,
          ~s(button[phx-click=question-toggle][phx-value-qi="0"][phx-value-label="Cat"])
        )
      )

      html =
        render_click(
          element(
            view,
            ~s(button[phx-click=question-toggle][phx-value-qi="0"][phx-value-label="Dog"])
          )
        )

      # both chips read as pressed (accumulated selection, not a single winner)
      assert html =~ ~s(phx-value-label="Cat" aria-pressed="true") or
               html =~ ~s(aria-pressed="true")

      html =
        render_click(element(view, ~s(button[phx-click=question-submit][phx-value-rid="q-3"])))

      assert html =~ "✓ answered"
    end

    # Charter D32, end-to-end through the LiveView: the multiSelect answer that
    # reaches the WIRE is the comma-joined labels, keyed by the QUESTION STRING.
    # The fake subprocess tees every stdin line to a capture file, so this
    # asserts the literal control_response bytes the CLI would read — chip
    # clicks → build_answers → respond_permission → port write.
    test "a multiSelect answer reaches the wire comma-joined, keyed by the question string",
         %{view: view} do
      wire =
        Path.join(
          System.tmp_dir!(),
          "chat_live_wire_#{System.pid()}_#{System.unique_integer([:positive])}"
        )

      File.rm_rf(wire)
      on_exit(fn -> File.rm_rf(wire) end)

      Application.put_env(:barkpark, :claude_chat,
        enabled: true,
        command: {"sh", ["-c", "tee '#{wire}' >/dev/null"]}
      )

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "choose many"})

      ask_question(view, "q-wire", [
        %{
          "question" => "Which pets?",
          "multiSelect" => true,
          "options" => [%{"label" => "Cat"}, %{"label" => "Dog"}]
        }
      ])

      render(view)

      render_click(
        element(
          view,
          ~s(button[phx-click=question-toggle][phx-value-qi="0"][phx-value-label="Cat"])
        )
      )

      render_click(
        element(
          view,
          ~s(button[phx-click=question-toggle][phx-value-qi="0"][phx-value-label="Dog"])
        )
      )

      render_click(element(view, ~s(button[phx-click=question-submit][phx-value-rid="q-wire"])))

      frame = await_wire_frame(wire, "control_response")

      assert %{
               "response" => %{
                 "subtype" => "success",
                 "request_id" => "q-wire",
                 "response" => %{"behavior" => "allow", "updatedInput" => updated}
               }
             } = frame

      assert updated["answers"] == %{"Which pets?" => "Cat, Dog"}
      # the questions ride back unchanged next to the answers (charter D32)
      assert [%{"question" => "Which pets?"} | _] = updated["questions"]
    end

    test "a custom free-text answer resolves the question", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "choose"})

      ask_question(view, "q-4", [%{"question" => "Anything?", "options" => []}])
      render(view)

      render_hook(view, "question-custom", %{
        "rid" => "q-4",
        "qi" => "0",
        "value" => "surprise me"
      })

      html =
        render_click(element(view, ~s(button[phx-click=question-submit][phx-value-rid="q-4"])))

      assert html =~ "✓ answered"
    end

    test "dismissing the questions denies honestly", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "choose"})

      ask_question(view, "q-5", [%{"question" => "X", "options" => [%{"label" => "A"}]}])
      render(view)

      html =
        render_click(element(view, ~s(button[phx-click=question-dismiss][phx-value-rid="q-5"])))

      assert html =~ "✗ dismissed"
      refute html =~ "The agent is asking you"
    end

    # (S1's minimal plan-card fallback test was superseded by the rich S2 card —
    # see "the proposed-plan card (ExitPlanMode, charter D34)" describe below.)

    # Charter D35 — a resolution BROADCASTS so a co-viewing tab's open form
    # converges instead of lingering answerable after the ask is already handled.
    test "resolving a question converges a co-viewing tab", %{view: view, conn: conn} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "choose"})
      sid = store_id(view)

      {:ok, view_b, _html} = live(conn, "/studio/chat/#{sid}")

      send_frame(
        sid,
        {:claude_chat_permission,
         %{
           request_id: "q-9",
           tool_name: "AskUserQuestion",
           input: %{"questions" => [%{"question" => "Pick", "options" => [%{"label" => "A"}]}]},
           title: nil,
           decision_reason: nil
         }}
      )

      # both tabs render the open form
      assert render(view) =~ "The agent is asking you"
      assert render(view_b) =~ "The agent is asking you"

      # answer on tab A
      render_click(
        element(
          view,
          ~s(button[phx-click=question-toggle][phx-value-qi="0"][phx-value-label="A"])
        )
      )

      render_click(element(view, ~s(button[phx-click=question-submit][phx-value-rid="q-9"])))

      # tab B converges: the form is gone, the terminal line is shown
      html_b = render(view_b)
      assert html_b =~ "✓ answered"
      refute html_b =~ "The agent is asking you"
    end

    # Reopen honesty for the question role (charter D31): a stored question row
    # replays in its terminal state, and a dangling "pending" row with no live
    # owner renders as canceled — never a dead answer form, never a bare
    # :system fallback line.
    defp seed_session_with_question(request_id, status) do
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})
      {:ok, _} = StudioChat.append_message(id, %{role: "user", source_markdown: "choose"})

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "question",
          source_markdown: "AskUserQuestion",
          metadata: %{
            "request_id" => request_id,
            "tool_name" => "AskUserQuestion",
            "input" => %{"questions" => [%{"question" => "Which pet?", "options" => ["Cat"]}]},
            "approval_status" => status
          }
        })

      id
    end

    test "an answered question row reopens as its terminal line, not a form", %{conn: conn} do
      sid = seed_session_with_question("q-done", "allowed")

      {:ok, view, html} = live(conn, "/studio/chat/#{sid}")

      assert html =~ "✓ answered"
      refute html =~ "The agent is asking you"
      refute has_element?(view, ~s(button[phx-click=question-submit][phx-value-rid="q-done"]))
    end

    test "a dangling pending question row reopens as ✗ canceled, never a live form",
         %{conn: conn} do
      sid = seed_session_with_question("q-hang", "pending")

      {:ok, view, html} = live(conn, "/studio/chat/#{sid}")

      # pending + no live owner → the honest terminal state, not a dead form
      assert html =~ "✗ canceled"
      refute html =~ "The agent is asking you"
      refute has_element?(view, ~s(button[phx-click=question-submit][phx-value-rid="q-hang"]))
    end

    test "switching mode steers the LIVE session in place (no respawn, no teardown)",
         %{view: view} do
      # spawn is lazy now — establish a live subprocess, then finish the turn
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      send(view.pid, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})
      pid_before = session_pid(view)
      refute pid_before == nil

      html = render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "acceptEdits"})
      # the mode change is recorded honestly with the friendly label…
      assert html =~ "Permission mode → accept edits"
      assert html =~ "accept edits"
      # …and the session is steered in place, never respawned or torn down —
      # the old context-destroying respawn path is gone (charter D12).
      refute html =~ "New session started"
      assert session_pid(view) == pid_before
      assert html =~ "ready"
    end

    test "mode change with no live session just updates the selector", %{view: view} do
      html = render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "acceptEdits"})
      refute html =~ "New session started"
      assert html =~ "accept edits"
      assert session_pid(view) == nil
    end

    # Picking bypassPermissions NEVER persists on the select alone (charter D48
    # fail-closed law) — it opens the loud type-to-confirm arm panel and leaves
    # the mode untouched.
    test "picking bypass opens the arm panel and never steers on the select alone",
         %{view: view} do
      html =
        render_change(element(view, ~s(form[phx-change=set-mode])), %{
          "mode" => "bypassPermissions"
        })

      # the arm ceremony opened, but no mode change was announced or persisted
      assert html =~ "Type"
      assert has_element?(view, ~s(button[phx-click=arm-bypass]))
      refute html =~ "Permission mode → bypass"
      assert lv_assigns(view)[:mode] == "plan"
    end

    # ── honest turn outcomes (scc-w1-honest-turns) ───────────────────────

    test "while a turn runs, Stop replaces Send (attribute-level, not disabled)", %{view: view} do
      # render_submit bypasses the disabled attribute, so assert on the button
      # IDENTITY, not on disabled: the submit button is GONE, Stop is present.
      refute has_element?(view, ~s(button[phx-click=stop_turn]))
      assert has_element?(view, ~s(button[type=submit][form=chat-composer-form]))

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})

      assert has_element?(view, ~s(button[phx-click=stop_turn]))
      refute has_element?(view, ~s(button[type=submit][form=chat-composer-form]))
    end

    # ── mid-turn sends queue honestly instead of dropping (charter D43) ──────

    test "a mid-turn submit is NOT dropped — it echoes with a ⧗ queued badge and persists queued=true",
         %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "first turn"})
      # the turn is live (cat never sends a result), so the second send is mid-turn
      assert turn_active_status?(view)

      html = render_submit(element(view, "form[phx-submit=send]"), %{"message" => "second turn"})
      # both words are on screen now (the drop-gate is gone) and the second wears
      # the live queued badge…
      assert html =~ "first turn"
      assert html =~ "second turn"
      assert html =~ "⧗ queued"

      # …the row persists immediately with metadata.queued=true (words are never
      # deferred — the frame is dispatched right away, the binary buffers it).
      sid = store_id(view)
      queued_rows = StudioChat.list_messages(sid) |> Enum.filter(&(&1.metadata["queued"] == true))
      assert [%{source_markdown: "second turn"}] = queued_rows
    end

    test "the queued badge is LIVE-ONLY — the next system/init clears it in place", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "first turn"})
      html = render_submit(element(view, "form[phx-submit=send]"), %{"message" => "queued one"})
      assert html =~ "⧗ queued"

      # the queued turn starts → system/init fires → the badge clears in memory,
      # but the words stay on screen (the row is now a plain ❯ prompt).
      send(view.pid, {:claude_chat_event, %{"type" => "system", "subtype" => "init", "model" => "sonnet"}})
      html = render(view)
      refute html =~ "⧗ queued"
      assert html =~ "queued one"
    end

    test "a failed mid-turn (queued) dispatch withdraws the echo and restores the draft verbatim (D24)",
         %{view: view} do
      # A peer tab's send (the co-view broadcast) flips THIS idle tab to a running
      # turn WITH NO local subprocess — the deterministic way to reach the queued
      # path without an async kill race. Status is :thinking, session still nil.
      send(view.pid, {:chat_user_message, "peer turn", []})
      _ = render(view)
      assert turn_active_status?(view)
      assert session_pid(view) == nil

      # Arm a hard spawn failure for the deferred dispatch (charter D24 restore).
      Application.put_env(:barkpark, :public_demo_studio, true)

      html = render_submit(element(view, "form[phx-submit=send]"), %{"message" => "keep me too"})
      # phase 1: the queued echo is on screen with its live badge…
      assert html =~ "keep me too"
      assert html =~ "⧗ queued"

      # phase 2: the deferred dispatch can't spawn (demo gate) → restore fires.
      _ = render(view)

      # the words are handed back to the composer verbatim and the queued echo is
      # gone (no stranded ⧗ row that never reached the model)…
      assert has_element?(view, ~s(input#chat-composer[value="keep me too"]))
      html = render(view)
      refute html =~ "⧗ queued"
      assert html =~ "not enabled on this host"
      # …and NO orphan chat_messages row (persist is gated on a dispatched frame).
      assert StudioChat.list_messages(store_id(view)) == []
    end

    test "a queued user row replays as a plain ❯ prompt — the badge is chrome, never stored",
         %{conn: conn} do
      sid = seed_session("Queued replay")
      # a stored user row carrying the historical queued=true fact
      {:ok, _} =
        StudioChat.append_message(sid, %{
          role: "user",
          source_markdown: "buffered words",
          metadata: %{"queued" => true}
        })

      {:ok, _view, html} = live(conn, "/studio/chat/#{sid}")
      assert html =~ "buffered words"
      # replay never renders the live-only badge glyph
      refute html =~ "⧗"
    end

    # Esc fires stop_turn from anywhere now (charter D42), so the handler must be
    # a strict no-op unless a turn is actually running — a stray Escape at an idle
    # composer must never interrupt a live-but-quiescent session.
    test "stop_turn is a server-side no-op when no turn is running (idle live session)",
         %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      # complete the turn — the session stays live, but idle
      send(view.pid, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})
      render(view)
      refute turn_active_status?(view)
      pid = session_pid(view)
      assert is_pid(pid)

      # an Esc-driven stop_turn while idle changes nothing: no :interrupting flip,
      # the session is untouched
      render_hook(view, "stop_turn", %{})
      refute turn_active_status?(view)
      assert lv_assigns(view)[:status] != :interrupting
      assert session_pid(view) == pid
    end

    test "stop_turn is a no-op with no session at all", %{view: view} do
      assert session_pid(view) == nil
      render_hook(view, "stop_turn", %{})
      assert session_pid(view) == nil
      refute turn_active_status?(view)
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
      assert has_element?(view, ~s(button[type=submit][form=chat-composer-form]))
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

      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "acceptEdits"})
      rid = pending_mode_req(view)
      # the CLI echoes back exactly the mode we asked for → confirmed
      send(view.pid, {:claude_chat_control, :set_mode, rid, %{"mode" => "acceptEdits"}})

      html = render(view)
      assert html =~ "accept edits"
      refute html =~ "Couldn't switch permission mode"
      # confirmed = persisted: the store's mode is the ACKED value (D23), and the
      # pending marker is cleared.
      assert lv_assigns(view)[:pending_mode] == nil
      assert StudioChat.get_session(store_id(view)).mode == "acceptEdits"
    end

    test "an empty mode echo reverts the optimistic selector + posts an honest line",
         %{view: view} do
      spawn_silent_session(view)

      # optimistic switch to acceptEdits…
      html =
        render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "acceptEdits"})

      assert html =~ "accept edits"
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

      # rapid double switch: acceptEdits (req A) then auto (req B) before any ack
      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "acceptEdits"})
      rid_a = pending_mode_req(view)
      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "auto"})
      rid_b = pending_mode_req(view)
      refute rid_a == rid_b

      # req A's ack lands LATE echoing acceptEdits. Value-matching (the wave-2 bug)
      # would see echo "acceptEdits" != current "auto" and MIS-REVERT. By
      # request_id it is stale (B superseded it) → ignored, mode stays auto.
      send(view.pid, {:claude_chat_control, :set_mode, rid_a, %{"mode" => "acceptEdits"}})
      html = render(view)
      assert html =~ "auto-run"
      refute html =~ "Couldn't switch permission mode"

      # req B's ack then confirms auto honestly.
      send(view.pid, {:claude_chat_control, :set_mode, rid_b, %{"mode" => "auto"}})
      html = render(view)
      assert html =~ "auto-run"
      refute html =~ "Couldn't switch permission mode"
      assert lv_assigns(view)[:pending_mode] == nil
      assert StudioChat.get_session(store_id(view)).mode == "auto"
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

      # a near-full window pre-compaction: 180k / 200k = 90%. The :sm footer ring
      # hides the % label (charter D44), so the arc dasharray is the proof:
      # 0.9 × 97.39 = 87.65.
      send_frame(store_id(view), {:claude_chat_event, big_result(180_000)})
      html = render(view)
      assert html =~ ~s(stroke-dasharray="87.65 97.39")

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
      send_frame(store_id(view), {:claude_chat_event, big_result(40_000)})
      html = render(view)
      # 40k / 200k = 20% → 0.2 × 97.39 = 19.48; the pre-compaction 90% arc is gone.
      assert html =~ ~s(stroke-dasharray="19.48 97.39")
      refute html =~ ~s(stroke-dasharray="87.65 97.39")
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
      assert has_element?(view, ~s(button[type=submit][form=chat-composer-form]))
      refute has_element?(view, ~s(button[phx-click=stop_turn]))
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
      assert has_element?(view, ~s(button[type=submit][form=chat-composer-form]))
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
      send_frame(sid, {:claude_chat_event, stream_delta("partial ")})
      send_frame(sid, {:claude_chat_event, stream_delta("answer")})
      render(view)
      assert StudioChat.get_session(sid).message_count == 1

      # the completed assistant message persists (on the message boundary,
      # written by the RECORDER — the runtime owns the store since wave 4)
      send_frame(
        sid,
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

      send_frame(
        sid,
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

      send_frame(
        sid,
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

      send_frame(
        sid,
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

  describe "the proposed-plan card (ExitPlanMode, charter D34)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      {:ok, view: view, conn: conn}
    end

    # The plan markdown used across the live-card tests — a real heading + list
    # so the title helper and the paper-engine body both have something to chew.
    @plan_md "# Migrate the widgets\n\nSteps:\n\n1. Inventory the widgets\n2. Port each one\n3. Delete the shim"

    defp plan_ask(request_id, plan) do
      {:claude_chat_permission,
       %{
         request_id: request_id,
         tool_name: "ExitPlanMode",
         input: %{"plan" => plan},
         title: nil,
         decision_reason: nil
       }}
    end

    defp drive_plan(view, request_id, plan \\ @plan_md) do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "plan it"})
      send(view.pid, plan_ask(request_id, plan))
      render(view)
    end

    test "an ExitPlanMode ask renders a proposed-plan card, not the Allow/Deny line",
         %{view: view} do
      html = drive_plan(view, "plan-1")

      # a first-class plan card — title from the first heading, the full plan
      # through the paper engine, Approve / Keep planning
      assert html =~ "proposed plan"
      assert html =~ "Migrate the widgets"
      assert html =~ "Inventory the widgets"
      assert html =~ ~s(phx-click="plan-approve")
      assert html =~ ~s(phx-click="plan-keep")
      assert html =~ "Approve plan"
      assert html =~ "Keep planning"

      # NEVER the generic tool-approval card
      refute html =~ "Allow ExitPlanMode?"
    end

    test "the title falls back to 'Proposed plan' when the plan has no heading",
         %{view: view} do
      html = drive_plan(view, "plan-noh", "Just some prose, no heading at all.")
      assert html =~ "Proposed plan"
      assert html =~ "Just some prose, no heading at all."
    end

    test "Approve resolves the card to '✓ plan approved' and drops the buttons",
         %{view: view} do
      # a silent session so no echo loop races the resolve; the card flip is the
      # synchronous truth of this click (the {:allow, input} seam lands via S1).
      spawn_silent_session(view)
      send(view.pid, plan_ask("plan-ok", @plan_md))
      render(view)

      html =
        render_click(element(view, ~s(button[phx-click=plan-approve][phx-value-rid=plan-ok])))

      assert html =~ "✓ plan approved"
      refute html =~ "Approve plan"
      refute html =~ "Keep planning"
    end

    test "Keep planning resolves the card to '✗ kept planning'", %{view: view} do
      spawn_silent_session(view)
      send(view.pid, plan_ask("plan-keep", @plan_md))
      render(view)

      html = render_click(element(view, ~s(button[phx-click=plan-keep][phx-value-rid=plan-keep])))
      assert html =~ "✗ kept planning"
      refute html =~ "Approve plan"
    end

    test "the preview is clamped and the toggle expands it per tab", %{view: view} do
      html = drive_plan(view, "plan-exp")
      # collapsed by default: the clamp class ON THE BODY (space-joined, distinct
      # from the CSS rule `.bp-chat-plan-body.is-collapsed`) + the affordance
      assert html =~ ~s(bp-chat-plan-body is-collapsed)
      assert html =~ "Show full plan"

      # find the plan message id to target the toggle
      plan = Enum.find(lv_assigns(view).messages, &(&1.role == :plan))

      html =
        render_click(element(view, ~s(button[phx-click=plan-toggle][phx-value-id="#{plan.id}"])))

      # expanded: the clamp class is off the body and the label inverts
      refute html =~ ~s(bp-chat-plan-body is-collapsed)
      assert html =~ "Show less"
      # per-tab socket state, never persisted to the store
      assert MapSet.member?(lv_assigns(view).plan_expanded, plan.id)
    end

    # ── the mode flip is OBSERVED, never assumed (charter D34/D52) ───────────
    #
    # Approving a plan makes the CLI flip its own permission mode; the flip is
    # visible ONLY on the next system/init permissionMode. The result frame's
    # permission_mode is null, so asserting there would be vacuous-green.
    #
    # WAVE-10 REAL-BINARY VERDICT (charter D52, probe :probe_postplan_mode,
    # v2.1.205): the post-plan init reports `"default"` — the D34 assumption is
    # PROVEN, not assumed. This test is now pinned to that measured value.

    test "a system/init reporting a new permissionMode flips the mode + persists it + narrates it",
         %{view: view} do
      spawn_silent_session(view)
      sid = store_id(view)
      assert StudioChat.get_session(sid).mode == "plan"

      # the CLI flipped plan → default inside ExitPlanMode; we learn it here
      # (the real-binary-proven value, charter D52)
      send(
        view.pid,
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "init", "permissionMode" => "default"}}
      )

      html = render(view)
      # the selector adopts the observed mode — the CLI's real post-plan mode is
      # `default`, which now surfaces as the "ask (legacy)" option (charter D48:
      # observe reflects CLI reality; a persisted default still spawns verbatim).
      assert html =~ "ask (legacy)"
      assert lv_assigns(view).mode == "default"
      # …and it is PERSISTED, so a reopen and the next --resume carry it
      assert StudioChat.get_session(sid).mode == "default"
      # NO SILENT ESCALATION (charter D52): the CLI-initiated flip to a mode the
      # user never picked surfaces as a visible system line.
      assert html =~ "Permission mode is now ask (legacy) after plan approval"
    end

    test "an unrecognized init permissionMode is surfaced but NEVER adopted (charter D52)",
         %{view: view} do
      spawn_silent_session(view)
      sid = store_id(view)
      assert StudioChat.get_session(sid).mode == "plan"

      # A future/unknown CLI mode outside the six-value guard: never widen the
      # guard to admit an untrusted string — keep the stored mode, but say so.
      send(
        view.pid,
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "init", "permissionMode" => "yolo"}}
      )

      html = render(view)
      assert html =~ "unrecognized permission mode (yolo)"
      # the stored + in-memory mode is LEFT ALONE
      assert lv_assigns(view).mode == "plan"
      assert StudioChat.get_session(sid).mode == "plan"
    end

    test "a fail-closed echo (disarmed bypass spawning plan) is quiet and keeps the stored bypass",
         %{view: view} do
      spawn_silent_session(view)
      sid = store_id(view)

      # persist bypass through the only legal road — the arm ceremony (D48)
      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "bypassPermissions"})
      render_change(element(view, ~s(form[phx-change=bypass-confirm])), %{"confirm" => "bypass"})
      render_click(element(view, ~s(button[phx-click=arm-bypass])))
      assert StudioChat.get_session(sid).mode == "bypassPermissions"

      # A DISARMED bypass session spawns fail-closed (charter D48b/D55) and its
      # init echoes OUR normalized "plan" — that is not a CLI-side flip. It must
      # neither narrate a lie ("after plan approval") nor adopt/persist "plan",
      # which would silently erase the bypass row the re-arm affordance keys on.
      send(
        view.pid,
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "init", "permissionMode" => "plan"}}
      )

      html = render(view)
      refute html =~ "Permission mode is now"
      refute html =~ "unrecognized permission mode"
      assert lv_assigns(view).mode == "bypassPermissions"
      assert StudioChat.get_session(sid).mode == "bypassPermissions"
    end

    test "an init echoing the SAME mode does not churn the selector or the store",
         %{view: view} do
      spawn_silent_session(view)
      sid = store_id(view)

      send(
        view.pid,
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "init", "permissionMode" => "plan"}}
      )

      render(view)
      assert lv_assigns(view).mode == "plan"
      assert StudioChat.get_session(sid).mode == "plan"
    end
  end

  describe "proposed-plan replay (reopen from the store, charter D34)" do
    setup %{conn: conn} do
      enable_fake_chat()
      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    test "a resolved plan row reopens as its terminal card, re-rendered from input.plan",
         %{conn: conn} do
      sid = seed_session_with_plan("plan-done", "# Approved plan\n\nDo the thing.", "allowed")

      {:ok, view, html} = live(conn, "/studio/chat/#{sid}")

      assert html =~ "✓ plan approved"
      assert html =~ "Approved plan"
      # display-only reopen — no live card no one can answer
      refute has_element?(view, ~s(button[phx-click=plan-approve][phx-value-rid=plan-done]))
      assert session_pid(view) == nil
    end

    test "a dangling pending plan row reopens as ✗ canceled, never a live card",
         %{conn: conn} do
      sid = seed_session_with_plan("plan-hang", "# Half-made plan\n\nStep one.", "pending")

      {:ok, view, html} = live(conn, "/studio/chat/#{sid}")

      # pending + no live owner → the honest terminal state, not a dead button
      # and not a bare :system fallback line
      assert html =~ "✗ canceled"
      assert html =~ "Half-made plan"
      refute has_element?(view, ~s(button[phx-click=plan-approve][phx-value-rid=plan-hang]))
      refute has_element?(view, ~s(button[phx-click=plan-keep][phx-value-rid=plan-hang]))
    end
  end

  describe "plans as papers (charter D49)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      {:ok, view: view, conn: conn}
    end

    # reuses the module-level plan_ask/2 helper from the proposed-plan describe
    @d49_plan_md "# Ship the migration\n\nSteps:\n\n1. Inventory\n2. Port\n3. Delete the shim"

    test "approving a plan publishes a real published Paper and the card links to it",
         %{view: view} do
      spawn_silent_session(view)
      sid = store_id(view)
      send(view.pid, plan_ask("plan-pub", @d49_plan_md))
      render(view)

      # the approve is synchronous — the card flips immediately, never waiting on
      # the async projection
      html =
        render_click(element(view, ~s(button[phx-click=plan-approve][phx-value-rid=plan-pub])))

      assert html =~ "✓ plan approved"

      slug = PlanPapers.slug_for(sid, "plan-pub")

      # the fire-and-forget Task publishes a real, PUBLISHED paper at the
      # deterministic slug (shared-mode sandbox lets the Task reach the DB)
      await(fn ->
        case Content.get_paper(slug, "production") do
          %{status: "published", type: "paper"} -> true
          _ -> false
        end
      end)

      # …and the {:plan_paper} broadcast converges back onto this tab: the plan
      # card grows its "→ published as Paper" link pointing at /papers/:slug
      await(fn -> render(view) =~ "published as Paper" end)
      assert render(view) =~ ~s(href="/papers/#{slug}")
    end

    test "the {:plan_paper} broadcast stamps the link on a co-viewing tab (converge)",
         %{view: view} do
      spawn_silent_session(view)
      send(view.pid, plan_ask("plan-conv", @d49_plan_md))

      html =
        render_click(element(view, ~s(button[phx-click=plan-approve][phx-value-rid=plan-conv])))

      assert html =~ "✓ plan approved"

      # a co-viewing tab (or this one) receives the projection outcome over the
      # session topic — the handler stamps the row deterministically, no async
      send(
        view.pid,
        {:plan_paper, "plan-conv",
         %{paper_id: "chat-plan-xyz", paper_url: "/papers/chat-plan-xyz"}}
      )

      html = render(view)
      assert html =~ "published as Paper"
      assert html =~ ~s(href="/papers/chat-plan-xyz")
    end

    test "keep planning creates NO paper — a rejected plan stays chat ephemera",
         %{view: view} do
      spawn_silent_session(view)
      sid = store_id(view)
      send(view.pid, plan_ask("plan-keep2", @d49_plan_md))
      render(view)

      html =
        render_click(element(view, ~s(button[phx-click=plan-keep][phx-value-rid=plan-keep2])))

      assert html =~ "✗ kept planning"

      # give any (wrongly-scheduled) async work a chance to land, then prove none did
      Process.sleep(60)
      assert Content.get_paper(PlanPapers.slug_for(sid, "plan-keep2"), "production") == nil
      refute render(view) =~ "published as Paper"
    end

    test "an ordinary tool approval creates NO paper (only :plan projects)",
         %{view: view} do
      spawn_silent_session(view)
      sid = store_id(view)

      send(
        view.pid,
        {:claude_chat_permission,
         %{
           request_id: "appr-1",
           tool_name: "Write",
           input: %{"file_path" => "/opt/x"},
           title: "Claude wants to write /opt/x",
           decision_reason: nil
         }}
      )

      render(view)
      render_click(element(view, ~s(button[phx-click=approve][phx-value-rid=appr-1])))

      Process.sleep(60)
      assert Content.get_paper(PlanPapers.slug_for(sid, "appr-1"), "production") == nil
      refute render(view) =~ "published as Paper"
    end

    test "a publish failure renders an honest system line and leaves the plan approved",
         %{view: view} do
      spawn_silent_session(view)
      send(view.pid, plan_ask("plan-fail", @d49_plan_md))
      render(view)

      html =
        render_click(element(view, ~s(button[phx-click=plan-approve][phx-value-rid=plan-fail])))

      # the approve already succeeded on the wire — the card is approved
      assert html =~ "✓ plan approved"

      # the projection failed; the failure is honest, not silent, and never a lie
      send(view.pid, {:plan_paper_failed, "plan-fail"})
      html = render(view)
      assert html =~ "Couldn&#39;t publish the approved plan as a Paper"
      # the plan STAYS approved — no link, but the approval is untouched
      assert html =~ "✓ plan approved"
      refute html =~ "published as Paper"
    end

    test "the Paper link survives reopen — replayed from persisted metadata",
         %{conn: conn} do
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})
      {:ok, _} = StudioChat.append_message(id, %{role: "user", source_markdown: "make a plan"})

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "plan",
          source_markdown: "# Reopened plan\n\nStep one.",
          metadata: %{
            "request_id" => "plan-replay",
            "tool_name" => "ExitPlanMode",
            "input" => %{"plan" => "# Reopened plan\n\nStep one."},
            "approval_status" => "allowed",
            "paper_id" => "chat-plan-reopen",
            "paper_url" => "/papers/chat-plan-reopen"
          }
        })

      {:ok, _view, html} = live(conn, "/studio/chat/#{id}")

      assert html =~ "✓ plan approved"
      assert html =~ "Reopened plan"
      # the link is threaded from persisted metadata — durable across reopen
      assert html =~ "published as Paper"
      assert html =~ ~s(href="/papers/chat-plan-reopen")
    end
  end

  describe "terminal look (w6.5)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "go"})
      {:ok, view: view, sid: store_id(view), conn: conn}
    end

    test "a tool call renders the ● row and its result the ⎿ line", %{view: view, sid: sid} do
      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "Bash",
                 "input" => %{"command" => "mix test"}
               }
             ]
           }
         }}
      )

      html = render(view)
      assert html =~ "Bash"
      refute html =~ "⎿"

      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "user",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "toolu_1",
                 "content" => "247 tests, 0 failures"
               }
             ]
           }
         }}
      )

      html = render(view)
      assert html =~ "⎿"
      assert html =~ "247 tests, 0 failures"
    end

    test "a multiline output collapses behind details with a line count", %{view: view, sid: sid} do
      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{"type" => "tool_use", "id" => "toolu_2", "name" => "Read", "input" => %{}}
             ]
           }
         }}
      )

      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "user",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "toolu_2",
                 "content" => "line one\nline two\nline three"
               }
             ]
           }
         }}
      )

      html = render(view)
      assert html =~ "<details>"
      assert html =~ "line one"
      assert html =~ "+2 lines"
    end

    test "the reopened transcript replays the ⎿ output from the store", %{conn: conn, sid: sid} do
      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{"type" => "tool_use", "id" => "toolu_3", "name" => "Bash", "input" => %{}}
             ]
           }
         }}
      )

      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "user",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "toolu_3",
                 "content" => "replayed output"
               }
             ]
           }
         }}
      )

      {:ok, _view2, html} = live(conn, "/studio/chat/#{sid}")
      assert html =~ "⎿"
      assert html =~ "replayed output"
    end

    test "pre-wrap text nodes carry NO template whitespace (alignment regression)", %{
      view: view,
      sid: sid
    } do
      # regression: `<%= message.text %>` on its own indented template line put a
      # literal newline + ~22 spaces INSIDE the pre-wrap text node — the ❯ sat
      # alone on a blank first line and the prompt rendered "centered" below it.
      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{"content" => [%{"type" => "text", "text" => "plain reply"}]}
         }}
      )

      html = render(view)
      # the text node begins immediately after the tag — no template newline
      refute html =~ ~r/pre-wrap[^>]*>\s*\n\s+go</
      assert html =~ ~r/pre-wrap[^"]*"[^>]*>go</
    end

    test "the user prompt wears the ❯ gutter, not a bubble", %{view: view} do
      html = render(view)
      assert html =~ "❯"
      assert html =~ "go"
    end

    test "the turn clock ticks while working and the spinner shows", %{view: view} do
      html = render(view)
      assert html =~ "bp-chat-spinner"
      assert html =~ "working…"

      send(view.pid, :turn_tick)
      send(view.pid, :turn_tick)
      assert render(view) =~ "2s"
    end
  end

  describe "TodoWrite living checklist card (charter D39)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "go"})
      {:ok, view: view, sid: store_id(view), conn: conn}
    end

    test "two TodoWrites in one turn render ONE card, updated in place", %{view: view, sid: sid} do
      send_frame(
        sid,
        todo_frame("tu1", [
          %{
            "content" => "read charter",
            "status" => "in_progress",
            "activeForm" => "reading the charter"
          },
          %{"content" => "write code", "status" => "pending"}
        ])
      )

      html = render(view)
      assert todo_card_count(html) == 1
      assert html =~ "read charter"
      # in_progress glyph + its activeForm live line
      assert html =~ "◐"
      assert html =~ "reading the charter"

      # A FRESH tool_use id (as the real binary emits) — the collapse must
      # supersede the existing card, never append a second one.
      send_frame(
        sid,
        todo_frame("tu2", [
          %{"content" => "read charter", "status" => "completed"},
          %{
            "content" => "write code",
            "status" => "in_progress",
            "activeForm" => "writing the code"
          }
        ])
      )

      html = render(view)
      assert todo_card_count(html) == 1
      assert html =~ "☒"
      assert html =~ "writing the code"
      refute html =~ "reading the charter"

      # The store collapsed to a single todo row too (Recorder-owned, D39).
      todos = StudioChat.list_messages(sid) |> Enum.filter(&(&1.role == "todo"))
      assert length(todos) == 1
    end

    test "reopen replays exactly ONE final-state checklist card", %{conn: conn, sid: sid} do
      send_frame(sid, todo_frame("tu1", [%{"content" => "step one", "status" => "pending"}]))
      send_frame(sid, todo_frame("tu2", [%{"content" => "step one", "status" => "completed"}]))

      {:ok, _view2, html} = live(conn, "/studio/chat/#{sid}")
      assert todo_card_count(html) == 1
      assert html =~ "step one"
      assert html =~ "☒"
    end

    test "no TodoWrite ⇒ no checklist card renders", %{view: view, sid: sid} do
      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{"content" => [%{"type" => "text", "text" => "just prose"}]}
         }}
      )

      refute render(view) =~ "Update todos"
    end
  end

  # ── D38: Edit/Write tool calls render as real colored diffs ─────────────────
  #
  # Dispatch is on input SHAPE, never tool name (host-binary-dependent). The full
  # input is threaded through BOTH render paths (live append + replay) and the
  # persisted store, so a reopened session reproduces the identical diff.
  describe "tool diffs (D38)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "go"})
      {:ok, view: view, sid: store_id(view), conn: conn}
    end

    defp send_tool_use(sid, name, input) do
      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{"type" => "tool_use", "id" => "toolu_x", "name" => name, "input" => input}
             ]
           }
         }}
      )
    end

    test "an Edit-shaped input renders a line diff with +/− token rows", %{view: view, sid: sid} do
      send_tool_use(sid, "Edit", %{
        "file_path" => "/app/x.ex",
        "old_string" => "alpha\nbeta\ngamma",
        "new_string" => "alpha\nBETA\ngamma",
        "replace_all" => false
      })

      html = render(view)
      # removed old line + added new line, each with its role-color token pair
      assert html =~ "var(--danger-soft)"
      assert html =~ "var(--ok-soft)"
      assert html =~ "beta"
      assert html =~ "BETA"
      # unchanged context survives
      assert html =~ "alpha"
      # the ● header shows only the path — the diff below carries the content,
      # so the old preview ("old_string: …") would duplicate it
      assert html =~ "Edit — /app/x.ex"
      refute html =~ "old_string:"
      refute html =~ "new_string:"
    end

    test "dispatch is on SHAPE, not tool name — a renamed Edit tool still diffs",
         %{view: view, sid: sid} do
      # The cmux fork renames tools; an Edit-shaped input under ANY name diffs.
      send_tool_use(sid, "CustomFileEditor", %{
        "file_path" => "/app/y.ex",
        "old_string" => "was here",
        "new_string" => "now here"
      })

      html = render(view)
      assert html =~ "var(--ok-soft)"
      assert html =~ "now here"
      assert html =~ "was here"
    end

    test "a Write-shaped input renders an all-added diff", %{view: view, sid: sid} do
      send_tool_use(sid, "Write", %{
        "file_path" => "/app/new.ex",
        "content" => "line one\nline two\nline three"
      })

      html = render(view)
      assert html =~ "var(--ok-soft)"
      refute html =~ "var(--danger-soft)"
      assert html =~ "line one"
      assert html =~ "line two"
    end

    test "a MultiEdit-shaped input renders stacked hunks defensively",
         %{view: view, sid: sid} do
      send_tool_use(sid, "MultiEdit", %{
        "file_path" => "/app/z.ex",
        "edits" => [
          %{"old_string" => "first old", "new_string" => "first new"},
          %{"old_string" => "second old", "new_string" => "second new"}
        ]
      })

      html = render(view)
      assert html =~ "first old"
      assert html =~ "first new"
      assert html =~ "second old"
      assert html =~ "second new"
    end

    test "an unknown shape falls back to the generic row, no diff", %{view: view, sid: sid} do
      send_tool_use(sid, "Bash", %{"command" => "ls -la"})

      html = render(view)
      assert html =~ "Bash"
      refute html =~ "var(--ok-soft)"
    end

    test "a >100-line Write collapses to ~20 lines with an accurate overflow count",
         %{view: view, sid: sid} do
      content = 1..120 |> Enum.map(&"row #{&1}") |> Enum.join("\n")
      send_tool_use(sid, "Write", %{"file_path" => "/app/big.ex", "content" => content})

      html = render(view)
      assert html =~ "<details>"
      # first ~20 lines visible in the collapsed summary
      assert html =~ "row 1"
      assert html =~ "row 20"
      # honest overflow: 120 total − 20 shown = 100 more
      assert html =~ "+100 more lines"
    end

    test "the diff engine is TextDiff — no second diff engine in api/lib" do
      # Guard against a copy-pasted Myers/LCS. TextDiff.diff_lines/2 is the ONE
      # engine; only its own definition may mention myers_difference.
      hits =
        "lib"
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.filter(&(File.read!(&1) =~ "myers_difference"))

      assert hits == [], "unexpected diff engine(s): #{inspect(hits)}"
    end

    test "replay parity: a reopened session with a persisted Edit row shows the same diff",
         %{conn: conn} do
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "tool",
          source_markdown: "Edit — file_path: /app/r.ex",
          metadata: %{
            "tool" => "Edit",
            "tool_use_id" => "toolu_r",
            "input" => %{
              "file_path" => "/app/r.ex",
              "old_string" => "stored old",
              "new_string" => "stored new"
            }
          }
        })

      {:ok, _view, html} = live(conn, "/studio/chat/#{id}")

      # display-only reopen reproduces the identical colored diff from the store
      assert html =~ "var(--ok-soft)"
      assert html =~ "var(--danger-soft)"
      assert html =~ "stored old"
      assert html =~ "stored new"
    end
  end

  describe "nested agent traces (charter D40)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "go"})
      {:ok, view: view, sid: store_id(view), conn: conn}
    end

    test "spawn dispatch is name- AND shape-tolerant: Task, Agent, and a shaped tool all show the description",
         %{view: view, sid: sid} do
      # name Task
      send_frame(sid, spawn_frame("toolu_t", "Task", "Task-named work"))
      # name Agent
      send_frame(sid, spawn_frame("toolu_a", "Agent", "Agent-named work"))
      # shape only, under an arbitrary tool name
      send_frame(sid, spawn_frame("toolu_s", "Dispatch", "Shape-only work"))

      html = render(view)
      assert html =~ "Task-named work"
      assert html =~ "Agent-named work"
      assert html =~ "Shape-only work"
    end

    test "interleaved child frames render indented under the spawn row (data-parent)",
         %{view: view, sid: sid} do
      send_frame(sid, spawn_frame("toolu_spawn", "Task", "Audit the recorder"))

      # a frame emitted by the sub-agent — top-level parent_tool_use_id set
      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "parent_tool_use_id" => "toolu_spawn",
           "message" => %{
             "content" => [
               %{"type" => "text", "text" => "reading the file"},
               %{
                 "type" => "tool_use",
                 "id" => "toolu_child",
                 "name" => "Bash",
                 "input" => %{"command" => "grep -rn parent_tool_use_id"}
               }
             ]
           }
         }}
      )

      html = render(view)
      # the spawn headline, the indented child rows, and their connecting gutter
      assert html =~ "Audit the recorder"
      assert html =~ ~s(data-parent="toolu_spawn")
      assert html =~ "reading the file"
      assert html =~ "grep -rn parent_tool_use_id"
      assert html =~ "border-left: 2px solid var(--primary)"
    end

    test "reopening replays the nested trace from the store", %{conn: conn, sid: sid} do
      send_frame(sid, spawn_frame("toolu_spawn", "Task", "Persisted spawn"))

      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "parent_tool_use_id" => "toolu_spawn",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_child",
                 "name" => "Read",
                 "input" => %{"file_path" => "/x"}
               }
             ]
           }
         }}
      )

      {:ok, _view2, html} = live(conn, "/studio/chat/#{sid}")
      assert html =~ "Persisted spawn"
      assert html =~ ~s(data-parent="toolu_spawn")
    end

    test "the parent tool_result (subagent summary) still attaches to the spawn row",
         %{view: view, sid: sid} do
      send_frame(sid, spawn_frame("toolu_spawn", "Task", "Summarize"))

      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "user",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "toolu_spawn",
                 "content" => "the subagent finished"
               }
             ]
           }
         }}
      )

      html = render(view)
      assert html =~ "⎿"
      assert html =~ "the subagent finished"
    end
  end

  describe "agent drill-down (charter D46)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "go"})
      {:ok, view: view, sid: store_id(view), conn: conn}
    end

    test "a running spawn shows the breathing progress line + step count and stays expanded",
         %{view: view, sid: sid} do
      send_frame(sid, spawn_frame("toolu_spawn", "Task", "Audit the recorder"))
      send_frame(sid, task_started("toolu_spawn", "task_1"))
      send_frame(sid, task_progress("toolu_spawn", "reading recorder.ex"))
      send_frame(sid, agent_child("toolu_spawn", "toolu_child", "grep -rn task_started"))

      html = render(view)
      # the breathing running line carries the LATEST progress description
      assert html =~ "Running: reading recorder.ex"
      assert html =~ ~s(data-agent-running="toolu_spawn")
      # a running agent is expanded by default → its child trace is nested in the
      # transcript (data-parent is transcript-only; the sidebar activity line is
      # NOT the drill-down, so we assert the nested row directly)
      assert html =~ ~s(data-parent="toolu_spawn")
      assert html =~ "grep -rn task_started"
      # the header names the agent and counts its steps
      assert html =~ "Agent(explore — Audit the recorder)"
      assert html =~ "1 step"
    end

    test "a completed agent collapses to its ⎿ report and hides the child trace by default",
         %{view: view, sid: sid} do
      send_frame(sid, spawn_frame("toolu_spawn", "Task", "Summarize the tree"))
      send_frame(sid, task_started("toolu_spawn", "task_1"))
      send_frame(sid, agent_child("toolu_spawn", "toolu_child", "hidden-child-command"))
      # the subagent's report attaches to the spawn row via the existing machinery
      send_frame(sid, tool_result_frame("toolu_spawn", "the audit is complete"))
      send_frame(sid, task_notification("toolu_spawn", "completed"))

      html = render(view)
      # collapsed → the report shows, the nested child trace does NOT, no spinner
      assert html =~ "the audit is complete"
      refute html =~ ~s(data-parent="toolu_spawn")
      refute html =~ "data-agent-running"
    end

    test "a manual toggle wins over the running-open default", %{view: view, sid: sid} do
      send_frame(sid, spawn_frame("toolu_spawn", "Task", "Long job"))
      send_frame(sid, task_started("toolu_spawn", "task_1"))
      send_frame(sid, agent_child("toolu_spawn", "toolu_child", "child-visible-here"))

      # default (running) is expanded — the nested child shows in the transcript
      assert render(view) =~ ~s(data-parent="toolu_spawn")

      # collapse it manually while it is still running
      render_click(element(view, ~s([phx-click="agent-toggle"][phx-value-id="toolu_spawn"])))
      html = render(view)
      refute html =~ ~s(data-parent="toolu_spawn")
      # …and the running line still breathes even while collapsed
      assert html =~ ~s(data-agent-running="toolu_spawn")
    end

    test "a stale agent-toggle (no matching spawn row) is a safe no-op", %{view: view} do
      # A click can land after the session switched away and the messages reset —
      # the handler must drop it, never crash the LiveView on a missing row.
      render_click(view, "agent-toggle", %{"id" => "toolu_gone"})
      assert Process.alive?(view.pid)
    end

    test "task_updated resolves the block by task_id (collapses when patched terminal)",
         %{view: view, sid: sid} do
      send_frame(sid, spawn_frame("toolu_spawn", "Task", "Patched job"))
      send_frame(sid, task_started("toolu_spawn", "task_9"))
      send_frame(sid, agent_child("toolu_spawn", "toolu_child", "patch-child-command"))
      assert render(view) =~ ~s(data-parent="toolu_spawn")

      # task_updated carries NO tool_use_id — it resolves via the task_id the row
      # learned from task_started
      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "system",
           "subtype" => "task_updated",
           "task_id" => "task_9",
           "patch" => %{"status" => "completed", "end_time" => 123}
         }}
      )

      html = render(view)
      refute html =~ ~s(data-parent="toolu_spawn")
      refute html =~ "data-agent-running"
    end

    test "two parallel spawns with interleaved children attribute each child to the right block",
         %{view: view, sid: sid} do
      # both spawns launch, then their children INTERLEAVE in seq order — grouping
      # must be by parent-id match, never by consecutive position
      send_frame(sid, spawn_frame("toolu_a", "Task", "Agent A"))
      send_frame(sid, spawn_frame("toolu_b", "Task", "Agent B"))
      send_frame(sid, agent_child("toolu_a", "toolu_a1", "child-of-A"))
      send_frame(sid, agent_child("toolu_b", "toolu_b1", "child-of-B"))
      send_frame(sid, agent_child("toolu_a", "toolu_a2", "second-child-of-A"))

      html = render(view)
      # each child is nested under its OWN spawn (data-parent match), all visible
      assert html =~ ~s(data-parent="toolu_a")
      assert html =~ ~s(data-parent="toolu_b")
      assert html =~ "child-of-A"
      assert html =~ "child-of-B"
      assert html =~ "second-child-of-A"
      # Agent A owns 2 steps, Agent B owns 1 — proves interleave didn't misattribute
      assert html =~ "2 steps"
      assert html =~ "1 step"
    end

    test "a manual expand wins even across the running→completed transition",
         %{view: view, sid: sid} do
      send_frame(sid, spawn_frame("toolu_spawn", "Task", "Transition job"))
      send_frame(sid, task_started("toolu_spawn", "task_1"))
      send_frame(sid, agent_child("toolu_spawn", "toolu_child", "transition-child"))

      # collapse manually while running, then let it complete — the OVERRIDE (open?
      # no: collapsed) must survive the terminal default flip. Re-expand and prove
      # the manual choice sticks past completion.
      render_click(element(view, ~s([phx-click="agent-toggle"][phx-value-id="toolu_spawn"])))
      send_frame(sid, task_notification("toolu_spawn", "completed"))
      # a completed block defaults collapsed; our override says collapsed too — flip
      # it open manually and confirm it STAYS open despite the terminal default
      render_click(element(view, ~s([phx-click="agent-toggle"][phx-value-id="toolu_spawn"])))
      html = render(view)
      assert html =~ ~s(data-parent="toolu_spawn")
      refute html =~ "data-agent-running"
    end

    test "the value-equality guard makes an identical repeated frame a no-op (no reassign)",
         %{view: view, sid: sid} do
      send_frame(sid, spawn_frame("toolu_spawn", "Task", "Idempotent job"))
      send_frame(sid, task_started("toolu_spawn", "task_1"))
      send_frame(sid, task_progress("toolu_spawn", "same line"))
      render(view)

      before = :sys.get_state(view.pid).socket.assigns.messages
      # an identical progress frame carries no new information
      send_frame(sid, task_progress("toolu_spawn", "same line"))
      render(view)
      after_msgs = :sys.get_state(view.pid).socket.assigns.messages

      # value equality → the messages list is returned UNCHANGED (same term)
      assert before == after_msgs
    end

    test "an orphan child (no matching spawn in this transcript) still renders indented",
         %{view: view, sid: sid} do
      # a child frame whose parent spawn never appeared — it must NOT vanish
      send_frame(sid, agent_child("toolu_ghost", "toolu_orphan", "orphan-work-line"))

      html = render(view)
      assert html =~ "orphan-work-line"
      assert html =~ ~s(data-parent="toolu_ghost")
      assert html =~ "border-left: 2px solid var(--primary)"
    end

    test "replay hydrates the last task line for a mid-run reopen", %{conn: conn} do
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "tool",
          source_markdown: "Task — Persisted run",
          metadata: %{
            "tool" => "Task",
            "tool_use_id" => "toolu_spawn",
            "input" => %{
              "description" => "Persisted run",
              "prompt" => "x",
              "subagent_type" => "explore"
            },
            "task_id" => "task_1",
            "task_status" => "running",
            "task_progress" => "still reading files"
          }
        })

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "tool",
          source_markdown: "Bash — replayed-child-line",
          metadata: %{
            "tool" => "Bash",
            "tool_use_id" => "toolu_child",
            "parent_tool_use_id" => "toolu_spawn",
            "input" => %{"command" => "irrelevant"}
          }
        })

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, "/studio/chat/#{id}")
      # honest last-persisted running line + the nested child (running → expanded)
      assert html =~ "Running: still reading files"
      assert html =~ "replayed-child-line"
      assert html =~ ~s(data-parent="toolu_spawn")
    end

    test "replay of an interrupted agent shows its report, no spinner", %{conn: conn} do
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "tool",
          source_markdown: "Task — Aborted run",
          metadata: %{
            "tool" => "Task",
            "tool_use_id" => "toolu_spawn",
            "input" => %{
              "description" => "Aborted run",
              "prompt" => "x",
              "subagent_type" => "explore"
            },
            "task_id" => "task_1",
            "task_status" => "interrupted"
          }
        })

      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, _view, html} = live(conn, "/studio/chat/#{id}")
      assert html =~ "Aborted run"
      refute html =~ "data-agent-running"
    end
  end

  describe "agents rail — mission control below the composer (charter D47)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "go"})
      {:ok, view: view, sid: store_id(view), conn: conn}
    end

    defp bg_changed(tasks),
      do:
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "background_tasks_changed", "tasks" => tasks}}

    defp wf_progress(task_id, workflow, usage),
      do:
        {:claude_chat_event,
         %{
           "type" => "system",
           "subtype" => "task_progress",
           "task_id" => task_id,
           "workflow_progress" => workflow,
           "usage" => usage
         }}

    test "background_tasks_changed renders a live rail row below the composer",
         %{view: view, sid: sid} do
      send_frame(
        sid,
        bg_changed([
          %{"task_id" => "t", "task_type" => "local_workflow", "description" => "Build the rail"}
        ])
      )

      html = render(view)
      assert html =~ ~s(data-role="agents-rail")
      assert html =~ ~s(data-rail-task="t")
      assert html =~ ~s(data-rail-status="running")
      assert html =~ "Build the rail"
    end

    test "a workflow row expands into its phase→agent tree with model + token counts",
         %{view: view, sid: sid} do
      send_frame(
        sid,
        bg_changed([%{"task_id" => "t", "task_type" => "local_workflow", "description" => "wf"}])
      )

      send_frame(
        sid,
        wf_progress(
          "t",
          [
            %{"type" => "workflow_phase", "title" => "Explore"},
            %{"type" => "workflow_agent", "label" => "explorer", "model" => "fable", "state" => "running", "tokens" => 128}
          ],
          %{"total_tokens" => 128}
        )
      )

      # collapsed by default → the phase→agent tree is hidden
      refute render(view) =~ "explorer"

      render_click(element(view, ~s([phx-click="rail-toggle"][phx-value-id="t"])))
      html = render(view)
      assert html =~ "Explore"
      assert html =~ "explorer"
      assert html =~ "fable"
      assert html =~ "128 tok"
    end

    test "a token-only workflow tick does NOT re-render the rail; a state flip does",
         %{view: view, sid: sid} do
      send_frame(
        sid,
        bg_changed([%{"task_id" => "t", "task_type" => "local_workflow", "description" => "wf"}])
      )

      send_frame(
        sid,
        wf_progress(
          "t",
          [%{"type" => "workflow_agent", "label" => "a", "state" => "running", "tokens" => 10}],
          %{"total_tokens" => 10}
        )
      )

      sig1 = lv_assigns(view)[:rail_sig]

      # identical structure, only tokens advanced ⇒ value-equality no-op
      send_frame(
        sid,
        wf_progress(
          "t",
          [%{"type" => "workflow_agent", "label" => "a", "state" => "running", "tokens" => 9_999}],
          %{"total_tokens" => 9_999}
        )
      )

      assert lv_assigns(view)[:rail_sig] == sig1

      # a state flip is structural ⇒ the signature (and render) changes
      send_frame(
        sid,
        wf_progress(
          "t",
          [%{"type" => "workflow_agent", "label" => "a", "state" => "completed", "tokens" => 9_999}],
          %{}
        )
      )

      refute lv_assigns(view)[:rail_sig] == sig1
    end

    test "a vanished task flips its rail row to done, keeping the entry",
         %{view: view, sid: sid} do
      send_frame(
        sid,
        bg_changed([
          %{"task_id" => "a", "task_type" => "local_workflow", "description" => "one"},
          %{"task_id" => "b", "task_type" => "local_workflow", "description" => "two"}
        ])
      )

      send_frame(
        sid,
        bg_changed([%{"task_id" => "b", "task_type" => "local_workflow", "description" => "two"}])
      )

      html = render(view)
      # "a" is gone from the wire but its row survives as done
      assert html =~ ~s(data-rail-task="a")
      assert lv_assigns(view)[:rail]["a"]["status"] == "completed"
    end

    test "replay hydrates the rail; a reopened interrupted entry shows no running row",
         %{conn: conn} do
      {:ok, s} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})

      {:ok, _} =
        StudioChat.set_rail_snapshot(s.id, %{
          "t" => %{
            "row" => %{"task_type" => "local_workflow", "description" => "was running"},
            "status" => "interrupted",
            "seq" => 1,
            "workflow" => [%{"type" => "workflow_agent", "label" => "explorer", "state" => "running"}]
          }
        })

      {:ok, view, _html} = live(conn, "/studio/chat/#{s.id}")
      html = render(view)

      assert html =~ ~s(data-rail-task="t")
      assert html =~ ~s(data-rail-status="interrupted")
      assert html =~ "interrupted"
      assert html =~ "was running"
      # the honest last-known rail: NOTHING renders as a live running row
      refute html =~ ~s(data-rail-status="running")
    end
  end

  describe "model picker (wave 5)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      {:ok, view: view}
    end

    test "the picker renders every allowlisted alias + default", %{view: view} do
      html = render(view)
      assert html =~ "model: default"
      assert html =~ "Haiku — fastest"
      assert html =~ "Opus — powerful"
      assert html =~ "Fable — frontier"
    end

    test "picking a model persists the choice and confirms honestly", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hello"})
      sid = store_id(view)

      html = render_change(element(view, ~s(form[phx-change=set-model])), %{"model" => "opus"})

      assert html =~ "Model → Opus — powerful."
      assert StudioChat.get_session(sid).model_choice == "opus"
    end

    test "an unknown model value fail-closes to the CLI default", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hello"})
      sid = store_id(view)

      html =
        render_change(element(view, ~s(form[phx-change=set-model])), %{"model" => "evil-model"})

      assert html =~ "Model → the CLI default."
      assert StudioChat.get_session(sid).model_choice == nil
    end

    test "a stored choice reloads with the session", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hello"})
      sid = store_id(view)
      render_change(element(view, ~s(form[phx-change=set-model])), %{"model" => "sonnet"})

      # navigate away and back — the picker follows the stored intent
      render_patch(view, "/studio/chat")
      assert render(view) =~ "model: default"
      render_patch(view, "/studio/chat/#{sid}")
      html = render(view)
      assert html =~ ~s(value="sonnet" selected)
    end
  end

  describe "effort picker (wave 9, charter D48)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      {:ok, view: view}
    end

    test "the picker renders every tier composed with the model (Fable · high)",
         %{view: view} do
      html = render(view)
      assert html =~ "effort: default"
      # every allowlisted tier is offered
      for e <- ~w(low medium high xhigh max), do: assert(html =~ ~s(value="#{e}"))
      # composed as one group with the model select (the dim "·" separator)
      assert html =~ "·"
    end

    test "picking a tier persists it and confirms honestly", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hello"})
      sid = store_id(view)

      html = render_change(element(view, ~s(form[phx-change=set-effort])), %{"effort" => "high"})

      # mid-session (a live session is up) → the honest next-resume line
      assert html =~ "Effort → high (applies from the next resume)."
      assert StudioChat.get_session(sid).effort_choice == "high"
    end

    test "an unknown tier fail-closes to the CLI default", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hello"})
      sid = store_id(view)

      html = render_change(element(view, ~s(form[phx-change=set-effort])), %{"effort" => "ludicrous"})

      assert html =~ "Effort → the CLI default"
      assert StudioChat.get_session(sid).effort_choice == nil
    end

    test "a stored tier reloads with the session", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hello"})
      sid = store_id(view)
      render_change(element(view, ~s(form[phx-change=set-effort])), %{"effort" => "max"})

      render_patch(view, "/studio/chat")
      render_patch(view, "/studio/chat/#{sid}")
      assert render(view) =~ ~s(value="max" selected)
    end
  end

  describe "bypass arm ceremony UI (wave 9, charter D48)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      {:ok, view: view}
    end

    test "the arm panel is hidden until bypass is picked", %{view: view} do
      refute has_element?(view, ~s(button[phx-click=arm-bypass]))

      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "bypassPermissions"})
      assert has_element?(view, ~s(button[phx-click=arm-bypass]))
    end

    test "the Arm button is disabled until the exact word is typed", %{view: view} do
      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "bypassPermissions"})
      assert has_element?(view, ~s(button[phx-click=arm-bypass][disabled]))

      render_change(element(view, ~s(form[phx-change=bypass-confirm])), %{"confirm" => "bypass"})
      refute has_element?(view, ~s(button[phx-click=arm-bypass][disabled]))
    end

    test "arming persists bypass and posts the honest, non-live line (no set_mode steer)",
         %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      send(view.pid, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})
      sid = store_id(view)

      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "bypassPermissions"})
      render_change(element(view, ~s(form[phx-change=bypass-confirm])), %{"confirm" => "bypass"})
      html = render_click(element(view, ~s(button[phx-click=arm-bypass])))

      # persisted on the row (the only road to a persisted bypass)
      assert StudioChat.get_session(sid).mode == "bypassPermissions"
      # honest: it does NOT steer the running turn, it arms the next resume
      assert html =~ "ARMED"
      assert html =~ "next resume"
      # NEVER a pending set_mode steer for bypass (unlike the other five modes)
      assert lv_assigns(view)[:pending_mode] == nil
    end

    test "cancel closes the panel and never arms", %{view: view} do
      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "bypassPermissions"})
      assert has_element?(view, ~s(button[phx-click=arm-bypass]))

      render_click(element(view, ~s(button[phx-click=cancel-arm-bypass])))
      refute has_element?(view, ~s(button[phx-click=arm-bypass]))
      assert lv_assigns(view)[:mode] == "plan"
    end

    # Enter in the confirm input must ARM (phx-submit), never fall through to a
    # native form submit that navigates the LiveView away — and the submit path
    # rides the SAME server-side exact-word guard as the button.
    test "Enter in the confirm input arms via phx-submit, word-guarded", %{view: view} do
      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "bypassPermissions"})

      # wrong word: submit never arms, panel stays open for another try
      render_change(element(view, ~s(form[phx-change=bypass-confirm])), %{"confirm" => "nope"})
      render_submit(element(view, ~s(form[phx-submit=arm-bypass])), %{"confirm" => "nope"})
      assert lv_assigns(view)[:mode] == "plan"
      assert has_element?(view, ~s(button[phx-click=arm-bypass]))

      # exact word: Enter arms without touching the button
      render_change(element(view, ~s(form[phx-change=bypass-confirm])), %{"confirm" => "bypass"})
      html = render_submit(element(view, ~s(form[phx-submit=arm-bypass])), %{"confirm" => "bypass"})
      assert lv_assigns(view)[:mode] == "bypassPermissions"
      assert html =~ "ARMED"
    end
  end

  describe "living sidebar cards (wave 5)" do
    setup %{conn: conn} do
      enable_fake_chat()
      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    # A SECOND session works in the background while the tab views the first:
    # its card must show the live pill + the concrete tool line — the sidebar
    # is a window into every running agent, not a stale list.
    test "a background session's card shows working + its current tool line", %{conn: conn} do
      {:ok, view, _} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "mine"})
      # a second, BACKGROUND session with its own runtime
      other = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: other, mode: "plan", title: "Background job"})

      {:ok, _rec} =
        Barkpark.StudioChat.Recorder.ensure(%{session_id: other, mode: "plan", resume: false})

      render(view)

      send_frame(
        other,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "mix test"}}
             ]
           }
         }}
      )

      html = render(view)
      assert html =~ ~s(data-test-id="chat-activity-#{other}")
      assert html =~ "mix test"
      # the working pill pulses (live dot present)
      assert html =~ "bp-chat-live-dot"
    end

    test "the live line yields to the stored summary when the turn completes", %{conn: conn} do
      {:ok, view, _} = live(conn, "/studio/chat")
      other = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: other, mode: "plan", title: "Background job"})

      {:ok, _rec} =
        Barkpark.StudioChat.Recorder.ensure(%{session_id: other, mode: "plan", resume: false})

      send_frame(
        other,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{"content" => [%{"type" => "text", "text" => "The final answer."}]}
         }}
      )

      assert render(view) =~ ~s(data-test-id="chat-activity-#{other}")

      send_frame(other, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})

      html = render(view)
      # overlay gone; the stored summary (owned by the store row) shows instead
      refute html =~ ~s(data-test-id="chat-activity-#{other}")
      assert html =~ "The final answer."
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

      send_frame(
        sid,
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

    test "the first tab keeps co-viewing (no detach, no frozen composer) when a second opens",
         %{conn: conn} do
      {view_a, sid, owner} = start_live_session_with_pending(conn, "req-coview")

      {:ok, view_b, _html} = live(conn, "/studio/chat/#{sid}")

      # wave 4: the runtime is server-owned — BOTH tabs stay live viewers of
      # the SAME session process; neither composer freezes.
      assert session_pid(view_b) == owner
      assert has_element?(view_a, "form[phx-submit=send]")
      assert has_element?(view_b, "form[phx-submit=send]")

      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{"content" => [%{"type" => "text", "text" => "co-viewed answer"}]}
         }}
      )

      assert render(view_a) =~ "co-viewed answer"
      assert render(view_b) =~ "co-viewed answer"
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

    # ── effort rides the spawn end-to-end (charter D48) ──────────────────────

    test "a chosen effort rides the FRESH spawn as --effort", %{conn: conn, marker: marker} do
      {:ok, view, _html} = live(conn, "/studio/chat")

      render_change(element(view, ~s(form[phx-change=set-effort])), %{"effort" => "high"})
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "brand new"})

      argv = read_marker(marker)
      assert argv =~ "--effort"
      assert argv =~ "high"
    end

    test "effort persists and rides the RESUME spawn too", %{conn: conn, marker: marker} do
      sid = seed_session_with_history()
      {:ok, _} = StudioChat.set_effort_choice(sid, "xhigh")

      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "continue"})

      argv = read_marker(marker)
      assert argv =~ "--resume"
      assert argv =~ "--effort"
      assert argv =~ "xhigh"
    end

    # ── bypass arming end-to-end (charter D48 — the ceremony IS the only road) ─

    test "an ARMED bypass spawns with both the mode and the danger flag",
         %{conn: conn, marker: marker} do
      {:ok, view, _html} = live(conn, "/studio/chat")

      # pick bypass → opens the arm panel (mode still plan, nothing persisted)
      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "bypassPermissions"})
      assert lv_assigns(view)[:mode] == "plan"

      # type the confirm word, then arm
      render_change(element(view, ~s(form[phx-change=bypass-confirm])), %{"confirm" => "bypass"})
      render_click(element(view, ~s(button[phx-click=arm-bypass])))
      assert lv_assigns(view)[:mode] == "bypassPermissions"

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "go wild"})

      argv = read_marker(marker)
      assert argv =~ "bypassPermissions"
      assert argv =~ "--allow-dangerously-skip-permissions"
    end

    test "a bypass pick WITHOUT arming spawns fail-closed (plan, no danger flag)",
         %{conn: conn, marker: marker} do
      {:ok, view, _html} = live(conn, "/studio/chat")

      # pick bypass but NEVER complete the ceremony
      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "bypassPermissions"})
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "no arming"})

      argv = read_marker(marker)
      assert argv =~ "--permission-mode"
      assert argv =~ "plan"
      refute argv =~ "bypassPermissions"
      refute argv =~ "--allow-dangerously-skip-permissions"
    end

    test "typing the wrong confirm word never arms (Arm is a no-op)",
         %{conn: conn, marker: marker} do
      {:ok, view, _html} = live(conn, "/studio/chat")

      render_change(element(view, ~s(form[phx-change=set-mode])), %{"mode" => "bypassPermissions"})
      render_change(element(view, ~s(form[phx-change=bypass-confirm])), %{"confirm" => "yes"})
      # the button is disabled client-side; a FORGED event by name still hits the
      # server guard, which refuses to arm on the wrong word (defense in depth).
      render_click(view, "arm-bypass", %{})
      assert lv_assigns(view)[:mode] == "plan"

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "still safe"})
      argv = read_marker(marker)
      refute argv =~ "--allow-dangerously-skip-permissions"
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

  describe "composer power — slash builtins + sticky draft/model (wave 6, charter D36)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, conn: conn}
    end

    test "the slash menu is hook-owned so composer round-trips can't close it", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/chat")

      # regression: the composer is server-bound (D24) — every keystroke
      # round-trips, and without phx-update="ignore" the returning patch
      # re-applied `hidden` and wiped the menu milliseconds after it opened.
      assert html =~ ~r/<ul[^>]*id="chat-slash-menu"[^>]*phx-update="ignore"/s or
               html =~ ~r/<ul[^>]*phx-update="ignore"[^>]*id="chat-slash-menu"/s
    end

    test "the composer stamps the builtin slash vocabulary on the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/chat")

      assert html =~ ~s(id="chat-slash-menu")
      assert html =~ ~s(role="combobox")
      # The two control builtins are the hard floor (charter D48 retired /default).
      assert html =~ "/plan"
      assert html =~ "/model"
    end

    test "the retired /default builtin is gone from the floor", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/studio/chat")
      refute html =~ "/default"
    end

    test "a /default submit is NO LONGER a builtin — it rides as user text (D48)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")
      assert lv_assigns(view)[:mode] == "plan"

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "/default"})

      # the retired builtin no longer steers the mode — it is ordinary text, so a
      # session spawns and the words reach the model
      assert lv_assigns(view)[:mode] == "plan"
      assert session_pid(view) != nil
    end

    test "a /model opus slash submit switches the model WITHOUT sending a turn",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "/model opus"})

      assert lv_assigns(view)[:model_choice] == "opus"
      refute turn_active_status?(view)
      assert render(view) =~ "Model →"
    end

    test "a bare /model submit shows usage and changes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")

      html = render_submit(element(view, "form[phx-submit=send]"), %{"message" => "/model"})

      assert html =~ "Usage: /model"
      assert lv_assigns(view)[:model_choice] == "default"
    end

    test "an unrecognized /model alias shows usage and KEEPS the current choice",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "/model opus"})
      assert lv_assigns(view)[:model_choice] == "opus"

      # a typo must not silently reset the sticky choice to the CLI default
      html = render_submit(element(view, "form[phx-submit=send]"), %{"message" => "/model opsu"})

      assert html =~ "Usage: /model"
      assert lv_assigns(view)[:model_choice] == "opus"
    end

    test "an explicit /model default resets to the CLI default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "/model fable"})
      assert lv_assigns(view)[:model_choice] == "fable"

      html =
        render_submit(element(view, "form[phx-submit=send]"), %{"message" => "/model default"})

      assert html =~ "Model → the CLI default"
      assert lv_assigns(view)[:model_choice] == "default"
    end

    test "an advertised (non-builtin) slash command is sent as plain user text",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")

      html = render_submit(element(view, "form[phx-submit=send]"), %{"message" => "/compact"})

      # Not a builtin → flows through the normal send path (user bubble + turn).
      assert html =~ "/compact"
      assert html =~ ~s(data-role="user")
      assert turn_active_status?(view)
    end

    test "a chat_commands broadcast populates the advertised menu vocabulary",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")

      send(
        view.pid,
        {:chat_commands, "any", [%{"name" => "review", "description" => "Code review"}]}
      )

      html = render(view)

      # The stamped vocab now carries the advertised command AND still floors the
      # builtins — dedupe keeps all four present.
      assert html =~ "review"
      assert html =~ "/plan"
    end

    test "a sticky draft round-trips across a session switch and clears on send",
         %{conn: conn} do
      a = seed_session("Session A")
      b = seed_session("Session B")

      {:ok, view, _html} = live(conn, "/studio/chat/#{a}")

      # Type a draft into A, then switch to B and back.
      render_change(element(view, "form[phx-submit=send]"), %{"message" => "unfinished A thought"})

      render_patch(view, "/studio/chat/#{b}")
      render_patch(view, "/studio/chat/#{a}")

      # A's unsent words are restored verbatim (server-bound value assign, D24).
      assert lv_assigns(view)[:composer_draft] == "unfinished A thought"
      assert StudioChat.get_session(a).draft == "unfinished A thought"

      # Sending clears the persisted draft — a reopen shows a clean composer.
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "actually send"})
      assert StudioChat.get_session(a).draft == nil
    end

    test "a new chat inherits the last non-default model choice (sticky model)",
         %{conn: conn} do
      prev = seed_session("picked opus")
      {:ok, _} = StudioChat.set_model_choice(prev, "opus")

      {:ok, view, _html} = live(conn, "/studio/chat")

      assert lv_assigns(view)[:model_choice] == "opus"
    end
  end

  # ══ gutter geometry matrix — rendered-HTML flush-text assertions (D50) ══════
  #
  # Three alignment bugs shipped this week — #1844 (pre-wrap template whitespace),
  # #1849 (paper first-block margin), and the tool-row wrap — from ONE blind spot:
  # nothing asserted rendered-HTML GEOMETRY. The existing #1844/#1849 regression
  # tests are string-presence proxies (#1849's passes with zero matching elements;
  # #1844's fires on the setup's user row). This matrix closes the class:
  #
  #   (1) a generic flush guard (`assert_flush_gutter_text/1`) over every
  #       `data-gutter-text` carrier — a gutter TEXT node that MUST begin flush
  #       after its opening tag. The #1844 defect lived in the SERIALIZED bytes
  #       (an interpolation on its own indented template line baked a leading
  #       "\n<indent>" INTO a pre-wrap text node), so the RAW render string is
  #       more faithful here than a normalizing parser.
  #   (2) a first-block structural check (`assert_first_block_flush_rule/1`) at
  #       the honest ceiling — computed margin-top is unobservable from static
  #       HTML (no headless browser), so we assert what IS observable: the
  #       `.bp-paper-surface.bp-chat-md > :first-child` EXISTS and is a block
  #       element the #1849 rule targets, plus the rule text is present.
  #       Rule-presence-and-structure, NOT computed geometry — documented as such.
  #   (3) each gutter ROW TYPE × the content shapes it actually renders, driven
  #       by fixture frames through the REAL Recorder (or the live-chrome path
  #       for streaming/thinking) — a new row type inherits the guard by adding
  #       one line, never a bespoke assertion.
  describe "gutter geometry matrix — flush-text assertions (charter D50)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "go"})
      {:ok, view: view, sid: store_id(view), conn: conn}
    end

    # ── ❯ user prompt × real prose shapes ────────────────────────────────────
    test "❯ user rows render flush for every shape (plain / multiline / wrapped / long-word)",
         %{conn: conn} do
      sid = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: sid, cwd: "/tmp", mode: "plan"})
      long_word = String.duplicate("z", 90)

      for md <- [
            "a plain single-line prompt",
            "first line\nsecond line\nthird line",
            String.duplicate("wrap ", 45),
            "before-#{long_word}-after"
          ] do
        {:ok, _} = StudioChat.append_message(sid, %{role: "user", source_markdown: md})
      end

      {:ok, _view, html} = live(conn, "/studio/chat/#{sid}")

      assert html =~ "a plain single-line prompt"
      assert html =~ "second line"
      assert html =~ long_word
      # the ❯ glyph pairs with a flush pre-wrap text node — no leading newline
      # baked into any user prompt (the #1844 class), across all four shapes
      assert_flush_gutter_text(html)
    end

    # ── ● assistant paper-html × (heading-first / paragraph / multiline) ──────
    test "● assistant heading-first bubble: the first block is a rule-targeted block element, flush",
         %{view: view, sid: sid} do
      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [%{"type" => "text", "text" => "# Big heading\n\nThen a paragraph."}]
           }
         }}
      )

      html = render(view)
      assert html =~ "Big heading"
      # #1849: the bubble's first block starts flush with the ● glyph — rule text
      # present AND the first child is a block element the rule targets (an <h1>)
      assert_first_block_flush_rule(html, "h1")
      assert_flush_gutter_text(html)
    end

    test "● assistant paragraph-first and multiline bubbles keep the first-block rule",
         %{view: view, sid: sid} do
      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{"type" => "text", "text" => "Just prose, no heading.\n\nA second paragraph too."}
             ]
           }
         }}
      )

      html = render(view)
      assert html =~ "Just prose, no heading."
      assert html =~ "A second paragraph too."
      # a paragraph-first bubble's first child is a <p> the same rule targets
      assert_first_block_flush_rule(html, "p")
      assert_flush_gutter_text(html)
    end

    # ── ● tool row + ⎿ output (inline single-line + multiline <pre>) ──────────
    test "● tool row + ⎿ multiline output render flush (the pre carries no template indent)",
         %{view: view, sid: sid} do
      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_gm",
                 "name" => "Bash",
                 "input" => %{"command" => "mix test"}
               }
             ]
           }
         }}
      )

      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "user",
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "toolu_gm",
                 "content" => "line one\nline two\nline three"
               }
             ]
           }
         }}
      )

      html = render(view)
      # the ● tool row (a plain, non-spawn label) and its ⎿ multiline <pre>
      assert html =~ "Bash"
      assert html =~ "⎿"
      assert html =~ "line one"
      assert html =~ "line three"
      assert_flush_gutter_text(html)
    end

    # ── ✻ thinking (the live pulse) ──────────────────────────────────────────
    test "✻ thinking pulse renders the cumulative counter and keeps every carrier flush",
         %{view: view} do
      send(view.pid, {:claude_chat_event, thinking_tokens(42)})
      send(view.pid, {:claude_chat_event, thinking_tokens(128)})

      html = render(view)
      assert html =~ "✻" or html =~ "bp-chat-spinner"
      assert html =~ "128"
      assert_flush_gutter_text(html)
    end

    # ── todo card (☐ / ◐ / ☒) ────────────────────────────────────────────────
    test "the todo card items render flush across the three statuses",
         %{view: view, sid: sid} do
      send_frame(
        sid,
        todo_frame("toolu_todo", [
          %{"content" => "explore the tree", "status" => "completed"},
          %{"content" => "write the matrix", "status" => "in_progress", "activeForm" => "Writing"},
          %{"content" => "run the gate", "status" => "pending"}
        ])
      )

      html = render(view)
      assert html =~ "Update todos"
      assert html =~ "explore the tree"
      assert html =~ "write the matrix"
      assert html =~ "run the gate"
      assert_flush_gutter_text(html)
    end

    # ── agent drill-down block (header + running line + ⎿ report) ─────────────
    test "the agent block header, running line, nested child, and ⎿ report render flush",
         %{view: view, sid: sid} do
      send_frame(sid, spawn_frame("toolu_ag", "Task", "Audit the recorder"))
      send_frame(sid, task_started("toolu_ag", "task_gm"))
      send_frame(sid, task_progress("toolu_ag", "reading recorder.ex"))
      send_frame(sid, agent_child("toolu_ag", "toolu_ag_kid", "grep -rn task_started"))
      send_frame(sid, tool_result_frame("toolu_ag", "subreport line one\nsubreport line two"))

      html = render(view)
      assert html =~ "Agent(explore — Audit the recorder)"
      assert html =~ "Running: reading recorder.ex"
      # the nested child (rendered byte-identically via message_body) AND the ⎿
      # multiline report <pre> both carry the gutter-text guard
      assert html =~ ~s(data-parent="toolu_ag")
      assert html =~ "grep -rn task_started"
      assert html =~ "⎿"
      assert_flush_gutter_text(html)
    end

    # ── plan body via its .bp-paper-surface.bp-chat-md class (D50 forbids ─────
    #    touching the :plan branch — S3 owns it; here we only ASSERT geometry) ─
    test "the proposed-plan card body shares the .bp-chat-md first-block rule",
         %{view: view} do
      # a live ExitPlanMode ask paints the pending plan card; its body renders the
      # plan markdown through the SAME paper engine + .bp-chat-md class, so the
      # #1849 first-child rule covers it too (asserted, never re-broken here)
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "plan it"})

      send(
        view.pid,
        {:claude_chat_permission,
         %{
           request_id: "gm-plan",
           tool_name: "ExitPlanMode",
           input: %{"plan" => "# Plan heading\n\nStep one.\n\nStep two."},
           title: nil,
           decision_reason: nil
         }}
      )

      html = render(view)
      assert html =~ "proposed plan"
      assert html =~ "Plan heading"
      # the plan body's first block is a rule-targeted <h1>, flush like any bubble
      assert_first_block_flush_rule(html, "h1")
      assert_flush_gutter_text(html)
    end

    # ── ⧗ queued mid-turn ❯ row ───────────────────────────────────────────────
    test "a mid-turn queued ❯ row renders flush with its badge", %{view: view} do
      # the setup's "go" turn is still live (cat never sends a result), so a second
      # send is mid-turn → an echoed ❯ row wearing the ⧗ queued badge
      html = render_submit(element(view, "form[phx-submit=send]"), %{"message" => "queued prompt"})
      assert html =~ "queued prompt"
      assert html =~ "⧗ queued"
      assert_flush_gutter_text(html)
    end

    # ── live-chrome: the streaming tail (charter D37/D41) ─────────────────────
    test "the live streaming tail (live-chrome) renders flush", %{view: view} do
      send(view.pid, {:claude_chat_event, stream_delta("streaming prose with no leading indent")})

      html = render(view)
      assert html =~ "streaming prose with no leading indent"
      assert_flush_gutter_text(html)
    end
  end

  # ── D50 generic assertions (module-scope; shared by the matrix above) ───────

  # Block-level tags the #1849 `.bp-paper-surface.bp-chat-md > :first-child`
  # margin rule can meaningfully target. A gutter bubble's first child is always
  # one of these; an inline/text first child would mean the paper engine changed
  # shape and the rule silently stopped applying.
  @gutter_block_tags ~w(h1 h2 h3 h4 h5 h6 p ul ol pre blockquote table div)

  # Every `data-gutter-text` node is a gutter TEXT node — the text paired with a
  # ❯/●/✻/⎿ glyph, which MUST render flush after its opening tag. This refutes the
  # #1844 class (a leading template newline/indent baked into the serialized text)
  # for the whole class in one pass; it is deliberately raw-string, not parsed,
  # because the defect lives in the bytes a normalizing parser would swallow.
  defp assert_flush_gutter_text(html) do
    assert html =~ "data-gutter-text",
           "expected at least one data-gutter-text carrier in the render (guard would be vacuous)"

    refute html =~ ~r/data-gutter-text[^>]*>\s*\n/,
           "a data-gutter-text node begins with template whitespace — the #1844 alignment-bug class"

    html
  end

  # The #1849 first-block check at the HONEST CEILING. Computed margin-top is not
  # observable from static HTML, so this proves (a) the rule TEXT is present and
  # (b) the `.bp-paper-surface.bp-chat-md > :first-child` element EXISTS and is a
  # block element the rule targets, pinned to the expected tag. This is
  # rule-presence-AND-structure, NOT geometry — no headless browser, by design.
  defp assert_first_block_flush_rule(html, expected_tag) do
    assert html =~ ".bp-paper-surface.bp-chat-md > :first-child",
           "the #1849 first-child margin rule text is missing"

    assert html =~ "margin-top: 0", "the #1849 margin-top:0 declaration is missing"

    first = html |> LazyHTML.from_fragment() |> LazyHTML.query(".bp-paper-surface.bp-chat-md > :first-child")

    assert Enum.count(first) >= 1,
           "no .bp-paper-surface.bp-chat-md > :first-child element — the #1849 rule targets nothing"

    [tag | _] = LazyHTML.tag(first)

    assert tag in @gutter_block_tags,
           "the bubble's first child is <#{tag}>, not a block element the margin rule can target"

    assert tag == expected_tag, "expected first block <#{expected_tag}>, got <#{tag}>"

    html
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

  # A TodoWrite-shaped assistant frame (charter D39) with a FRESH tool_use id.
  defp todo_frame(id, todos) do
    {:claude_chat_event,
     %{
       "type" => "assistant",
       "message" => %{
         "content" => [
           %{
             "type" => "tool_use",
             "id" => id,
             "name" => "TodoWrite",
             "input" => %{"todos" => todos}
           }
         ]
       }
     }}
  end

  # How many living-checklist cards a rendered transcript carries.
  defp todo_card_count(html), do: length(String.split(html, "Update todos")) - 1

  # A Task/agent spawn frame (charter D40): a single tool_use carrying the
  # sub-agent input shape, so both name- and shape-tolerant dispatch light up.
  defp spawn_frame(id, name, description) do
    {:claude_chat_event,
     %{
       "type" => "assistant",
       "message" => %{
         "content" => [
           %{
             "type" => "tool_use",
             "id" => id,
             "name" => name,
             "input" => %{
               "description" => description,
               "prompt" => "do the thing",
               "subagent_type" => "explore"
             }
           }
         ]
       }
     }}
  end

  # Task-lifecycle frames (charter D45/D46) driving an agent drill-down block.
  # task_started/task_progress/task_notification carry tool_use_id; task_updated
  # is task_id-only (tested inline above).
  defp task_started(tool_use_id, task_id) do
    {:claude_chat_event,
     %{
       "type" => "system",
       "subtype" => "task_started",
       "tool_use_id" => tool_use_id,
       "task_id" => task_id
     }}
  end

  defp task_progress(tool_use_id, description) do
    {:claude_chat_event,
     %{
       "type" => "system",
       "subtype" => "task_progress",
       "tool_use_id" => tool_use_id,
       "description" => description
     }}
  end

  defp task_notification(tool_use_id, status) do
    {:claude_chat_event,
     %{
       "type" => "system",
       "subtype" => "task_notification",
       "tool_use_id" => tool_use_id,
       "status" => status,
       "summary" => "done"
     }}
  end

  # A sub-agent's own frame: a top-level parent_tool_use_id plus a nested Bash
  # tool_use so the child row carries a recognizable command line.
  defp agent_child(parent_id, child_id, command) do
    {:claude_chat_event,
     %{
       "type" => "assistant",
       "parent_tool_use_id" => parent_id,
       "message" => %{
         "content" => [
           %{
             "type" => "tool_use",
             "id" => child_id,
             "name" => "Bash",
             "input" => %{"command" => command}
           }
         ]
       }
     }}
  end

  # A tool_result frame attaching a subagent report to its spawn row.
  defp tool_result_frame(tool_use_id, content) do
    {:claude_chat_event,
     %{
       "type" => "user",
       "message" => %{
         "content" => [
           %{"type" => "tool_result", "tool_use_id" => tool_use_id, "content" => content}
         ]
       }
     }}
  end

  # A cumulative thinking-token frame (charter D41): the wire's monotonic
  # `estimated_tokens`, no thinking text ever.
  defp thinking_tokens(n) do
    %{"type" => "system", "subtype" => "thinking_tokens", "estimated_tokens" => n}
  end
end
