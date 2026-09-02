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

  import Barkpark.TenancyFixtures, only: [ensure_default_scope!: 0]

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.PlanPapers
  alias Barkpark.StudioChat.Recorder
  alias BarkparkWeb.Studio.ChatToolRenderer
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

  defmodule FakeCodexAdapter do
    @behaviour Barkpark.StudioChat.Runtime.Adapter

    def start(_opts), do: {:error, :not_started_by_identity_picker_tests}
    def resume(_opts), do: {:error, :not_started_by_identity_picker_tests}
    def send_turn(_runtime, _content), do: :ok
    def steer(_runtime, _command), do: :ok
    def interrupt(_runtime), do: {:ok, "interrupt-test"}
    def answer_approval(_runtime, _approval_id, _decision), do: :ok
    def close(_runtime), do: :ok
    def readiness(_opts), do: %{binary: true, authed?: true}
    def capabilities, do: %{modes: ["read-only"], models: ["gpt-5.6"], efforts: ["high"]}
    def normalize_mode(value), do: if(value == "read-only", do: value, else: "read-only")
    def normalize_model(value), do: if(value == "gpt-5.6", do: value)
    def normalize_effort(value), do: if(value == "high", do: value)
    def cwd, do: "/tmp/codex-managed"
  end

  setup %{conn: conn} do
    # Wave-26 leaked-session pollution guard (felix-w27, third victim — same
    # class the felix-w27-s6 slice guarded in studio_chat_test.exs and
    # chat_render_golden_test.exs): a Recorder that outlived a prior test's
    # sandbox owner can COMMIT chat_sessions rows that escape rollback and ride
    # list_sessions' recency-desc ordering ahead of seeded rows — reddening the
    # sidebar/empty-state assertions here on a shifting set. At setup no test
    # in this file has created a session yet, so every visible row is such a
    # leak; purge for a clean baseline. Restrict-FK children first; deleting
    # sessions cascades the delete_all children. Runs inside this test's
    # sandbox transaction and rolls back with it — test-infra hygiene only.
    Barkpark.Repo.query!("DELETE FROM chat_runtime_usage_receipts")
    Barkpark.Repo.query!("DELETE FROM epic_assignment_runtime_attempts")
    Barkpark.Repo.delete_all(Barkpark.StudioChat.Session)

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

  defp enable_fake_codex_adapter do
    previous = Application.get_env(:barkpark, :studio_chat_runtime_adapters)

    Application.put_env(
      :barkpark,
      :studio_chat_runtime_adapters,
      Map.put(previous || %{}, :codex, FakeCodexAdapter)
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :studio_chat_runtime_adapters, previous),
        else: Application.delete_env(:barkpark, :studio_chat_runtime_adapters)
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

    # Write-then-RENAME so read_marker/2 (which returns as soon as the file
    # exists) can never observe a half-written argv. The argv has grown past
    # one atomic pipe write (mcp flags + the system-prompt appendix), so a
    # bare `> marker` raced the reader into truncated reads (seen: argv cut
    # mid-appendix, --resume missing).
    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$@" > #{marker}.tmp && mv #{marker}.tmp #{marker}
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

  # Readiness-probe seam (chat-task-hands, decision 4): config/test.exs pins
  # {:static, :ready} suite-wide (the REAL probe shells out to the host's
  # `claude` — host-dependent and slow); card tests override per-test to drive
  # every named state through the same async start_async machinery.
  defp put_probe(value) do
    prev = Application.get_env(:barkpark, :studio_chat_readiness_probe)
    Application.put_env(:barkpark, :studio_chat_readiness_probe, value)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :studio_chat_readiness_probe, prev),
        else: Application.delete_env(:barkpark, :studio_chat_readiness_probe)
    end)
  end

  # bp-lane hands seam: what the spawn-time mint reported. Tests inject the
  # verdict; the default (absent) reads the spawn-env slice's session seam.
  defp put_hands_state(fun) when is_function(fun, 1) do
    Application.put_env(:barkpark, :studio_chat_hands_state, fun)
    on_exit(fn -> Application.delete_env(:barkpark, :studio_chat_hands_state) end)
  end

  @readiness_fixture Path.expand("../../../fixtures/claude_chat/unauthed_stream.ndjson", __DIR__)

  defp unauthed_frames do
    @readiness_fixture
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.reject(&(&1["type"] == "fixture_provenance"))
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

    # the herd column (charter D38/D40) — what the sidebar pill actually reads.
    # D80h: a blocked flip carries its :ask corroboration (a real pending ask
    # row); every other state is a :derived write through the same funnel.
    case opts[:agent_state] do
      nil ->
        :ok

      "blocked" ->
        {:ok, _} =
          StudioChat.append_message(id, %{
            role: "approval",
            metadata: %{
              "request_id" => "cl-#{System.unique_integer([:positive])}",
              "approval_status" => "pending"
            }
          })

        {1, _} = StudioChat.set_agent_state(id, "blocked", :ask)

      agent_state ->
        {1, _} = StudioChat.set_agent_state(id, agent_state, :derived)
    end

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

  describe "readiness onboarding card (chat never vanishes — chat-task-hands)" do
    setup %{conn: conn} do
      enable_fake_chat()
      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    # THE INVERSION (charter decision 4): a missing binary used to make this
    # exact mount redirect. Now the chat surface stays, and the card names the
    # state — reusing the spawn_error_text(:binary_not_found) copy, which was
    # dead code until this test.
    test ":no_binary mounts (no redirect), swaps the composer for the card", %{conn: conn} do
      Application.put_env(:barkpark, :claude_chat,
        enabled: true,
        command: {"definitely-not-a-real-binary-bp", []}
      )

      put_probe({:static, :no_binary})

      {:ok, view, _html} = live(conn, "/studio/chat")
      html = render_async(view)

      assert html =~ ~s(data-readiness="no_binary")
      assert html =~ "not installed on this host"
      assert html =~ "Install Claude Code and run"
      assert has_element?(view, "button[phx-click=readiness-recheck]")
      refute has_element?(view, "form[phx-submit=send]")
    end

    test ":not_logged_in names the exact next step (claude auth login)", %{conn: conn} do
      put_probe({:static, :not_logged_in})

      {:ok, view, _html} = live(conn, "/studio/chat")
      html = render_async(view)

      assert html =~ ~s(data-readiness="not_logged_in")
      assert html =~ "claude auth login"
      assert has_element?(view, "button[phx-click=readiness-recheck]")
      refute has_element?(view, "form[phx-submit=send]")
    end

    test ":checking shows the probe strip WITHOUT hiding the composer", %{conn: conn} do
      # A probe that never lands: the card stays :checking for the whole test.
      put_probe(fn -> Process.sleep(60_000) end)

      {:ok, view, html} = live(conn, "/studio/chat")

      assert html =~ ~s(data-readiness="checking")
      assert html =~ "checking Claude readiness"
      # The composer stays live — :checking must never be its own vanish.
      assert has_element?(view, "form[phx-submit=send]")
      refute has_element?(view, "button[phx-click=readiness-recheck]")
    end

    test "Re-check re-probes and unlocks the composer WITHOUT a reload", %{conn: conn} do
      {:ok, verdict} = Agent.start_link(fn -> :no_binary end)
      put_probe(fn -> Agent.get(verdict, & &1) end)

      {:ok, view, _html} = live(conn, "/studio/chat")
      html = render_async(view)

      assert html =~ ~s(data-readiness="no_binary")
      refute has_element?(view, "form[phx-submit=send]")

      # The host got fixed (binary installed + logged in) — Re-check sees it.
      Agent.update(verdict, fn _ -> :ready end)
      view |> element("button[phx-click=readiness-recheck]") |> render_click()
      html = render_async(view)

      # Same LiveView process, no reload: the composer is back, the card gone.
      assert has_element?(view, "form[phx-submit=send]")
      refute html =~ ~s(data-readiness="no_binary")
    end

    test "a spawn that dies on a missing binary flips the card beside the honest system line",
         %{conn: conn} do
      # Probe said ready (e.g. raced an uninstall), but the REAL spawn dies on
      # find_executable — the card must follow the spawn truth, not the stale
      # probe verdict.
      Application.put_env(:barkpark, :claude_chat,
        enabled: true,
        command: {"definitely-not-a-real-binary-bp", []}
      )

      {:ok, view, _html} = live(conn, "/studio/chat")
      render_async(view)

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      html = render(view)

      # The dead spawn_error_text(:binary_not_found) copy, live in the transcript…
      assert html =~ "not installed on this host"
      # …AND the card, locking the composer with the same next step.
      assert html =~ ~s(data-readiness="no_binary")
      refute has_element?(view, "form[phx-submit=send]")
    end

    test ":no_task_hands renders as a banner BESIDE a live composer", %{conn: conn} do
      put_hands_state(fn _session -> :refused end)

      {:ok, view, _html} = live(conn, "/studio/chat")
      render_async(view)

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      html = render(view)

      assert html =~ ~s(data-readiness="no_task_hands")
      assert html =~ "task tools are offline"
      # The chat itself still works — a bp-side problem never locks the composer.
      assert has_element?(view, "form[phx-submit=send]")
      assert has_element?(view, "button[phx-click=readiness-recheck]")
    end

    test ":task_token_expired renders as a banner BESIDE a live composer", %{conn: conn} do
      put_hands_state(fn _session -> :expired end)

      {:ok, view, _html} = live(conn, "/studio/chat")
      render_async(view)

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      html = render(view)

      assert html =~ ~s(data-readiness="task_token_expired")
      assert html =~ "task token has expired"
      assert has_element?(view, "form[phx-submit=send]")
    end

    # task-cth-bl-token-renewal. A renewal cannot re-arm a RUNNING child (its
    # environment was fixed at Port.open), so the card must say the one true
    # next step rather than report a success the shell lane did not get.
    test ":task_token_rearmed names the restart instead of claiming a live re-arm",
         %{conn: conn} do
      put_hands_state(fn _session -> :rearmed end)

      {:ok, view, _html} = live(conn, "/studio/chat")
      render_async(view)

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      html = render(view)

      assert html =~ ~s(data-readiness="task_token_rearmed")
      assert html =~ "Restart this session"
      # The chat itself keeps working — this is a bp-lane banner, not a lock.
      assert has_element?(view, "form[phx-submit=send]")
    end

    # The renewal happens on the SESSION's clock, mid-conversation, with nobody
    # watching. It must reach the card with no reload and no Re-check click.
    test "a renewal that lands mid-session flips the card in place — no reload",
         %{conn: conn} do
      put_hands_state(fn _session -> :ok end)

      {:ok, view, _html} = live(conn, "/studio/chat")
      render_async(view)
      refute render(view) =~ ~s(data-readiness="task_token_rearmed")

      # Exactly what the Recorder rebroadcasts when the Session renews.
      send(view.pid, {:claude_chat_task_hands, :rearmed})
      html = render(view)

      assert html =~ ~s(data-readiness="task_token_rearmed")
      assert html =~ "Restart this session"

      # …and a later expiry the renewal could not fix arrives the same way.
      send(view.pid, {:claude_chat_task_hands, :expired})
      assert render(view) =~ ~s(data-readiness="task_token_expired")
    end
  end

  describe "runtime auth guard (unauthed stream replay — chat-task-hands, decision 5)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_async(view)
      {:ok, view: view}
    end

    test "the captured unauthed stream flips the card to :not_logged_in, exactly once", %{
      view: view
    } do
      for frame <- unauthed_frames() do
        send(view.pid, {:claude_chat_event, frame})
      end

      html = render(view)

      # The card locked the composer with the login step…
      assert lv_assigns(view).readiness == :not_logged_in
      assert html =~ ~s(data-readiness="not_logged_in")
      assert html =~ "claude auth login"
      refute has_element?(view, "form[phx-submit=send]")

      # …the transcript got ONE honest line (assistant + result frames both
      # classify, but the flip is idempotent)…
      assert length(String.split(html, "turn ended unauthenticated")) == 2

      # …and the lying subtype:"success" was NOT classified a success: the
      # result took the auth branch, so no generic error line either.
      refute html =~ "The turn ended with an error"
    end

    test "the lying result frame ALONE flips the card — subtype:success is never trusted", %{
      view: view
    } do
      result = Enum.find(unauthed_frames(), &(&1["type"] == "result"))
      assert result["subtype"] == "success"

      send(view.pid, {:claude_chat_event, result})
      html = render(view)

      assert lv_assigns(view).readiness == :not_logged_in
      assert html =~ ~s(data-readiness="not_logged_in")
      refute has_element?(view, "form[phx-submit=send]")
    end

    test "an honest success result does NOT flip the card", %{view: view} do
      send(view.pid, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})
      html = render(view)

      assert lv_assigns(view).readiness == :ready
      refute html =~ ~s(data-readiness="not_logged_in")
      assert has_element?(view, "form[phx-submit=send]")
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
    # HOTFIX PIN (task-e277b8fcff7915f7). w1 disabled the composer until the CLI
    # emitted system/init — but init fires only when the FIRST TURN STARTS, and a
    # turn can only start from a send, and a send can only come from the composer.
    # A real browser therefore deadlocked; LiveViewTest did not, because
    # `render_submit` bypasses the `disabled` attribute entirely and spawned a
    # session straight through a `disabled=""` input. So the pin CANNOT be a send:
    # it has to be on the rendered composer, in the pre-init window.
    #
    # Both halves below are load-bearing, and the ORDER matters:
    #
    #   a) `assert has_element?` on the composer + submit button — WITHOUT this,
    #      the two `refute`s below pass vacuously the moment a future readiness
    #      gate hides the composer by ABSENCE (`:if={... and not is_nil(@init)}`)
    #      instead of by attribute. That variant deadlocks the tab identically
    #      and the pre-hardening version of this test stayed GREEN through it.
    #   b) `refute` on `[disabled]` — catches the literal w1 shape.
    #
    # And `init == nil` is asserted FIRST: it proves these assertions are made
    # inside the deadlock window. Without it the test could pass because init
    # arrived, never because the gate is gone.
    test "mount is a new-chat state with an enabled composer and no subprocess", %{view: view} do
      assert render(view) =~ ~s(data-chat-status="new")

      # The deadlock window: no init has arrived, and nothing exists that could
      # emit one. Anything gating the composer on @init is unlockable ONLY by a
      # send that the gate itself prevents.
      assert lv_assigns(view)[:init] == nil
      assert session_pid(view) == nil
      assert store_id(view) == nil

      # (a) the composer is actually RENDERED — a gate by absence is a deadlock too.
      assert has_element?(view, "input#chat-composer[name=message]")
      assert has_element?(view, ~s(button[type=submit][form=chat-composer-form]))

      # (b) …and it is not disabled.
      refute has_element?(view, "input[name=message][disabled]")
      refute has_element?(view, "button[type=submit][disabled]")
    end

    test "renders the composer and the chat tab in the top menu", %{html: html} do
      assert html =~ ~s(phx-submit="send")
      assert html =~ ~s(phx-hook="PaperMermaid")
      assert html =~ ~s(href="/studio/chat")
      assert html =~ "studio-tab active"
    end

    # Keyboard-first affordances are documented from the very first mount
    # (charter D42) — they live in the idle composer PLACEHOLDER, not a
    # standing footer row, so they vanish the moment the user types.
    test "the keyboard affordances render in the idle placeholder on fresh mount", %{
      html: html
    } do
      assert html =~ "/ for commands"
      assert html =~ "↵ to send"
      assert html =~ "esc to interrupt"
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

    # The codex turn_completed path (studio_chat_runtime_event) commits the
    # streamed answer to a durable :assistant message so it survives turn
    # completion (which always resets `streaming: nil`). The `streaming` assign
    # is a StreamTail BARE MAP (%{text: ...}) — the old `text when is_binary(text)`
    # clause never matched a map, so the just-streamed answer vanished from the
    # open transcript at turn completion. MUTATION-PROOF: reverting the clause to
    # `text when is_binary(text)` reds this — streaming resets to nil and the
    # sentinel disappears because it was never appended.
    test "turn_completed commits the streamed codex answer to a durable assistant message",
         %{view: view} do
      # populate the shared `streaming` StreamTail via the delta path
      send(view.pid, {:claude_chat_event, stream_delta("ZZ_STREAMED_ANSWER_ZZ")})
      assert render(view) =~ "ZZ_STREAMED_ANSWER_ZZ"

      # codex end-of-turn — after this, streaming is nil no matter what
      send(view.pid, {:studio_chat_runtime_event, codex_turn_completed()})

      assert lv_assigns(view)[:streaming] == nil
      # the streamed answer is still visible — now a durable :assistant message
      assert render(view) =~ "ZZ_STREAMED_ANSWER_ZZ"
    end

    # A stdout buffer overflow (claude_chat.ex D126) sends a NAMED reason before
    # the DOWN follows. Without a {:claude_chat_error, ...} clause it fell to the
    # catch-all no-op and the user saw only the generic DOWN banner, losing the
    # captured stderr tail. MUTATION-PROOF: removing the clause reds this — the
    # render no longer carries the overflow copy or the captured reason.
    test "a buffer_overflow error surfaces the captured reason, not the generic DOWN banner",
         %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})

      send(
        view.pid,
        {:claude_chat_error, :buffer_overflow, "codex: runaway stdout ZZ_OVERFLOW_TAIL_ZZ"}
      )

      html = render(view)
      assert html =~ "more data than this session can buffer"
      assert html =~ "ZZ_OVERFLOW_TAIL_ZZ"
      refute html =~ "ended unexpectedly"
    end

    # A codex runtime FAILURE event (protocol.ex :protocol_error / :error /
    # :process_failed) carries an `error` map with the reason. Before this clause
    # these kinds fell to the bare %Runtime.Event{} catch-all and rendered NOTHING
    # — a framing buffer overflow left the transcript silent. MUTATION-PROOF:
    # removing the codex-failure handle_info clause reds this — the render no
    # longer carries the failure copy or the captured reason.
    test "a codex :protocol_error surfaces its reason instead of rendering nothing",
         %{view: view} do
      send(
        view.pid,
        {:studio_chat_runtime_event, codex_protocol_error("ZZ_PROTOCOL_REASON_ZZ")}
      )

      html = render(view)
      assert html =~ "protocol error"
      assert html =~ "ZZ_PROTOCOL_REASON_ZZ"
    end

    # charter D41 — the wire carries no thinking text, so the pulse is a live
    # counter off `system/thinking_tokens` (cumulative `estimated_tokens`).
    test "thinking_tokens frames render a live ✻ pulse with the cumulative count",
         %{view: view} do
      send(view.pid, {:claude_chat_event, thinking_tokens(64)})
      send(view.pid, {:claude_chat_event, thinking_tokens(210)})
      html = render(view)
      assert spinner_word_shown?(html)
      # the cumulative high-water mark, not a per-frame count
      assert html =~ "~210 tokens"
    end

    test "the pulse settles into a durable 'thought for ~N tokens' line when prose begins",
         %{view: view} do
      send(view.pid, {:claude_chat_event, thinking_tokens(128)})
      assert spinner_word_shown?(render(view))

      # the first text delta is the moment thinking gives way to prose
      send(view.pid, {:claude_chat_event, stream_delta("Here")})
      html = render(view)
      refute spinner_word_shown?(html)
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
      refute spinner_word_shown?(html)
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

    # felix W22 (charter D131): the streaming display accumulator is bounded at a
    # config-overridable byte cap. A flood of many small WELL-FORMED deltas keeps
    # the transport buffer near-empty yet would grow this display assign (and
    # re-render the full prefix per delta) unboundedly. On breach the live bubble
    # freezes at the last stable block with an honest marker; the DURABLE full
    # text still lands untruncated on completion (this accumulator is
    # display-only for both providers).
    test "a flood of well-formed deltas caps the display but completion still yields the FULL text",
         %{view: view} do
      # shrink the cap far below the flood; merge into the live :claude_chat env
      # so `enabled`/`command` survive, and restore on exit.
      prev = Application.get_env(:barkpark, :claude_chat, [])

      Application.put_env(
        :barkpark,
        :claude_chat,
        Keyword.put(prev, :max_streaming_display_bytes, 4096)
      )

      on_exit(fn -> Application.put_env(:barkpark, :claude_chat, prev) end)

      # Well-formed prose with balanced-fence block boundaries — the buffer stays
      # complete-lines the whole time (the transport cap never trips), only THIS
      # sink grows. 400 × ~48B ≈ 19.2 KiB, ~4.7× the 4096 cap.
      chunk = "Lorem ipsum dolor sit amet, consectetur adipi.\n\n"

      for _ <- 1..400 do
        send(view.pid, {:claude_chat_event, stream_delta(chunk)})
      end

      html = render(view)
      streaming = lv_assigns(view)[:streaming]

      # RED-BEFORE (uncapped): streaming.text would grow to the full ~19.2 KiB
      # flood. GREEN (capped): it froze at the last stable boundary at/under the
      # cap plus at most one delta of slack.
      assert streaming.capped == true
      assert byte_size(streaming.text) <= 4096 + byte_size(chunk)
      # the honest marker stands in for the dropped forming tail
      assert html =~ "live preview truncated"
      assert html =~ "data-streaming-capped"
      # never a live cursor once frozen (the tail was dropped at a stable boundary)
      refute html =~ "▌"

      # …and the completion path is UNBOUNDED by the display cap: a full frame far
      # larger than the cap renders in full, sentinel and all.
      full = String.duplicate("full durable body paragraph. ", 1000) <> "ZZ_FULL_TAIL_SENTINEL_ZZ"

      send(
        view.pid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{"content" => [%{"type" => "text", "text" => full}]}
         }}
      )

      done = render(view)
      assert done =~ "ZZ_FULL_TAIL_SENTINEL_ZZ"
      # the streamed preview is superseded (no marker lingers post-completion)
      refute done =~ "live preview truncated"
    end

    # A capped state is terminal: every further delta is ignored, so neither the
    # accumulator nor the per-delta full-prefix re-render can keep growing.
    test "once capped, further deltas do not grow the frozen display", %{view: view} do
      prev = Application.get_env(:barkpark, :claude_chat, [])

      Application.put_env(
        :barkpark,
        :claude_chat,
        Keyword.put(prev, :max_streaming_display_bytes, 2048)
      )

      on_exit(fn -> Application.put_env(:barkpark, :claude_chat, prev) end)

      chunk = "The quick brown fox jumps over the lazy dog.\n\n"
      for _ <- 1..200, do: send(view.pid, {:claude_chat_event, stream_delta(chunk)})

      frozen = lv_assigns(view)[:streaming]
      assert frozen.capped == true
      frozen_size = byte_size(frozen.text)

      # 200 more deltas after the freeze must not budge the frozen text.
      for _ <- 1..200, do: send(view.pid, {:claude_chat_event, stream_delta(chunk)})
      after_more = lv_assigns(view)[:streaming]
      assert after_more.capped == true
      assert byte_size(after_more.text) == frozen_size
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
      assert html =~ ~s(data-chat-status="ready")
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
      # No init frame arrived → a nonzero exit reads as a doomed start (D54).
      send(view.pid, {:claude_chat_exit, 1, ""})
      html = render(view)
      assert html =~ ~s(data-chat-status="offline")
      assert html =~ "exit 1"
    end

    # ── honest dead spawns (charter D54) ──────────────────────────────────────

    test "a pre-init dead spawn surfaces the stderr reason and refuses a resume",
         %{view: view} do
      # A rejected argv exits nonzero BEFORE any system/init frame; a resume
      # would re-run the same command and re-die, so no resume invite.
      send(view.pid, {:claude_chat_exit, 1, "error: unknown option '--nope'"})
      html = render(view)

      assert html =~ ~s(data-chat-status="offline")
      assert html =~ "failed to start"
      assert html =~ "unknown option"
      refute html =~ "Send a message to resume it"
    end

    test "a death AFTER init keeps the resume invite and appends the reason",
         %{view: view} do
      send(
        view.pid,
        {:claude_chat_event, %{"type" => "system", "subtype" => "init", "model" => "m"}}
      )

      send(view.pid, {:claude_chat_exit, 1, "segfault at 0xdead"})
      html = render(view)

      assert html =~ "Send a message to resume it"
      assert html =~ "segfault at 0xdead"
      refute html =~ "failed to start"
    end

    test "a clean exit keeps the plain resume invite", %{view: view} do
      send(
        view.pid,
        {:claude_chat_event, %{"type" => "system", "subtype" => "init", "model" => "m"}}
      )

      send(view.pid, {:claude_chat_exit, 0, ""})
      html = render(view)

      assert html =~ "Send a message to resume it"
      refute html =~ "failed to start"
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

      html =
        render_change(view, "set-mode", %{"mode" => "acceptEdits"})

      # the mode change is recorded honestly with the friendly label…
      assert html =~ "Permission mode → accept edits"
      assert html =~ "accept edits"
      # …and the session is steered in place, never respawned or torn down —
      # the old context-destroying respawn path is gone (charter D12).
      refute html =~ "New session started"
      assert session_pid(view) == pid_before
      assert html =~ ~s(data-chat-status="ready")
    end

    test "mode change with no live session just updates the selector", %{view: view} do
      html =
        render_change(view, "set-mode", %{"mode" => "acceptEdits"})

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
        render_change(view, "set-mode", %{
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
      send(
        view.pid,
        {:claude_chat_event, %{"type" => "system", "subtype" => "init", "model" => "sonnet"}}
      )

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
      assert html =~ ~s(data-chat-status="ready")
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

      send(view.pid, {:claude_chat_exit, 1, ""})
      html = render(view)

      # POSITIVELY assert the cancellation, then refute the live buttons — a
      # dead Allow/Deny post-exit would be a button that lies.
      assert html =~ "✗ canceled"
      refute has_element?(view, ~s(button[phx-click=approve][phx-value-rid=req-crash]))
      refute has_element?(view, ~s(button[phx-click=deny][phx-value-rid=req-crash]))
      assert html =~ ~s(data-chat-status="offline")
    end

    # ── control acks: the UI never lies about a mode switch (scc-w2/w3, D17/D23) ──
    #
    # The ack is now correlated by request_id — the LV records the minted id in
    # `:pending_mode`, so a test reads it from assigns to forge a matching ack.

    defp pending_mode_req(view), do: lv_assigns(view)[:pending_mode][:req]

    test "a confirmed mode echo keeps the switch and posts no revert line", %{view: view} do
      spawn_silent_session(view)

      render_change(view, "set-mode", %{"mode" => "acceptEdits"})
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
        render_change(view, "set-mode", %{"mode" => "acceptEdits"})

      assert html =~ "accept edits"
      rid = pending_mode_req(view)

      # …but the CLI's ack carries an EMPTY response (the silent-no-op trap, D12):
      # we must NOT trust subtype:success, so the switch reverts to plan.
      send(view.pid, {:claude_chat_control, :set_mode, rid, %{}})
      html = render(view)
      assert html =~ "switch permission mode"
      assert has_element?(view, ".mode-tab-plan.active")
      # revert persists too: the store never keeps a mode the CLI refused.
      assert StudioChat.get_session(store_id(view)).mode == "plan"
    end

    test "a mismatched mode echo reverts to the prior mode", %{view: view} do
      spawn_silent_session(view)

      render_change(view, "set-mode", %{"mode" => "acceptEdits"})
      rid = pending_mode_req(view)
      # the CLI reports a DIFFERENT mode than we asked → the switch did not take
      send(view.pid, {:claude_chat_control, :set_mode, rid, %{"mode" => "plan"}})

      html = render(view)
      assert html =~ "switch permission mode"
      assert has_element?(view, ".mode-tab-plan.active")
    end

    test "a stale ack from a superseded rapid switch is ignored (no mis-revert)",
         %{view: view} do
      spawn_silent_session(view)

      # rapid double switch: acceptEdits (req A) then auto (req B) before any ack
      render_change(view, "set-mode", %{"mode" => "acceptEdits"})
      rid_a = pending_mode_req(view)
      render_change(view, "set-mode", %{"mode" => "auto"})
      rid_b = pending_mode_req(view)
      refute rid_a == rid_b

      # req A's ack lands LATE echoing acceptEdits. Value-matching (the wave-2 bug)
      # would see echo "acceptEdits" != current "auto" and MIS-REVERT. By
      # request_id it is stale (B superseded it) → ignored, mode stays auto.
      send(view.pid, {:claude_chat_control, :set_mode, rid_a, %{"mode" => "acceptEdits"}})
      html = render(view)
      assert has_element?(view, ".mode-tab-autopilot.active")
      refute html =~ "Couldn't switch permission mode"

      # req B's ack then confirms auto honestly.
      send(view.pid, {:claude_chat_control, :set_mode, rid_b, %{"mode" => "auto"}})
      html = render(view)
      assert has_element?(view, ".mode-tab-autopilot.active")
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

      assert render(view) =~ ~s(data-chat-status="ready")

      # let the (now stale) timer fire — it must NOT flip offline
      Process.sleep(180)
      html = render(view)
      refute html =~ ~s(data-chat-status="offline")
      assert html =~ ~s(data-chat-status="ready")
    end

    # ── extracted teardown is idempotent (scc-w2, D18) ────────────────────

    test "a close-then-DOWN double fire does not duplicate the offline system line",
         %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      pid = session_pid(view)

      # an initialized (running) session, then the process exits — resume is legit
      send(
        view.pid,
        {:claude_chat_event, %{"type" => "system", "subtype" => "init", "model" => "m"}}
      )

      send(view.pid, {:claude_chat_exit, 2, ""})
      # the DOWN that follows the process death — teardown already ran, so this
      # must find no matching session pid and no-op (never a second system line)
      send(view.pid, {:DOWN, make_ref(), :process, pid, :normal})

      html = render(view)
      count = html |> String.split("Send a message to resume it") |> length() |> Kernel.-(1)
      assert count == 1
      assert html =~ ~s(data-chat-status="offline")
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

      assert html =~ ~s(data-chat-status="offline")
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
      enable_fake_codex_adapter()
      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    test "provider and execution identity are selectable only before first send", %{conn: conn} do
      host_id = Ecto.UUID.generate()
      {:ok, view, _html} = live(conn, "/studio/chat")

      assert has_element?(view, ~s(form[phx-change=set-provider]))
      assert has_element?(view, ~s(form[phx-change=set-execution-target]))

      render_change(element(view, ~s(form[phx-change=set-provider])), %{"provider" => "codex"})

      render_change(element(view, ~s(form[phx-change=set-execution-target])), %{
        "execution_target" => "registered_host"
      })

      render_change(element(view, ~s(form[phx-change=set-execution-host])), %{
        "execution_host_id" => host_id
      })

      assert lv_assigns(view)[:provider] == "codex"
      assert lv_assigns(view)[:execution_target] == "registered_host"
      assert lv_assigns(view)[:execution_host_id] == host_id
      assert store_id(view) == nil
    end

    test "reopen restores immutable provider and execution identity without pickers", %{
      conn: conn
    } do
      sid = Ecto.UUID.generate()
      host_id = Ecto.UUID.generate()

      assert {:ok, _session} =
               StudioChat.create_session(%{
                 id: sid,
                 provider: "codex",
                 execution_target: "registered_host",
                 execution_host_id: host_id,
                 mode: "read-only"
               })

      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")

      assert lv_assigns(view)[:provider] == "codex"
      assert lv_assigns(view)[:execution_target] == "registered_host"
      assert lv_assigns(view)[:execution_host_id] == host_id
      refute has_element?(view, ~s(form[phx-change=set-provider]))
      refute has_element?(view, ~s(form[phx-change=set-execution-target]))
      refute has_element?(view, ~s(form[phx-change=set-execution-host]))
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
      _newer = seed_session("Newer chat", status: "working", agent_state: "working")

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

    test "cold pills read the persisted agent_state (herd wave 1): blocked → needs you, unknown → offline",
         %{conn: conn} do
      seed_session("Blocked chat", agent_state: "blocked")
      seed_session("Unknown chat", agent_state: "unknown")
      seed_session("Idle chat")

      {:ok, _view, html} = live(conn, "/studio/chat")

      # blocked wears the warn-toned needs-you pill straight off the column
      assert html =~ "badge-chat-approval"
      assert html =~ "needs you"
      # a mid-turn death (unknown) reads as offline
      assert html =~ "badge-chat-offline"
      assert html =~ "offline"
      # a plain resting session stays the idle pill
      assert html =~ "badge-chat-idle"
    end

    test "a {:chat_heartbeat} liveness tick is explicitly ignored (charter D41h)",
         %{conn: conn} do
      sid = seed_session("Quiet chat")
      {:ok, view, _html} = live(conn, "/studio/chat")

      send(view.pid, {:chat_heartbeat, sid, DateTime.utc_now()})

      assert render(view) =~ "Quiet chat"
      assert Process.alive?(view.pid)
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

      # First-send dispatch is deliberately deferred through handle_info; wait
      # for its public navigation signal before inspecting internal assigns.
      path = assert_patch(view, 1_000)
      sid = store_id(view)
      assert is_binary(sid)
      assert path == "/studio/chat/#{sid}"

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

      render_change(view, "set-mode", %{"mode" => "acceptEdits"})

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

    test "the Recorder's title event reaches the open tab through the real subscriptions",
         %{conn: conn} do
      # ct-bl-recorder-titles: no `send(view.pid, …)` here — the event goes out
      # on PubSub exactly as `Titles.kick_title` sends it, so this also proves
      # the tab is genuinely subscribed rather than merely handling the tuple.
      sid = seed_session("Original")
      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
      assert render(view) =~ "Original"

      # The sidebar renders the STORE, never the tuple's payload, so the row has
      # to move first — a rename is the cheapest way to move it.
      {:ok, _} = StudioChat.rename(sid, "Pushed by the Recorder")
      Recorder.broadcast_title(sid, "Pushed by the Recorder")

      await(fn -> render(view) =~ "Pushed by the Recorder" end)
      refute render(view) =~ "Original"
    end

    test "the SECOND delivery of one title is dropped, not re-read", %{conn: conn} do
      # An open tab subscribes to BOTH topics the Recorder publishes a title on,
      # so one accepted write arrives twice. The repeat must not re-read the
      # store: this test moves the row BEHIND the tab's back between the two
      # deliveries, so a second `refresh_sessions/1` would visibly repaint a
      # title nothing announced — the flicker criterion 3 forbids.
      sid = seed_session("Original")
      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")

      {:ok, _} = StudioChat.rename(sid, "Announced title")
      send(view.pid, {:chat_title, sid, "Announced title"})
      await(fn -> render(view) =~ "Announced title" end)

      {:ok, _} = StudioChat.rename(sid, "Never announced")
      send(view.pid, {:chat_title, sid, "Announced title"})
      render(view)

      assert render(view) =~ "Announced title"
      refute render(view) =~ "Never announced"
    end

    test "a title the tab has NOT rendered always refreshes (the guard only drops no-ops)",
         %{conn: conn} do
      # The inverse of the test above — proof the duplicate guard cannot swallow
      # a real update. Same shape, one difference: the announced title is the
      # NEW store value, so the refresh must happen.
      sid = seed_session("Original")
      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")

      {:ok, _} = StudioChat.rename(sid, "Announced title")
      send(view.pid, {:chat_title, sid, "Announced title"})
      await(fn -> render(view) =~ "Announced title" end)

      {:ok, _} = StudioChat.rename(sid, "A genuinely newer title")
      send(view.pid, {:chat_title, sid, "A genuinely newer title"})

      await(fn -> render(view) =~ "A genuinely newer title" end)
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

    test "the CLI's post-plan default flip is INERT in the LiveView (the Recorder owns that seam)",
         %{view: view} do
      spawn_silent_session(view)
      sid = store_id(view)
      assert StudioChat.get_session(sid).mode == "plan"

      # The CLI flipped plan → default inside ExitPlanMode (the real-binary-
      # proven value, charter D52). The LiveView no longer adopts it — the
      # Recorder observes the SAME init frame, engages Autopilot (steer +
      # persist), and broadcasts; adopting here too would double-persist and
      # race the steer.
      send(
        view.pid,
        {:claude_chat_event,
         %{"type" => "system", "subtype" => "init", "permissionMode" => "default"}}
      )

      html = render(view)
      assert lv_assigns(view).mode == "plan"
      assert StudioChat.get_session(sid).mode == "plan"
      refute html =~ "Permission mode is now"
    end

    test "the Recorder's adoption broadcast engages Autopilot in the toggle + narrates it",
         %{view: view} do
      spawn_silent_session(view)

      # The Recorder engaged Autopilot (an approved plan) — steer + persist
      # happened server-side; the LiveView renders only.
      send(view.pid, {:studio_chat_mode_adopted, "auto", :plan_approved})

      html = render(view)
      assert lv_assigns(view).mode == "auto"
      assert lv_assigns(view)[:pending_mode] == nil
      assert has_element?(view, ".mode-tab-autopilot.active")
      # NO SILENT ESCALATION (charter D52): the flip surfaces as a system line.
      assert html =~ "Plan approved — Autopilot engaged."
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
      render_change(view, "set-mode", %{"mode" => "bypassPermissions"})

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
      assert spinner_word_shown?(html)

      send(view.pid, :turn_tick)
      send(view.pid, :turn_tick)
      assert render(view) =~ "2s"
    end

    test "the busy row's word rotates on the turn clock (never sticks)", %{view: view} do
      before = shown_spinner_word(render(view))
      assert before

      # 7 ticks = one rotation window; next_spinner_word excludes the current
      # word, so the swap is guaranteed visible.
      for _ <- 1..7, do: send(view.pid, :turn_tick)
      after_rotation = shown_spinner_word(render(view))
      assert after_rotation
      assert after_rotation != before
    end

    test "the busy row's word wears the shimmer, stopping… stays plain", %{view: view} do
      assert render(view) =~ "bp-chat-spin-word"
    end

    test "the thinking pulse's word rotates on the turn clock too", %{view: view} do
      # a live pulse hides the busy row, so the shown word IS the pulse's
      send(view.pid, {:claude_chat_event, thinking_tokens(64)})
      before = shown_spinner_word(render(view))
      assert before

      for _ <- 1..7, do: send(view.pid, :turn_tick)
      after_rotation = shown_spinner_word(render(view))
      assert after_rotation
      assert after_rotation != before
    end
  end

  describe "hand-task surface (chat ⇄ ledger)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "go"})
      {:ok, view: view, sid: store_id(view), conn: conn}
    end

    test "a claim held by THIS session's worker raises the Doing strip", %{view: view, sid: sid} do
      worker = BarkparkWeb.Studio.ClaudeChat.worker_id(sid)

      send(
        view.pid,
        task_changed("task-hs-1", "Fix the gate latch", %{
          "lifecycle_status" => "in_progress",
          "claim" => %{"worker" => worker, "now" => "reading the brief"},
          "acceptance_criteria" => [%{"met" => true}, %{"met" => false}, %{"met" => false}]
        })
      )

      html = render(view)
      assert html =~ "data-role=\"chat-hand-task\""
      assert html =~ "Fix the gate latch"
      assert html =~ "1/3 ✓"
      assert html =~ "reading the brief"
      assert html =~ "task-hs-1"
    end

    test "another worker's claim never renders", %{view: view} do
      send(
        view.pid,
        task_changed("task-hs-2", "Someone else's yard", %{
          "lifecycle_status" => "in_progress",
          "claim" => %{"worker" => "claude-chat-deadbeef"}
        })
      )

      refute render(view) =~ "data-role=\"chat-hand-task\""
    end

    test "a close drops the strip row", %{view: view, sid: sid} do
      worker = BarkparkWeb.Studio.ClaudeChat.worker_id(sid)

      send(
        view.pid,
        task_changed("task-hs-3", "Dig the hole", %{
          "lifecycle_status" => "in_progress",
          "claim" => %{"worker" => worker}
        })
      )

      assert render(view) =~ "Dig the hole"

      send(
        view.pid,
        task_changed("task-hs-3", "Dig the hole", %{"lifecycle_status" => "done"})
      )

      refute render(view) =~ "data-role=\"chat-hand-task\""
    end

    test "a draft-twin echo never flaps the strip", %{view: view, sid: sid} do
      worker = BarkparkWeb.Studio.ClaudeChat.worker_id(sid)

      send(
        view.pid,
        task_changed("drafts.task-hs-4", "Draft twin", %{
          "lifecycle_status" => "in_progress",
          "claim" => %{"worker" => worker}
        })
      )

      refute render(view) =~ "data-role=\"chat-hand-task\""
    end

    test "the picker opens on the ready head and hands a task to Claude", %{view: view} do
      register_task_schema()

      # Tasks.ready is fail-closed on workspace scope — the fixture must live
      # in the same seeded Default scope the surface (and the agent's flat
      # /v1/tasks hands) read.
      ws = Barkpark.Tenancy.get_default_workspace()
      proj = Barkpark.Tenancy.get_default_project()

      {:ok, _} =
        Barkpark.Content.create_document(
          "task",
          %{
            "doc_id" => "task-hs-ready1",
            "title" => "Sweep the yard",
            "content" => %{"kind" => "task", "lifecycle_status" => "open", "priority" => 1}
          },
          "production",
          workspace_id: ws.id,
          project_id: proj.id
        )

      render_click(element(view, "button[phx-click=toggle-task-picker]"))
      html = render(view)
      assert html =~ "data-role=\"chat-task-picker\""
      assert html =~ "Sweep the yard"
      assert html =~ "Hand to Claude"

      render_click(element(view, "button[phx-value-id=task-hs-ready1]"))
      html = render(view)
      # picker closes; the claim-first work prompt rode the normal send path
      refute html =~ "data-role=\"chat-task-picker\""
      assert html =~ "Work Barkpark task task-hs-ready1"
      assert html =~ "bp task claim task-hs-ready1"
    end

    test "an empty ready queue shows the honest empty state", %{view: view} do
      render_click(element(view, "button[phx-click=toggle-task-picker]"))
      html = render(view)
      assert html =~ "data-role=\"chat-task-picker\""
      assert html =~ "Nothing ready"
    end

    test "/task <id> expands to the claim-first work prompt", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "/task task-abc123"})
      html = render(view)
      assert html =~ "Work Barkpark task task-abc123"
      assert html =~ "stamp each criterion"
    end

    test "/task new <wish> expands to the authoring prompt", %{view: view} do
      render_submit(
        element(view, "form[phx-submit=send]"),
        %{"message" => "/task new fix the fence latch"}
      )

      html = render(view)
      assert html =~ "Author and publish a Barkpark task"
      assert html =~ "fix the fence latch"
      assert html =~ "publish wall"
    end

    test "bare /task teaches usage without reaching the model", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "/task"})
      html = render(view)
      assert html =~ "Usage: /task &lt;task-id&gt;" or html =~ "Usage: /task <task-id>"
    end

    test "/task rides the slash-menu builtin floor", %{view: view} do
      assert render(view) =~ "/task"
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

  # ─────────────────────────────────────────────────────────────────────────
  # Settle-gated tool-row gutter (task-d5083ae525902f28). The transcript's tool
  # rows used to draw a CONSTANT ● with no completion semantics while the agents
  # rail already flipped ✓/✕ on settle. Two gates, each with its own test so a
  # mutation reds by NAME:
  #
  #   SETTLE gate     — a mid-turn tool_result does NOT flip the glyph; only the
  #                     turn's terminal `result` frame settles the row.
  #   PROVENANCE gate — after the settle, ✓ requires a result that actually
  #                     arrived; a resultless row stays neutral forever.
  #
  # The glyph is drawn from ChatToolRenderer.settle_state/1 over three ENVELOPE
  # facts (turn_settled / tool_error / output), which the Recorder persists and
  # `message_json` already ships — so the Go TUI's toolRowGlyph reads the same
  # truth and replay needs no re-derivation.
  # ─────────────────────────────────────────────────────────────────────────
  describe "settle-gated tool row gutter (task-d5083ae525902f28)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "go"})
      {:ok, view: view, sid: store_id(view), conn: conn}
    end

    defp settle_tool_use(sid, id, name, input) do
      send_frame(
        sid,
        {:claude_chat_event,
         %{
           "type" => "assistant",
           "message" => %{
             "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}]
           }
         }}
      )
    end

    defp settle_tool_result(sid, id, content, opts \\ []) do
      block =
        %{"type" => "tool_result", "tool_use_id" => id, "content" => content}
        |> then(fn b ->
          if Keyword.get(opts, :error, false), do: Map.put(b, "is_error", true), else: b
        end)

      send_frame(
        sid,
        {:claude_chat_event, %{"type" => "user", "message" => %{"content" => [block]}}}
      )
    end

    defp settle_turn(sid) do
      send_frame(sid, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})
    end

    test "the gutter is NEUTRAL while the turn runs — a mid-turn tool_result never flips it",
         %{view: view, sid: sid} do
      settle_tool_use(sid, "toolu_settle_1", "Bash", %{"command" => "ls -la"})

      html = render(view)
      assert html =~ ~s(data-tool-state="pending")
      refute html =~ ~s(data-tool-state="ok")

      # THE SETTLE GATE. The result for this tool has landed, but the TURN is
      # still running — a row that reads "done" while its turn can still fail is
      # a lie. Deleting the settle gate (flipping on tool_result alone) reds HERE.
      settle_tool_result(sid, "toolu_settle_1", "total 0")

      html = render(view)
      assert html =~ ~s(data-tool-state="pending")
      refute html =~ ~s(data-tool-state="ok")
      refute html =~ "✓"
    end

    test "the turn's result frame flips a resulted row to ✓", %{view: view, sid: sid} do
      settle_tool_use(sid, "toolu_settle_2", "Bash", %{"command" => "ls -la"})
      settle_tool_result(sid, "toolu_settle_2", "total 0")
      assert render(view) =~ ~s(data-tool-state="pending")

      settle_turn(sid)

      html = render(view)
      assert html =~ ~s(data-tool-state="ok")
      assert html =~ "✓"
      assert html =~ "var(--life-done)"
    end

    test "an is_error tool_result settles the row to ✗", %{view: view, sid: sid} do
      settle_tool_use(sid, "toolu_settle_3", "Bash", %{"command" => "false"})
      settle_tool_result(sid, "toolu_settle_3", "command failed", error: true)
      assert render(view) =~ ~s(data-tool-state="pending")

      settle_turn(sid)

      html = render(view)
      assert html =~ ~s(data-tool-state="error")
      assert html =~ "✗"
      refute html =~ ~s(data-tool-state="ok")
    end

    test "a settled row whose tool_result NEVER arrived stays neutral — never a fabricated ✓",
         %{view: view, sid: sid} do
      settle_tool_use(sid, "toolu_settle_4", "Bash", %{"command" => "sleep 9000"})

      # THE PROVENANCE GATE. The turn settles with no tool_result for this row
      # (the CLI died / the frame was dropped). Deleting the provenance gate
      # (✓ on settle alone) reds HERE.
      settle_turn(sid)

      html = render(view)
      assert html =~ ~s(data-tool-state="pending")
      refute html =~ ~s(data-tool-state="ok")
      refute html =~ "✓"
    end

    test "a reopened session replays ✓ and ✗ off the persisted envelope", %{conn: conn} do
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "tool",
          source_markdown: "Bash — REPLAYED_OK_ROW",
          metadata: %{
            "tool" => "Bash",
            "tool_use_id" => "replay-ok",
            "output" => "done",
            "turn_settled" => true
          }
        })

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "tool",
          source_markdown: "Bash — REPLAYED_ERR_ROW",
          metadata: %{
            "tool" => "Bash",
            "tool_use_id" => "replay-err",
            "output" => "boom",
            "tool_error" => true,
            "turn_settled" => true
          }
        })

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "tool",
          source_markdown: "Bash — REPLAYED_RESULTLESS_ROW",
          metadata: %{
            "tool" => "Bash",
            "tool_use_id" => "replay-none",
            "turn_settled" => true
          }
        })

      {:ok, _view, html} = live(conn, "/studio/chat/#{id}")

      assert html =~ "REPLAYED_OK_ROW"
      assert html =~ "REPLAYED_ERR_ROW"
      assert html =~ "REPLAYED_RESULTLESS_ROW"
      # a settled session renders its outcomes on reopen — the whole point of
      # persisting the settle rather than deriving it from a live-only turn.
      assert html =~ ~s(data-tool-state="ok")
      assert html =~ ~s(data-tool-state="error")
      # …and the resultless row is STILL neutral after replay.
      assert html =~ ~s(data-tool-state="pending")
      assert html =~ "✓"
      assert html =~ "✗"
    end

    test "the pure truth table is the ONE owner both surfaces read" do
      # The Go TUI's toolRowGlyph mirrors exactly these five rows.
      assert ChatToolRenderer.settle_state(%{turn_settled: false, output: "x"}) == :pending
      assert ChatToolRenderer.settle_state(%{turn_settled: true, output: "x"}) == :ok
      assert ChatToolRenderer.settle_state(%{turn_settled: true, output: nil}) == :pending
      assert ChatToolRenderer.settle_state(%{turn_settled: true, output: ""}) == :pending

      assert ChatToolRenderer.settle_state(%{turn_settled: true, output: "x", tool_error: true}) ==
               :error

      assert ChatToolRenderer.settle_glyph(%{turn_settled: false}) == "●"
      assert ChatToolRenderer.settle_glyph(%{turn_settled: true, output: "x"}) == "✓"
      assert ChatToolRenderer.settle_glyph(%{turn_settled: true, tool_error: true}) == "✗"
    end
  end

  # ─────────────────────────────────────────────────────────────────────────
  # MCP result chips (charter D64). Chip dispatch is a DELIBERATE narrow
  # exception to D38: it keys on OUR tool NAME (mcp__barkpark__ prefix) plus a
  # Jason.decode of the single text block. The classifier is consumed identically
  # by the live-append path (tool_use reducer + tool_result attach) and the
  # replay path (replay_message) — both thread `tool` + `output`, so the template
  # calling ChatToolRenderer.chip/2 renders parity-stable HTML.
  # ─────────────────────────────────────────────────────────────────────────
  describe "MCP result chip classifier (charter D64, pure)" do
    test "an mcp__barkpark__ task_create receipt classifies to a task chip with a board deep link" do
      chip = ChatToolRenderer.chip("mcp__barkpark__task_create", mcp_fixture("task_create.json"))

      assert %{kind: :task, href: "/admin/projects?task=task-9f81108b31d1d947"} = chip
      assert chip.label == "task-9f81108b31d1d947"
    end

    test "an mcp__barkpark__ task_show doc classifies to a task chip titled + board-linked" do
      chip = ChatToolRenderer.chip("mcp__barkpark__task_show", mcp_fixture("task_show.json"))

      assert %{kind: :task, href: "/admin/projects?task=task-d76fa14f63626556"} = chip
      assert chip.label =~ "native-chips"
    end

    test "an mcp__barkpark__ paper doc classifies to a paper chip with a reader link" do
      chip = ChatToolRenderer.chip("mcp__barkpark__doc_get", mcp_fixture("paper_get.json"))

      assert %{kind: :paper, href: "/papers/studio-chat-w12-wave-2026-07-10"} = chip
      assert chip.label == "Studio Chat — Wave 12 plan"
    end

    test "a task_ready list classifies to a search chip; each hit deep-links by its own type" do
      chip = ChatToolRenderer.chip("mcp__barkpark__task_ready", mcp_fixture("task_ready.json"))

      assert %{kind: :search, total: 3, overflow: 0} = chip
      assert length(chip.hits) == 3
      first = hd(chip.hits)
      assert first.label == "Wire the MCP loopback"
      assert first.type == "task"
      assert first.href == "/admin/projects?task=task-aaa"
    end

    test "an is_error result is a plain string — it fails the decode and yields NO chip (generic row)" do
      assert ChatToolRenderer.chip("mcp__barkpark__task_show", mcp_fixture("error.txt")) == nil
    end

    test "a {ok:false} outcome (empty-queue claim) is a real non-result — no chip" do
      assert ChatToolRenderer.chip("mcp__barkpark__task_next", mcp_fixture("no_ready.json")) ==
               nil
    end

    test "a HOST tool name never triggers a chip — D38 shape dispatch is untouched" do
      # Same JSON body, but the name lacks the mcp__barkpark__ prefix.
      assert ChatToolRenderer.chip("Bash", mcp_fixture("task_show.json")) == nil
      assert ChatToolRenderer.chip("Read", ~s({"ok":true,"doc":{"doc_id":"x"}})) == nil
    end

    test "a truncated / non-JSON payload degrades honestly to nil (generic row)" do
      # The recorder caps persisted output at 4k; a payload cut mid-object is
      # invalid JSON and must never render a half-chip.
      truncated = String.slice(mcp_fixture("task_ready.json"), 0, 60)
      assert ChatToolRenderer.chip("mcp__barkpark__task_ready", truncated) == nil
      assert ChatToolRenderer.chip("mcp__barkpark__task_ready", "not json at all") == nil
    end

    test "PAYLOAD LAW: a >100KB search result is SUMMARIZED, not dumped" do
      hits =
        for i <- 1..700 do
          %{
            "doc_id" => "task-#{i}",
            "title" => "Result number #{i} #{String.duplicate("x", 100)}",
            "type" => "task"
          }
        end

      payload = Jason.encode!(%{"ok" => true, "docs" => hits})
      assert byte_size(payload) > 100_000

      chip = ChatToolRenderer.chip("mcp__barkpark__task_ready", payload)

      assert %{kind: :search, total: 700} = chip
      # rendered hits capped; the rest honestly summarized
      assert length(chip.hits) == 8
      assert chip.overflow == 692
    end

    test "a task_prime payload classifies to a PRIME chip — counts plus a colored ready head" do
      chip = ChatToolRenderer.chip("mcp__barkpark__task_prime", mcp_fixture("task_prime.json"))

      assert %{kind: :prime, ready_total: 7, overflow: 2} = chip

      # counts render in board order, each carrying its lifecycle token
      assert Enum.map(chip.counts, & &1.state) ==
               ~w(open in_progress blocked done cancelled)

      assert Enum.map(chip.counts, & &1.count) == [12, 3, 1, 40, 2]

      assert Enum.find(chip.counts, &(&1.state == "in_progress")).color ==
               "var(--life-in_progress)"

      # the ready head is capped at 5, deep-linked, and lifecycle-colored
      assert length(chip.ready) == 5
      first = hd(chip.ready)
      assert first.label == "Render the prime queue chip"
      assert first.href == "/admin/projects?task=task-r1"
      # a BRIEF card omits lifecycle_status exactly when it is "open"
      assert first.state == "open"
      assert first.color == "var(--life-open)"

      ready_row = Enum.find(chip.ready, &(&1.label == "Fold the approval status"))
      assert ready_row.color == "var(--life-ready)"
    end

    test "an UNKNOWN lifecycle state reads dim-neutral — it never borrows a known color" do
      chip = ChatToolRenderer.chip("mcp__barkpark__task_prime", mcp_fixture("task_prime.json"))

      row = Enum.find(chip.ready, &(&1.label == "Retire the second diff engine"))
      assert row.state == "marinating"
      assert row.color == "var(--fg-dim)"

      # and the negative control: a state IN the vocabulary is NOT neutralized
      known = Enum.find(chip.ready, &(&1.label == "Wire the rail rev diff"))
      assert known.color == "var(--life-researching)"
    end

    test "a MALFORMED prime payload degrades to a neutral chip — never a crash, never invented state" do
      malformed =
        Jason.encode!(%{
          "ok" => true,
          "counts" => "not a map",
          "ready" => "not a list",
          "worker" => 7
        })

      chip = ChatToolRenderer.chip("mcp__barkpark__task_prime", malformed)

      assert %{kind: :prime, counts: [], ready: [], ready_total: 0, overflow: 0} = chip
    end

    test "a PARTIAL prime payload keeps every row it can read and drops only the unreadable ones" do
      partial =
        Jason.encode!(%{
          "ok" => true,
          "counts" => %{"open" => 2, "in_progress" => nil, "sludge" => "many"},
          "ready" => ["a bare string", %{"doc_id" => "task-x", "title" => "Readable"}, 42]
        })

      chip = ChatToolRenderer.chip("mcp__barkpark__task_prime", partial)

      # non-integer counts are dropped rather than rendered as garbage
      assert Enum.map(chip.counts, & &1.state) == ["open"]
      # only the map row with a label survives; the total stays HONEST
      assert Enum.map(chip.ready, & &1.label) == ["Readable"]
      assert chip.ready_total == 3
      assert chip.overflow == 2
    end

    test "the prime branch never steals a search payload — `counts` alone is not prime" do
      # a result LIST carrying a counts map (no `ready`) is still a search chip:
      # prime requires BOTH keys, so the existing branches are untouched.
      payload =
        Jason.encode!(%{
          "ok" => true,
          "counts" => %{"open" => 3},
          "docs" => [%{"doc_id" => "task-aaa", "title" => "Still a search", "type" => "task"}]
        })

      assert %{kind: :search, total: 1} =
               ChatToolRenderer.chip("mcp__barkpark__task_ready", payload)
    end
  end

  describe "MCP result chip render (charter D64)" do
    test "a task chip renders a board deep-link pill with tokens only" do
      html =
        render_component(&ChatToolRenderer.tool_chip/1,
          chip: %{kind: :task, label: "Ship the chip", href: "/admin/projects?task=task-abc"}
        )

      assert html =~ ~s(href="/admin/projects?task=task-abc")
      assert html =~ "Ship the chip"
      assert html =~ "var(--muted-surface)"
      # tokens only — no copied hex/hsl color literal
      refute html =~ ~r/#[0-9a-fA-F]{3,6}\b/
    end

    test "a paper chip renders a reader link" do
      html =
        render_component(&ChatToolRenderer.tool_chip/1,
          chip: %{kind: :paper, label: "Wave 12 plan", href: "/papers/w12"}
        )

      assert html =~ ~s(href="/papers/w12")
      assert html =~ "Wave 12 plan"
    end

    test "a search chip renders an expandable hit list with an honest overflow line" do
      html =
        render_component(&ChatToolRenderer.tool_chip/1,
          chip: %{
            kind: :search,
            total: 12,
            overflow: 2,
            hits: [
              %{label: "Alpha task", type: "task", href: "/admin/projects?task=task-1"},
              %{label: "A paper", type: "paper", href: "/papers/p1"},
              %{label: "Unlinked doc", type: "note", href: nil}
            ]
          }
        )

      assert html =~ "<details"
      assert html =~ "12 results"
      assert html =~ ~s(href="/admin/projects?task=task-1")
      assert html =~ ~s(href="/papers/p1")
      # a hit with no route is honest inline text, not a dead link
      assert html =~ "Unlinked doc"
      assert html =~ "+2 more"
    end

    test "a chip with no id renders the pill WITHOUT a link (honest, never a dead href)" do
      html =
        render_component(&ChatToolRenderer.tool_chip/1,
          chip: %{kind: :task, label: "no id", href: nil}
        )

      assert html =~ "no id"
      refute html =~ "href="
    end

    test "a prime chip renders the counts and a lifecycle-colored ready head, tokens only" do
      html =
        render_component(&ChatToolRenderer.tool_chip/1,
          chip: %{
            kind: :prime,
            ready_total: 7,
            overflow: 2,
            counts: [
              %{state: "open", count: 12, color: "var(--life-open)"},
              %{state: "in_progress", count: 3, color: "var(--life-in_progress)"}
            ],
            ready: [
              %{
                label: "Render the prime queue chip",
                state: "open",
                color: "var(--life-open)",
                href: "/admin/projects?task=task-r1"
              },
              %{
                label: "Unknown state row",
                state: "marinating",
                color: "var(--fg-dim)",
                href: nil
              }
            ]
          }
        )

      assert html =~ "7 ready"
      assert html =~ "open 12"
      assert html =~ "in_progress 3"
      assert html =~ "var(--life-in_progress)"
      assert html =~ ~s(href="/admin/projects?task=task-r1")
      # the unknown state draws the NEUTRAL token and no dead link
      assert html =~ "var(--fg-dim)"
      assert html =~ "Unknown state row"
      assert html =~ "+2 more"
      # tokens only — no copied hex/hsl color literal
      refute html =~ ~r/#[0-9a-fA-F]{3,6}\b/
    end

    test "an EMPTY prime chip still renders honestly — 0 ready, no rows, no overflow line" do
      html =
        render_component(&ChatToolRenderer.tool_chip/1,
          chip: %{kind: :prime, ready_total: 0, overflow: 0, counts: [], ready: []}
        )

      assert html =~ "0 ready"
      refute html =~ "more"
    end

    # ── tlv-s5: chips speak the lifecycle (TLV charter D12/D14) ───────────────

    test "a task chip carries the lifecycle glyph + hue from the payload's lifecycle_status" do
      chip =
        ChatToolRenderer.chip(
          "mcp__barkpark__task_get",
          ~s({"ok":true,"doc":{"doc_id":"task-c1","title":"Weighing the rewrite",) <>
            ~s("type":"task","lifecycle_status":"considering",) <>
            ~s("engagement":{"object":"research","holder":"cycle-42"}}})
        )

      assert chip.state == "considering"
      assert chip.object == "research"

      html = render_component(&ChatToolRenderer.tool_chip/1, chip: chip)

      # ◌ is the GENERATED manifest's considering glyph — the identical character
      # the board and the Go TUI paint (the chip folds TokensGen.lifecycle/0).
      assert html =~ ~s(data-life-state="considering")
      assert html =~ "◌"
      assert html =~ "var(--life-considering)"
      # the CONSIDERING object marker: what the task is being weighed FOR (D12)
      assert html =~ ~s(data-engagement-object="research")
      assert html =~ "research"
      # tokens only — no copied hex/hsl literal (studio-literal-check doctrine)
      refute html =~ ~r/#[0-9a-fA-F]{3,6}\b/
    end

    test "an UNKNOWN chip state draws the NEUTRAL token, never a known state's hue" do
      chip =
        ChatToolRenderer.chip(
          "mcp__barkpark__task_get",
          ~s({"ok":true,"doc":{"doc_id":"task-x","title":"From a newer server",) <>
            ~s("type":"task","lifecycle_status":"marinating"}})
        )

      html = render_component(&ChatToolRenderer.tool_chip/1, chip: chip)

      assert html =~ ~s(data-life-state="marinating")
      assert html =~ "var(--fg-dim)"
      # borrowing ANY --life-* hue would report a queue state that does not exist
      refute html =~ "var(--life-"
    end

    test "a payload with NO lifecycle_status draws no state mark at all" do
      chip =
        ChatToolRenderer.chip(
          "mcp__barkpark__task_create",
          ~s({"ok":true,"id":"task-n","title":"No state here"})
        )

      # NOT defaulted to "open": an entity payload that simply omits the field
      # tells us nothing, and inventing "open" would report claimable work.
      assert chip.state == nil
      assert chip.object == nil

      html = render_component(&ChatToolRenderer.tool_chip/1, chip: chip)

      refute html =~ "data-life-state"
      refute html =~ "data-engagement-object"
      assert html =~ "var(--primary)"
    end

    test "the engagement object marker is drawn ONLY for the thought states" do
      chip =
        ChatToolRenderer.chip(
          "mcp__barkpark__task_get",
          ~s({"ok":true,"doc":{"doc_id":"task-w","title":"Already building",) <>
            ~s("type":"task","lifecycle_status":"in_progress","engagement":{"object":"build"}}})
        )

      # a stale engagement left on a card that has MOVED ON is not a live
      # deliberation — drawing it would report thinking that already ended.
      assert chip.object == nil

      refute render_component(&ChatToolRenderer.tool_chip/1, chip: chip) =~
               "data-engagement-object"
    end

    test "search hits carry their own lifecycle mark, and an unknown one stays neutral" do
      chip =
        ChatToolRenderer.chip(
          "mcp__barkpark__task_ready",
          ~s({"ok":true,"docs":[) <>
            ~s({"doc_id":"task-a","title":"Ready one","type":"task","lifecycle_status":"ready"},) <>
            ~s({"doc_id":"task-b","title":"Thinking","type":"task","lifecycle_status":"researching"},) <>
            ~s({"doc_id":"task-c","title":"Newer server","type":"task","lifecycle_status":"marinating"}]})
        )

      html = render_component(&ChatToolRenderer.tool_chip/1, chip: chip)

      assert html =~ ~s(data-life-state="ready")
      assert html =~ ~s(data-life-state="researching")
      assert html =~ ~s(data-life-state="marinating")
      assert html =~ "var(--life-researching)"
      assert html =~ "var(--fg-dim)"
      assert html =~ "◎"
    end
  end

  describe "MCP chips in the live transcript (charter D64)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "go"})
      {:ok, view: view, sid: store_id(view), conn: conn}
    end

    test "a task_create result renders a chip and SUPPRESSES the raw JSON blob",
         %{view: view, sid: sid} do
      send_tool_use(sid, "mcp__barkpark__task_create", %{"title" => "Ship the chip"})
      send_frame(sid, tool_result_frame("toolu_x", mcp_fixture("task_create.json")))

      html = render(view)
      # the chip deep link is present
      assert html =~ "/admin/projects?task=task-9f81108b31d1d947"
      # the raw JSON dump is gone — the chip stands in for it (the draft id only
      # ever appears in the suppressed ⎿ output body)
      refute html =~ "drafts.task-9f81108b31d1d947"
    end

    test "a search result renders an expandable hit chip", %{view: view, sid: sid} do
      send_tool_use(sid, "mcp__barkpark__task_ready", %{})
      send_frame(sid, tool_result_frame("toolu_x", mcp_fixture("task_ready.json")))

      html = render(view)
      assert html =~ "3 results"
      assert html =~ "/admin/projects?task=task-aaa"
      assert html =~ "Ship native chips"
    end

    test "a task_prime result renders the queue chip in the live transcript",
         %{view: view, sid: sid} do
      send_tool_use(sid, "mcp__barkpark__task_prime", %{"worker" => "chat-w3"})
      send_frame(sid, tool_result_frame("toolu_x", mcp_fixture("task_prime.json")))

      html = render(view)
      assert html =~ "7 ready"
      assert html =~ "/admin/projects?task=task-r1"
      assert html =~ "Render the prime queue chip"
      assert html =~ "var(--life-in_progress)"
    end

    test "an is_error string keeps the generic ⎿ row, no chip", %{view: view, sid: sid} do
      send_tool_use(sid, "mcp__barkpark__task_show", %{"doc_id" => "task-nope"})
      send_frame(sid, tool_result_frame("toolu_x", "error: task task-nope not found"))

      html = render(view)
      assert html =~ "⎿"
      assert html =~ "not found"
      refute html =~ "/admin/projects?task="
    end
  end

  describe "MCP chip replay parity (charter D64)" do
    test "a reopened session renders the identical chip HTML the live tab drew",
         %{conn: conn} do
      output = mcp_fixture("task_show.json")

      # ── LIVE path: tool_use reducer appends the row, tool_result attaches output
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, live_view, _} = live(conn, "/studio/chat")
      render_submit(element(live_view, "form[phx-submit=send]"), %{"message" => "go"})
      sid = store_id(live_view)
      send_tool_use(sid, "mcp__barkpark__task_show", %{"doc_id" => "task-d76fa14f63626556"})
      send_frame(sid, tool_result_frame("toolu_x", output))
      live_chip = chip_fragment(render(live_view))

      # ── REPLAY path: a stored tool row carrying the SAME tool + output metadata
      id = Ecto.UUID.generate()
      {:ok, _} = StudioChat.create_session(%{id: id, cwd: "/tmp", mode: "plan"})

      {:ok, _} =
        StudioChat.append_message(id, %{
          role: "tool",
          source_markdown: "mcp__barkpark__task_show",
          metadata: %{
            "tool" => "mcp__barkpark__task_show",
            "tool_use_id" => "toolu_r",
            "output" => output
          }
        })

      {:ok, _replay_view, replay_html} = live(conn, "/studio/chat/#{id}")
      replay_chip = chip_fragment(replay_html)

      assert live_chip != ""
      assert replay_chip == live_chip
      assert replay_chip =~ "/admin/projects?task=task-d76fa14f63626556"
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

  describe "agents rail — the epic-cycle journey (charter D57–D61, wave 11)" do
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

    defp wf_phase(index, title),
      do: %{"type" => "workflow_phase", "index" => index, "title" => title}

    defp wf_agent(label, phase_index, phase_title, state, opts) do
      %{
        "type" => "workflow_agent",
        "label" => label,
        "phaseIndex" => phase_index,
        "phaseTitle" => phase_title,
        "state" => state,
        "model" => opts[:model],
        "tokens" => opts[:tokens],
        "error" => opts[:error]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end

    # Every assertion about the rail is scoped INSIDE data-role="agents-rail" —
    # the setup turn (and the transcript) can carry its own bp-chat-agent-run and
    # phase-like words, which must never satisfy a rail assertion.
    defp rail_html(view),
      do: view |> render() |> String.split(~s(data-role="agents-rail")) |> List.last()

    test "background_tasks_changed renders a live rail row below the composer",
         %{view: view, sid: sid} do
      send_frame(
        sid,
        bg_changed([
          %{"task_id" => "t", "task_type" => "local_workflow", "description" => "Build the rail"}
        ])
      )

      assert render(view) =~ ~s(data-role="agents-rail")
      html = rail_html(view)
      assert html =~ ~s(data-rail-task="t")
      assert html =~ ~s(data-rail-status="running")
      assert html =~ "Build the rail"
    end

    # Per-entry auto-dismiss (charter D47): each SETTLED entry ages out on its
    # OWN ~90s timer, independent of siblings. The three tests below pin the
    # contract the wholesale 5-min sweep could not honor — a single running
    # agent used to pin every completed sibling on screen forever.
    test "a settled entry auto-dismisses on its own while a running sibling stays put",
         %{view: view, sid: sid} do
      # Two agents launch, both running.
      send_frame(
        sid,
        bg_changed([
          %{"task_id" => "t1", "task_type" => "local_workflow", "description" => "first"},
          %{"task_id" => "t2", "task_type" => "local_workflow", "description" => "second"}
        ])
      )

      html = rail_html(view)
      assert html =~ ~s(data-rail-task="t1")
      assert html =~ ~s(data-rail-task="t2")

      # t1 vanishes from the snapshot ⇒ completed; t2 keeps running.
      send_frame(
        sid,
        bg_changed([
          %{"task_id" => "t2", "task_type" => "local_workflow", "description" => "second"}
        ])
      )

      rail = lv_assigns(view)[:rail]
      assert rail["t1"]["status"] == "completed"
      assert rail["t2"]["status"] == "running"

      # t1's per-entry prune fires (its armed signature still matches): t1 leaves
      # the on-screen rail, t2 — still running — is untouched.
      send(view.pid, {:rail_prune_entry, "t1", StudioChat.rail_entry_signature(rail["t1"])})

      html = rail_html(view)
      refute html =~ ~s(data-rail-task="t1")
      assert html =~ ~s(data-rail-task="t2")
      # Header count decremented; the rail region survives because t2 runs.
      assert map_size(lv_assigns(view)[:rail]) == 1
      assert render(view) =~ ~s(data-role="agents-rail")

      # Replay law (charter D47): the STORE still carries BOTH entries — the
      # prune only ended t1's screen residency, it never rewrote rail_snapshot.
      persisted = StudioChat.get_session(sid).rail_snapshot
      assert Map.has_key?(persisted, "t1")
      assert Map.has_key?(persisted, "t2")
    end

    test "a prune for a STILL-RUNNING entry is a guarded no-op", %{view: view, sid: sid} do
      send_frame(
        sid,
        bg_changed([
          %{"task_id" => "t1", "task_type" => "local_workflow", "description" => "runs"}
        ])
      )

      rail = lv_assigns(view)[:rail]
      assert rail["t1"]["status"] == "running"

      # Even with a signature matching the CURRENT running entry, the terminal
      # guard rejects the prune — a running agent is never dismissed.
      send(view.pid, {:rail_prune_entry, "t1", StudioChat.rail_entry_signature(rail["t1"])})

      assert rail_html(view) =~ ~s(data-rail-task="t1")
      assert lv_assigns(view)[:rail]["t1"]["status"] == "running"
    end

    test "a re-run resets the entry so a STALE prune cannot drop the freshly-running row",
         %{view: view, sid: sid} do
      # Launch + settle t1, capturing the signature its prune was armed against.
      send_frame(
        sid,
        bg_changed([
          %{"task_id" => "t1", "task_type" => "local_workflow", "description" => "job"}
        ])
      )

      send_frame(sid, bg_changed([]))
      settled = lv_assigns(view)[:rail]["t1"]
      assert settled["status"] == "completed"
      stale_sig = StudioChat.rail_entry_signature(settled)

      # BEFORE that 90s timer fires, the SAME task_id re-runs — a fresh bg
      # snapshot lists it again, flipping it back to "running".
      send_frame(
        sid,
        bg_changed([
          %{"task_id" => "t1", "task_type" => "local_workflow", "description" => "job"}
        ])
      )

      assert lv_assigns(view)[:rail]["t1"]["status"] == "running"

      # The stale prune (armed against the settled signature) now fires. It MUST
      # be a no-op: the entry is live again and its signature moved.
      send(view.pid, {:rail_prune_entry, "t1", stale_sig})

      assert rail_html(view) =~ ~s(data-rail-task="t1")
      assert lv_assigns(view)[:rail]["t1"]["status"] == "running"
    end

    test "a RUNNING cycle reads as a journey: aggregate header, settled phases, breathing active phase, dim futures",
         %{view: view, sid: sid} do
      send_frame(
        sid,
        bg_changed([
          %{"task_id" => "t", "task_type" => "local_workflow", "description" => "epic"}
        ])
      )

      send_frame(
        sid,
        wf_progress(
          "t",
          [
            wf_phase(1, "Strategize"),
            wf_phase(2, "Explore"),
            wf_phase(3, "Build"),
            wf_phase(4, "Review"),
            wf_agent("strategist", 1, "Strategize", "done", model: "fable", tokens: 9_600),
            wf_agent("explore:a", 2, "Explore", "done",
              model: "claude-opus-4-8[1m]",
              tokens: 42_100
            ),
            wf_agent("explore:b", 2, "Explore", "done",
              model: "claude-opus-4-8[1m]",
              tokens: 38_700
            ),
            wf_agent("build:journey-render", 3, "Build", "start",
              model: "claude-opus-4-8[1m]",
              tokens: 145_000
            ),
            wf_agent("build:aggregates", 3, "Build", "start",
              model: "claude-opus-4-8[1m]",
              tokens: 88_300
            )
          ],
          %{"total_tokens" => 323_700}
        )
      )

      html = rail_html(view)

      # (1) aggregate header — active phase m/n + running/done + tokens, all from
      # workflow_journey/1's summary, none invented
      assert html =~ "Build 3/4"
      assert html =~ "2 running"
      assert html =~ "3 done"
      # 323_700 → nearest-k "324k" (format_tokens rounds, never floors)
      assert html =~ "324k tok"

      # (2) settled phases collapse to one quiet line
      assert html =~ "Strategize"
      assert html =~ "1 agent"
      assert html =~ "Explore"
      assert html =~ "2 agents"
      # a settled phase does NOT spill its agent rows
      refute html =~ "explore:"

      # (3) the active phase breathes with its nested agents; pair labels render
      # two-part (kind dim + rest emphasized), NOT a raw "build:slug" node
      assert html =~ "bp-chat-agent-run"
      assert html =~ ">build:</span>"
      assert html =~ ">journey-render</span>"
      # (3b) wire model ids read as family names, never the raw id
      assert html =~ "Opus"
      refute html =~ "claude-opus-4-8"
      # (3c) tokens abbreviated
      assert html =~ "145k tok"

      # (4) a future phase renders dim by name, no agents
      assert html =~ ~s(data-rail-phase="future")
      assert html =~ "var(--life-open)"
    end

    test "a COMPLETED cycle collapses to one summary line; expand still works (D61)",
         %{view: view, sid: sid} do
      send_frame(
        sid,
        bg_changed([
          %{"task_id" => "t", "task_type" => "local_workflow", "description" => "epic"}
        ])
      )

      send_frame(
        sid,
        wf_progress(
          "t",
          [
            wf_phase(1, "Strategize"),
            wf_phase(2, "Build"),
            wf_phase(3, "Perfect"),
            wf_agent("strategist", 1, "Strategize", "done", tokens: 9_600),
            wf_agent("build:one", 2, "Build", "done", tokens: 51_900),
            wf_agent("build:two", 2, "Build", "done", tokens: 88_300)
          ],
          %{"total_tokens" => 149_800}
        )
      )

      # the workflow task vanishes from the bg snapshot ⇒ completed
      send_frame(sid, bg_changed([]))

      html = rail_html(view)
      assert html =~ ~s(data-rail-status="completed")
      # honest terminal collapse: "k of n phases · s skipped · A agents · T tok"
      assert html =~ "2 of 3 phases"
      assert html =~ "1 skipped"
      assert html =~ "3 agents"
      # default COLLAPSED — the phase detail is not spilled
      refute html =~ ~s(data-rail-phase=)
      assert html =~ "expand"

      # the explicit toggle still opens it
      render_click(element(view, ~s([phx-click="rail-toggle"][phx-value-id="t"])))
      opened = rail_html(view)
      assert opened =~ ~s(data-rail-phase="done")
      assert opened =~ ~s(data-rail-phase="skipped")
      assert opened =~ "Perfect"
      assert opened =~ "skipped"
    end

    test "the manual toggle wins BOTH ways, and survives a running→completed flip (D61)",
         %{view: view, sid: sid} do
      send_frame(
        sid,
        bg_changed([
          %{"task_id" => "t", "task_type" => "local_workflow", "description" => "epic"}
        ])
      )

      send_frame(
        sid,
        wf_progress(
          "t",
          [
            wf_phase(1, "Build"),
            wf_agent("build:x", 1, "Build", "start", tokens: 10)
          ],
          %{"total_tokens" => 10}
        )
      )

      # running defaults EXPANDED — detail visible
      assert rail_html(view) =~ ~s(data-rail-phase="active")
      # user collapses: the override beats the running default-expanded
      render_click(element(view, ~s([phx-click="rail-toggle"][phx-value-id="t"])))
      refute rail_html(view) =~ ~s(data-rail-phase=)

      # the running→completed flip must NOT reopen it — the manual override persists
      send_frame(sid, bg_changed([]))
      assert rail_html(view) =~ ~s(data-rail-status="completed")
      refute rail_html(view) =~ ~s(data-rail-phase=)
    end

    test "a COMPLETED cycle's default-collapsed can be manually expanded (override wins the other way, D61)",
         %{conn: conn} do
      {:ok, s} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})

      {:ok, _} =
        StudioChat.set_rail_snapshot(s.id, %{
          "t" => %{
            "row" => %{"task_type" => "local_workflow", "description" => "done epic"},
            "status" => "completed",
            "seq" => 1,
            "workflow" => [
              wf_phase(1, "Strategize"),
              wf_agent("strategist", 1, "Strategize", "done", tokens: 9_600)
            ]
          }
        })

      {:ok, view, _html} = live(conn, "/studio/chat/#{s.id}")
      # completed defaults COLLAPSED
      refute rail_html(view) =~ ~s(data-rail-phase=)
      # user expands — the override wins over the completed default-collapsed
      render_click(element(view, ~s([phx-click="rail-toggle"][phx-value-id="t"])))
      assert rail_html(view) =~ ~s(data-rail-phase="done")
      assert rail_html(view) =~ "Strategize"
    end

    # ── tlv-s5: the rail's fall-through is neutral (TLV charter D14) ──────────

    test "a rail status OUTSIDE the workflow vocabulary is neutral, never a bright live run",
         %{conn: conn} do
      {:ok, s} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})

      # A rail_snapshot REPLAYS verbatim on reopen (charter D57), so a status a
      # different build wrote reaches the renderer untouched. The default used to
      # be --life-in_progress: an unrecognised value rendered as a live run —
      # the worst direction for a wrong guess, since it claims work is in flight.
      {:ok, _} =
        StudioChat.set_rail_snapshot(s.id, %{
          "t" => %{
            "row" => %{"task_type" => "local_workflow", "description" => "queued epic"},
            "status" => "queued",
            "seq" => 1
          }
        })

      {:ok, view, _html} = live(conn, "/studio/chat/#{s.id}")
      html = rail_html(view)

      assert html =~ ~s(data-rail-status="queued")
      assert html =~ "var(--fg-dim)"
      refute html =~ "var(--life-in_progress)"
    end

    test "the three REAL workflow statuses keep their exact hues after the default flip",
         %{conn: conn} do
      for {status, token} <- [
            {"running", "var(--life-in_progress)"},
            {"completed", "var(--life-done)"},
            {"interrupted", "var(--life-blocked)"}
          ] do
        {:ok, s} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})

        {:ok, _} =
          StudioChat.set_rail_snapshot(s.id, %{
            "t" => %{
              "row" => %{"task_type" => "local_workflow", "description" => "an epic"},
              "status" => status,
              "seq" => 1
            }
          })

        {:ok, view, _html} = live(conn, "/studio/chat/#{s.id}")

        assert rail_html(view) =~ token,
               "the #{status} rail row lost its hue to the default flip"
      end
    end

    test "an INTERRUPTED cycle shows exactly the frontier phase, with agents visible but NOT breathing (D58)",
         %{conn: conn} do
      {:ok, s} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})

      {:ok, _} =
        StudioChat.set_rail_snapshot(s.id, %{
          "t" => %{
            "row" => %{"task_type" => "local_workflow", "description" => "killed epic"},
            "status" => "interrupted",
            "seq" => 1,
            "workflow" => [
              wf_phase(1, "Strategize"),
              wf_phase(2, "Explore"),
              wf_phase(3, "Decide"),
              wf_agent("strategist", 1, "Strategize", "done",
                model: "claude-fable-1[1m]",
                tokens: 9_600
              ),
              wf_agent("explore:wire", 2, "Explore", "progress",
                model: "claude-opus-4-8[1m]",
                tokens: 21_400
              ),
              wf_agent("explore:grammar", 2, "Explore", "progress",
                model: "claude-fable-1[1m]",
                tokens: 14_700
              )
            ]
          }
        })

      {:ok, view, _html} = live(conn, "/studio/chat/#{s.id}")
      html = rail_html(view)

      assert html =~ ~s(data-rail-status="interrupted")
      # the frontier is named honestly — "died in Explore"
      assert html =~ "interrupted in Explore (2/3)"
      assert html =~ ~s(data-rail-phase="interrupted")
      assert html =~ "var(--life-blocked)"

      # the frontier's agents are visible (mixed model families read as names)
      assert html =~ "Opus"
      assert html =~ "Fable"
      assert html =~ ">explore:</span>"

      # phases past the frontier are unreached; Strategize settled to done
      assert html =~ ~s(data-rail-phase="unreached")
      assert html =~ ~s(data-rail-phase="done")

      # a DEAD entry never breathes — no fake spinners (mandate law)
      refute html =~ "bp-chat-agent-run"
    end

    test "a failed agent renders ✕ with its error string, and the header counts it (D58)",
         %{view: view, sid: sid} do
      send_frame(
        sid,
        bg_changed([
          %{"task_id" => "t", "task_type" => "local_workflow", "description" => "epic"}
        ])
      )

      send_frame(
        sid,
        wf_progress(
          "t",
          [
            wf_phase(1, "Build"),
            wf_agent("build:doomed", 1, "Build", "error",
              error: "context deadline exceeded",
              tokens: 12
            ),
            wf_agent("build:live", 1, "Build", "start", tokens: 8)
          ],
          %{"total_tokens" => 20}
        )
      )

      html = rail_html(view)
      # the header carries the honest failed count
      assert html =~ "1 running"
      assert html =~ "1 failed"
      # the failed agent shows ✕ and surfaces its error in a title=
      assert html =~ "✕"
      assert html =~ ~s(title="context deadline exceeded")
      assert html =~ "var(--danger)"

      # a failure NEVER vanishes on completion: the collapsed summary line and
      # the settled phase line both keep the honest failed count
      send_frame(
        sid,
        wf_progress(
          "t",
          [
            wf_phase(1, "Build"),
            wf_agent("build:doomed", 1, "Build", "error",
              error: "context deadline exceeded",
              tokens: 12
            ),
            wf_agent("build:live", 1, "Build", "done", tokens: 8)
          ],
          %{"total_tokens" => 20}
        )
      )

      send_frame(sid, bg_changed([]))

      collapsed = rail_html(view)
      assert collapsed =~ ~s(data-rail-status="completed")
      assert collapsed =~ "1 failed"

      render_click(element(view, ~s([phx-click="rail-toggle"][phx-value-id="t"])))
      expanded = rail_html(view)
      assert expanded =~ ~s(data-rail-phase="done")
      assert expanded =~ "1 failed"
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
          [wf_agent("a", 1, "P", "start", tokens: 10)],
          %{"total_tokens" => 10}
        )
      )

      sig1 = lv_assigns(view)[:rail_sig]

      # identical structure, only tokens advanced ⇒ value-equality no-op
      send_frame(
        sid,
        wf_progress(
          "t",
          [wf_agent("a", 1, "P", "start", tokens: 9_999)],
          %{"total_tokens" => 9_999}
        )
      )

      assert lv_assigns(view)[:rail_sig] == sig1

      # a state flip is structural ⇒ the signature (and render) changes
      send_frame(
        sid,
        wf_progress(
          "t",
          [wf_agent("a", 1, "P", "done", tokens: 9_999)],
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

      # "a" is gone from the wire but its row survives as done
      assert rail_html(view) =~ ~s(data-rail-task="a")
      assert lv_assigns(view)[:rail]["a"]["status"] == "completed"
    end

    # ── fed off S1's committed real-run fixtures (charter D62) ───────────────
    # These fold the FULL interleaved bg+progress stream exactly as the Recorder
    # does, then cross-check the render against workflow_journey/1's own summary —
    # robust to the exact fixture bytes S1 ships (any real epic-cycle capture).
    @fixtures_dir Path.expand("../../../fixtures/claude_chat", __DIR__)

    defp load_epic(name) do
      @fixtures_dir
      |> Path.join(name)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
    end

    defp fold_epic(frames) do
      Enum.reduce(frames, %{}, fn f, rail ->
        case f["subtype"] do
          "background_tasks_changed" -> StudioChat.rail_apply_background(rail, f)
          "task_progress" -> StudioChat.rail_capture_progress(rail, f)
          _ -> rail
        end
      end)
    end

    test "epic_cycle_progress.ndjson folds to a multi-phase journey rendered from the SAME pure folds",
         %{conn: conn} do
      rail = fold_epic(load_epic("epic_cycle_progress.ndjson"))
      assert map_size(rail) == 1
      [{tid, entry}] = Map.to_list(rail)

      journey = StudioChat.workflow_journey(Map.put(entry, "task_id", tid))
      s = journey.summary
      # a real epic cycle is multi-phase, many-agent
      assert s.phase_total > 1
      assert s.agents_total > 1

      {:ok, sess} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})
      {:ok, _} = StudioChat.set_rail_snapshot(sess.id, rail)
      {:ok, view, _html} = live(conn, "/studio/chat/#{sess.id}")

      # a completed cycle defaults collapsed — open it so the journey shows
      unless rail_html(view) =~ "data-rail-phase" do
        render_click(element(view, ~s([phx-click="rail-toggle"][phx-value-id="#{tid}"])))
      end

      html = rail_html(view)
      # the token aggregate the SAME pure fold produced is on the entry header
      assert html =~ "#{StudioChat.format_tokens(s.tokens)} tok"
      # a settled/active phase's real title renders in the journey
      shown = Enum.find(journey.phases, &(&1.status in [:done, :active]))
      assert shown
      assert html =~ shown.title
    end

    test "epic_cycle_interrupted.ndjson folds to a frontier journey; the dead entry never breathes",
         %{conn: conn} do
      rail = fold_epic(load_epic("epic_cycle_interrupted.ndjson"))
      assert map_size(rail) == 1
      [{tid, entry}] = Map.to_list(rail)
      # the capture has NO terminal frames — the session-teardown interrupt flip
      # supplies "interrupted" exactly as production does (mirrors
      # interrupt_running_tasks/1); we stamp it here
      rail = Map.put(rail, tid, Map.put(entry, "status", "interrupted"))

      journey = StudioChat.workflow_journey(Map.put(Map.get(rail, tid), "task_id", tid))
      %{index: fi, title: ft} = journey.summary.active

      {:ok, sess} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})
      {:ok, _} = StudioChat.set_rail_snapshot(sess.id, rail)
      {:ok, view, _html} = live(conn, "/studio/chat/#{sess.id}")

      html = rail_html(view)
      assert html =~ ~s(data-rail-status="interrupted")
      assert html =~ "interrupted in #{ft} (#{fi}/#{journey.summary.phase_total})"
      assert html =~ ~s(data-rail-phase="interrupted")
      refute html =~ "bp-chat-agent-run"
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
      assert has_element?(view, ~s(select[name="model"] option[value="default"][selected]))
      html = render(view)
      assert html =~ "Haiku"
      assert html =~ "Opus"
      assert html =~ "Fable"
    end

    test "picking a model persists the choice and confirms honestly", %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hello"})
      sid = store_id(view)

      html = render_change(element(view, ~s(form[phx-change=set-model])), %{"model" => "opus"})

      assert html =~ "Model → Opus."
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
      assert has_element?(view, ~s(select[name="model"]))
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

    test "the picker renders every tier beside the model select", %{view: view} do
      assert has_element?(view, ~s(select[name="effort"] option[value="default"][selected]))
      # every allowlisted tier is offered
      html = render(view)
      for e <- ~w(low medium high xhigh max), do: assert(html =~ ~s(value="#{e}"))
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

      html =
        render_change(element(view, ~s(form[phx-change=set-effort])), %{"effort" => "ludicrous"})

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

      render_change(view, "set-mode", %{"mode" => "bypassPermissions"})

      assert has_element?(view, ~s(button[phx-click=arm-bypass]))
    end

    test "the Arm button is disabled until the exact word is typed", %{view: view} do
      render_change(view, "set-mode", %{"mode" => "bypassPermissions"})

      assert has_element?(view, ~s(button[phx-click=arm-bypass][disabled]))

      render_change(element(view, ~s(form[phx-change=bypass-confirm])), %{"confirm" => "bypass"})
      refute has_element?(view, ~s(button[phx-click=arm-bypass][disabled]))
    end

    test "arming persists bypass and posts the honest, non-live line (no set_mode steer)",
         %{view: view} do
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})
      send(view.pid, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})
      sid = store_id(view)

      render_change(view, "set-mode", %{"mode" => "bypassPermissions"})

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
      render_change(view, "set-mode", %{"mode" => "bypassPermissions"})

      assert has_element?(view, ~s(button[phx-click=arm-bypass]))

      render_click(element(view, ~s(button[phx-click=cancel-arm-bypass])))
      refute has_element?(view, ~s(button[phx-click=arm-bypass]))
      assert lv_assigns(view)[:mode] == "plan"
    end

    # Enter in the confirm input must ARM (phx-submit), never fall through to a
    # native form submit that navigates the LiveView away — and the submit path
    # rides the SAME server-side exact-word guard as the button.
    test "Enter in the confirm input arms via phx-submit, word-guarded", %{view: view} do
      render_change(view, "set-mode", %{"mode" => "bypassPermissions"})

      # wrong word: submit never arms, panel stays open for another try
      render_change(element(view, ~s(form[phx-change=bypass-confirm])), %{"confirm" => "nope"})
      render_submit(element(view, ~s(form[phx-submit=arm-bypass])), %{"confirm" => "nope"})
      assert lv_assigns(view)[:mode] == "plan"
      assert has_element?(view, ~s(button[phx-click=arm-bypass]))

      # exact word: Enter arms without touching the button
      render_change(element(view, ~s(form[phx-change=bypass-confirm])), %{"confirm" => "bypass"})

      html =
        render_submit(element(view, ~s(form[phx-submit=arm-bypass])), %{"confirm" => "bypass"})

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
      render_change(view, "set-mode", %{"mode" => "bypassPermissions"})

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
      render_change(view, "set-mode", %{"mode" => "bypassPermissions"})

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

      render_change(view, "set-mode", %{"mode" => "bypassPermissions"})

      render_change(element(view, ~s(form[phx-change=bypass-confirm])), %{"confirm" => "yes"})
      # the button is disabled client-side; a FORGED event by name still hits the
      # server guard, which refuses to arm on the wrong word (defense in depth).
      render_click(view, "arm-bypass", %{})
      assert lv_assigns(view)[:mode] == "plan"

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "still safe"})
      argv = read_marker(marker)
      refute argv =~ "--allow-dangerously-skip-permissions"
    end

    # ── bypass arming is a LIVE act — reopen DISARMS (charter D55) ────────────

    # A remembered bypassPermissions session must NOT silently re-arm on reopen:
    # the persisted mode is the record of a PAST arming, not a standing licence.
    # The live token drops to false on reopen, so the next --resume spawns
    # fail-closed (plan, no danger flag) until the ceremony re-runs.
    test "a reopened bypass session spawns fail-closed (plan, no danger flag) until re-armed",
         %{conn: conn, marker: marker} do
      sid = seed_session_with_history()
      {:ok, _} = StudioChat.set_mode(sid, "bypassPermissions")
      # store-level derivation still reads armed — the FAIL-CLOSED gate is the
      # ChatLive live token, not this row fact (D55).
      assert StudioChat.bypass_armed?(sid)

      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
      # reopen did not spawn — the resume happens lazily on this send
      assert session_pid(view) == nil
      # the selector still shows the persisted mode, but the live token is off
      assert lv_assigns(view)[:mode] == "bypassPermissions"
      refute lv_assigns(view)[:bypass_live_armed]

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "resume disarmed"})

      argv = read_marker(marker)
      assert argv =~ "--resume"
      assert argv =~ "--permission-mode"
      assert argv =~ "plan"
      refute argv =~ "--allow-dangerously-skip-permissions"
    end

    # Re-running the type-"bypass" ceremony after a reopen flips the live token
    # back on, so the very next resume is armed again — full reopen→ceremony→spawn.
    test "reopen → re-run the ceremony → the resume spawns armed again",
         %{conn: conn, marker: marker} do
      sid = seed_session_with_history()
      {:ok, _} = StudioChat.set_mode(sid, "bypassPermissions")

      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
      refute lv_assigns(view)[:bypass_live_armed]

      # re-run the ceremony this lifetime
      render_change(element(view, ~s(form[phx-change=bypass-confirm])), %{"confirm" => "bypass"})
      render_click(element(view, ~s(button[phx-click=arm-bypass])))
      assert lv_assigns(view)[:bypass_live_armed]
      assert lv_assigns(view)[:mode] == "bypassPermissions"

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "armed again"})

      argv = read_marker(marker)
      assert argv =~ "--resume"
      assert argv =~ "bypassPermissions"
      assert argv =~ "--allow-dangerously-skip-permissions"
    end
  end

  # ── reopening a bypass session is honest about being disarmed (charter D55) ─
  describe "reopen disarms bypass with an honest auto-opened panel (D55)" do
    setup %{conn: conn} do
      enable_fake_chat()
      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    test "reopening a bypass session auto-opens the arm panel with the honest disarmed line",
         %{conn: conn} do
      sid = seed_session("Dangerous chat")
      {:ok, _} = StudioChat.set_mode(sid, "bypassPermissions")

      {:ok, view, html} = live(conn, "/studio/chat/#{sid}")

      # the arm panel is auto-open (arming_bypass) and honestly disarmed…
      assert lv_assigns(view)[:arming_bypass]
      assert lv_assigns(view)[:bypass_disarmed]
      assert has_element?(view, ~s(button[phx-click=arm-bypass]))
      assert html =~ "Bypass disarmed — re-arm to enable"
      # …the selector keeps showing the persisted mode (nothing was un-persisted)
      assert lv_assigns(view)[:mode] == "bypassPermissions"
      assert StudioChat.get_session(sid).mode == "bypassPermissions"
    end

    test "cancelling the auto-opened panel closes it and drops the disarmed line",
         %{conn: conn} do
      sid = seed_session("Dangerous chat")
      {:ok, _} = StudioChat.set_mode(sid, "bypassPermissions")

      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
      assert lv_assigns(view)[:bypass_disarmed]

      render_click(element(view, ~s(button[phx-click=cancel-arm-bypass])))
      refute lv_assigns(view)[:arming_bypass]
      refute lv_assigns(view)[:bypass_disarmed]
    end

    test "reopening a NON-bypass session leaves the panel closed",
         %{conn: conn} do
      sid = seed_session("Safe chat")

      {:ok, view, html} = live(conn, "/studio/chat/#{sid}")
      refute lv_assigns(view)[:arming_bypass]
      refute lv_assigns(view)[:bypass_disarmed]
      refute html =~ "Bypass disarmed"
    end

    test "a reopen while the runtime is still LIVE never shows the false disarmed banner",
         %{conn: conn} do
      # tab A spawns the live runtime for this session
      {:ok, view_a, _html} = live(conn, "/studio/chat")
      render_submit(element(view_a, "form[phx-submit=send]"), %{"message" => "act"})
      sid = store_id(view_a)
      assert is_pid(session_pid(view_a))
      {:ok, _} = StudioChat.set_mode(sid, "bypassPermissions")

      # tab B reopens the SAME session — the runtime is LIVE (adopted, D22) and
      # runs under ITS spawn-time arming; "disarmed — re-arm to enable" would be
      # a false banner here, and re-arming only ever applies at the next spawn.
      {:ok, view_b, html} = live(conn, "/studio/chat/#{sid}")
      refute lv_assigns(view_b)[:arming_bypass]
      refute lv_assigns(view_b)[:bypass_disarmed]
      refute html =~ "Bypass disarmed"
      # the live token still starts false in this tab (D55): once that runtime
      # dies, the next respawn fail-closes to plan exactly as a cold reopen does.
      refute lv_assigns(view_b)[:bypass_live_armed]
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

      # Warm the session to a LIVE runtime FIRST (the row still exists, so the
      # lazy resume-spawn succeeds), then settle the turn back to :ready. This is
      # load-bearing: since the chat_sessions fail-closed store seal (c8d952a6c),
      # a resume-spawn of a VANISHED session fail-closes at spawn ("Failed to
      # start…") — so deleting the row BEFORE the first send would trip the spawn
      # guard, not the persist guard this test is about. We must dispatch through
      # a genuinely live runtime, then delete the row underneath it.
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "warm up"})
      send(view.pid, {:claude_chat_event, %{"type" => "result", "subtype" => "success"}})
      _ = render(view)

      # NOW delete the row so the next post-dispatch append hits the terminal
      # {:error} of do_append (a vanished-session FK) AFTER the live runtime has
      # already taken the turn. A true concurrent seq-conflict cannot be forced
      # on one sandbox connection; this exercises the SAME exhaustion branch of
      # persist_user_message with a deterministic {:error}.
      Barkpark.Repo.delete!(StudioChat.get_session(sid))

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "resend me"})
      _ = render(view)

      # The model DID get the turn (the live runtime dispatched it), so the echo
      # STAYS…
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
      # The control-builtin floor (charter D48 retired /default; the toggle
      # added /autopilot, and /bypass is the arm ceremony's entry point).
      assert html =~ "/plan"
      assert html =~ "/autopilot"
      assert html =~ "/bypass"
      assert html =~ "/model"
    end

    test "a /autopilot submit engages auto through the mode rail", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")
      assert lv_assigns(view)[:mode] == "plan"

      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "/autopilot"})

      assert lv_assigns(view)[:mode] == "auto"
      assert has_element?(view, ".mode-tab-autopilot.active")
    end

    test "a /bypass submit opens the arm ceremony and changes NO mode (D48)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/studio/chat")

      html = render_submit(element(view, "form[phx-submit=send]"), %{"message" => "/bypass"})

      assert lv_assigns(view)[:arming_bypass] == true
      assert has_element?(view, ~s(button[phx-click=arm-bypass]))
      # nothing armed, nothing announced — the typed confirm word is the gate
      assert lv_assigns(view)[:mode] == "plan"
      refute html =~ "Permission mode → bypass"
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
          %{
            "content" => "write the matrix",
            "status" => "in_progress",
            "activeForm" => "Writing"
          },
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
      html =
        render_submit(element(view, "form[phx-submit=send]"), %{"message" => "queued prompt"})

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

    first =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".bp-paper-surface.bp-chat-md > :first-child")

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

  # A codex end-of-turn runtime event (the studio_chat_runtime_event path). The
  # terminal_state drives the closing line; `:completed` yields no extra line, so
  # the durable-append assertion is the only thing under test.
  defp codex_turn_completed do
    %Barkpark.StudioChat.Runtime.Event{kind: :turn_completed, terminal_state: :completed}
  end

  defp codex_protocol_error(detail) do
    %Barkpark.StudioChat.Runtime.Event{
      kind: :protocol_error,
      error: %{"code" => "buffer_overflow", "detail" => detail}
    }
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

  # An MCP tool-result body committed by scc-w12-mcp-probe (S3). Until S3 lands
  # in this branch these live under api/test/support/fixtures/studio_chat/mcp/;
  # the lead reconciles them with S3's canonical fixtures on integration.
  @mcp_fixtures Path.expand("../../../support/fixtures/studio_chat/mcp", __DIR__)
  defp mcp_fixture(name) do
    @mcp_fixtures |> Path.join(name) |> File.read!() |> String.trim_trailing("\n")
  end

  # Pull JUST the chip's deep-link anchor out of a full transcript render so the
  # parity assertion compares the chip fragment, not the message-wrapper chrome
  # (ids differ between a live socket and a replayed one). The `?task=` guard
  # skips any unrelated nav link to the board.
  defp chip_fragment(html) do
    case Regex.run(~r{<a href="/admin/projects\?task=.*?</a>}s, html) do
      [frag] -> frag
      _ -> ""
    end
  end

  # A cumulative thinking-token frame (charter D41): the wire's monotonic
  # `estimated_tokens`, no thinking text ever.
  defp thinking_tokens(n) do
    %{"type" => "system", "subtype" => "thinking_tokens", "estimated_tokens" => n}
  end

  # A task-document broadcast as the Doing strip sees it — the lean mirror of
  # Content.Broadcast.broadcast_document_mutation/3's :document_changed shape.
  defp task_changed(doc_id, title, content) do
    {:document_changed,
     %{
       type: "task",
       doc_id: doc_id,
       doc: %{
         doc_id: doc_id,
         title: title,
         status: "published",
         content: content,
         updated_at: nil
       }
     }}
  end

  # Register the tasks plugin's schema definitions under the flat default scope
  # so Content.create_document("task", …) validates (tasks_test idiom, flattened).
  defp register_task_schema do
    for schema_def <- Barkpark.Tasks.schema_definitions("production") do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      Barkpark.Content.upsert_schema(attrs, "production", [])
    end
  end

  # ── wave-session-card: the sidebar's two conditional lines (wsc D8-D11) ────
  # A session driving an epic cycle earns (a) phase ticks + phase word +
  # settled/total counter and (b) an epic-goal line — and ONLY such a session:
  # every plain row renders byte-identically to before (D11). Live truth is the
  # {:chat_workflow} overlay (D4); cold truth is workflow_summary over the
  # select-widened rail_snapshot at refresh_sessions (D7).

  # A live 2-phase rail: Explore settled, Build 1 done + 1 running (2/3 settled
  # counting the explorer, D2's done+failed law exercised via unit tests).
  defp live_workflow_rail do
    %{
      "wf" => %{
        "status" => "running",
        "seq" => 1,
        "row" => %{"task_type" => "local_workflow", "description" => "wave 1"},
        "workflow" => [
          %{"type" => "workflow_phase", "index" => 1, "title" => "Explore"},
          %{"type" => "workflow_phase", "index" => 2, "title" => "Build"},
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 1,
            "label" => "explore",
            "state" => "done",
            "startedAt" => 100,
            "tokens" => 10
          },
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 2,
            "label" => "build:a",
            "state" => "done",
            "startedAt" => 200,
            "tokens" => 5
          },
          %{
            "type" => "workflow_agent",
            "phaseIndex" => 2,
            "label" => "build:b",
            "state" => "progress",
            "startedAt" => 300
          }
        ]
      }
    }
  end

  # epic_goal reads the published documents table directly — lean ledger rows,
  # no claim machinery (the READ fold is under test, not the write path).
  defp insert_ledger_task!(doc_id, title, content) do
    Barkpark.Repo.insert!(%Barkpark.Content.Document{
      doc_id: doc_id,
      type: "task",
      title: title,
      status: "published",
      content: content,
      rev: Ecto.UUID.generate()
    })
  end

  defp seed_epic_ledger!(worker) do
    insert_ledger_task!("task-wsc-epic", "Wave Session Card", %{
      "lifecycle_status" => "in_progress",
      "wave_status" => "wave: building 5 slices"
    })

    insert_ledger_task!("task-wsc-held", "Slice s3", %{
      "lifecycle_status" => "in_progress",
      "parent_id" => "task-wsc-epic",
      "claim" => %{"worker" => worker, "now" => "gating"}
    })

    insert_ledger_task!("task-wsc-s1", "Slice s1", %{
      "lifecycle_status" => "done",
      "parent_id" => "task-wsc-epic"
    })

    insert_ledger_task!("task-wsc-s2", "Slice s2", %{
      "lifecycle_status" => "open",
      "parent_id" => "task-wsc-epic"
    })

    :ok
  end

  describe "wave session card — sidebar two lines (wsc charter D8-D11)" do
    setup %{conn: conn} do
      enable_fake_chat()
      {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token})}
    end

    test "COLD: a completed rail renders every tick settled + complete · n/n — no Recorder alive",
         %{conn: conn} do
      rail = fold_epic(load_epic("epic_cycle_progress.ndjson"))
      summary = StudioChat.workflow_summary(rail)
      assert summary.outcome == :completed

      {:ok, sess} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})
      {:ok, _} = StudioChat.set_rail_snapshot(sess.id, rail)

      {:ok, view, _html} = live(conn, "/studio/chat")

      card = view |> element(~s([data-test-id="chat-workflow-#{sess.id}"])) |> render()
      assert card =~ "complete · #{summary.agents_done}/#{summary.agents_total}"
      # one tick per phase, all settled — a completed cycle never breathes
      assert length(String.split(card, "border-radius: 50%")) - 1 == summary.phases_total
      assert length(String.split(card, "var(--life-done)")) - 1 == summary.phases_total
      refute card =~ "bp-chat-live-dot"
    end

    test "LIVE: a {:chat_workflow} ping overlays ticks + phase word + counter; the active tick breathes",
         %{conn: conn} do
      {:ok, sess} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})
      {:ok, view, _html} = live(conn, "/studio/chat")

      refute has_element?(view, ~s([data-test-id="chat-workflow-#{sess.id}"]))

      summary = StudioChat.workflow_summary(live_workflow_rail())
      send(view.pid, {:chat_workflow, sess.id, summary})

      card = view |> element(~s([data-test-id="chat-workflow-#{sess.id}"])) |> render()
      assert card =~ "Build · 2/3 agents"
      # done tick evergreen, active tick breathing on the EXISTING pulse class
      assert card =~ "var(--life-done)"
      assert card =~ "bp-chat-live-dot"
      assert card =~ "var(--life-in_progress)"
      # the future-phase outline is the dim border token — none here (2 phases,
      # frontier is the last), so pin the tick count instead
      assert length(String.split(card, "border-radius: 50%")) - 1 == summary.phases_total
    end

    test "INTERRUPTED: a dead rail renders its frontier honestly and never breathes", %{
      conn: conn
    } do
      rail =
        "epic_cycle_interrupted.ndjson"
        |> load_epic()
        |> fold_epic()
        |> Map.new(fn
          {tid, %{"status" => "running"} = e} -> {tid, Map.put(e, "status", "interrupted")}
          other -> other
        end)

      summary = StudioChat.workflow_summary(rail)
      assert summary.outcome == :interrupted

      {:ok, sess} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})
      {:ok, _} = StudioChat.set_rail_snapshot(sess.id, rail)

      {:ok, view, _html} = live(conn, "/studio/chat")

      card = view |> element(~s([data-test-id="chat-workflow-#{sess.id}"])) |> render()

      assert card =~
               "interrupted in #{summary.phase} · #{summary.agents_done}/#{summary.agents_total}"

      # the dead frontier wears the blocked token and NEVER the pulse class
      assert card =~ "var(--life-blocked)"
      refute card =~ "bp-chat-live-dot"
    end

    test "MINIMALISM (D11): a non-workflow row renders byte-identical with vs without rail data",
         %{conn: conn} do
      # pin the row's only clock read far in the past so both mounts read the
      # same age label
      {:ok, sess} = StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"})
      two_days_ago = DateTime.add(DateTime.utc_now(), -2 * 86_400, :second)

      StudioChat.get_session(sess.id)
      |> Ecto.Changeset.change(last_active_at: two_days_ago)
      |> Barkpark.Repo.update!()

      {:ok, view, _html} = live(conn, "/studio/chat")
      plain_row = view |> element(~s([data-test-id="chat-session-row"])) |> render()

      # a rail WITHOUT workflow nodes (a plain background shell task) must not
      # move a byte of the row
      {:ok, _} =
        StudioChat.set_rail_snapshot(sess.id, %{
          "bg" => %{
            "status" => "running",
            "seq" => 1,
            "row" => %{"task_type" => "local_shell", "description" => "npm test"}
          }
        })

      {:ok, view2, _html} = live(conn, "/studio/chat")
      with_rail_row = view2 |> element(~s([data-test-id="chat-session-row"])) |> render()

      assert plain_row == with_rail_row
      refute plain_row =~ "chat-workflow-"
      refute plain_row =~ "chat-epic-"
    end

    test "EPIC (D9): the epic-goal line folds title · slices · wave_status off the ledger", %{
      conn: conn
    } do
      sid = Ecto.UUID.generate()
      worker = BarkparkWeb.Studio.ClaudeChat.worker_id(sid)
      {:ok, _sess} = StudioChat.create_session(%{id: sid, mode: "plan"})
      {:ok, _} = StudioChat.set_rail_snapshot(sid, live_workflow_rail())
      seed_epic_ledger!(worker)

      {:ok, view, _html} = live(conn, "/studio/chat")

      line = view |> element(~s([data-test-id="chat-epic-#{sid}"])) |> render()
      assert line =~ "Wave Session Card"
      assert line =~ "1/3 slices"
      assert line =~ "wave: building 5 slices"
      # "PRs open" was DROPPED (D8) — no data source exists; never invented
      refute render(view) =~ "PRs open"
    end

    test "SIBLING (D9): the epic parent's heartbeat re-reads the line; the claim.worker fold is untouched",
         %{conn: conn} do
      sid = Ecto.UUID.generate()
      worker = BarkparkWeb.Studio.ClaudeChat.worker_id(sid)
      {:ok, _sess} = StudioChat.create_session(%{id: sid, mode: "plan"})
      {:ok, _} = StudioChat.set_rail_snapshot(sid, live_workflow_rail())
      seed_epic_ledger!(worker)

      # open the session so the Doing strip / hand-task fold is live for it
      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
      assert render(view) =~ "wave: building 5 slices"

      # the EXISTING claim.worker clause raises the strip (untouched behavior)
      send(
        view.pid,
        task_changed("task-wsc-held", "Slice s3", %{
          "lifecycle_status" => "in_progress",
          "parent_id" => "task-wsc-epic",
          "claim" => %{"worker" => worker, "now" => "gating"},
          "acceptance_criteria" => [%{"met" => true}]
        })
      )

      assert render(view) =~ "data-role=\"chat-hand-task\""

      # the epic heartbeat moves on the ledger…
      Barkpark.Repo.get_by!(Barkpark.Content.Document, doc_id: "task-wsc-epic", type: "task")
      |> Ecto.Changeset.change(
        content: %{
          "lifecycle_status" => "in_progress",
          "wave_status" => "wave: complete — debrief"
        }
      )
      |> Barkpark.Repo.update!()

      # …and the SIBLING step (doc_id == a held task's parent_id) re-reads it
      # off the same dataset stream — zero new PubSub topics
      send(
        view.pid,
        task_changed("task-wsc-epic", "Wave Session Card", %{
          "lifecycle_status" => "in_progress",
          "wave_status" => "wave: complete — debrief"
        })
      )

      html = render(view)
      assert html =~ "wave: complete — debrief"
      refute html =~ "wave: building 5 slices"
      # the strip row survived — the claim.worker clause is untouched
      assert html =~ "data-role=\"chat-hand-task\""
    end
  end

  # Connectors epic wave 1 (charter D17/D18): the admin chat LiveView is the
  # `:global` superuser path — the tenant seam added to the store MUST NOT change
  # what the admin sidebar sees. It surfaces sessions of EVERY owner (a
  # workspace-owned one and a NULL-owner/global one alike), exactly as today.
  describe "tenant seam — admin sidebar is the :global superuser (charter D17/D18)" do
    setup %{conn: conn} do
      enable_fake_chat()
      conn = init_test_session(conn, %{"api_token" => @admin_token})
      {:ok, conn: conn}
    end

    test "the admin sidebar lists sessions of every owner (workspace + global)", %{conn: conn} do
      ws_a = Ecto.UUID.generate()

      {:ok, tenant} =
        StudioChat.create_session(
          %{id: Ecto.UUID.generate(), cwd: "/tmp/x"},
          {:workspace, ws_a}
        )

      {:ok, global} =
        StudioChat.create_session(%{id: Ecto.UUID.generate(), cwd: "/tmp/y"}, :global)

      assert tenant.owner_workspace_id == ws_a
      assert is_nil(global.owner_workspace_id)

      {:ok, view, _html} = live(conn, "/studio/chat")
      html = render(view)

      # Both owners' sessions render in the sidebar — the admin path is unfiltered.
      assert html =~ "/studio/chat/#{tenant.id}"
      assert html =~ "/studio/chat/#{global.id}"
      assert has_element?(view, ~s([data-test-id="chat-session-row"]))
    end

    # Herd charter D43h: `BlockedSweeper` is fail-closed on NULL owners, so a
    # `nil`-owned session can never fire `chat_blocked`. The Studio create path
    # used to stamp `:global` (NULL) for managed sessions — this pins the fix:
    # the first send creates a store row OWNED by the resolved workspace
    # (Default Workspace fallback on the unscoped admin route).
    test "the first send stamps the created session's owner_workspace_id (D43h)", %{conn: conn} do
      {default_ws, _project} = ensure_default_scope!()

      {:ok, view, _html} = live(conn, "/studio/chat")
      render_submit(element(view, "form[phx-submit=send]"), %{"message" => "hi"})

      sid = store_id(view)
      assert sid, "the first send must create the store session row"

      owner = StudioChat.get_session(sid).owner_workspace_id

      assert owner == default_ws.id,
             "a Studio-created managed session must carry a non-NULL owner " <>
               "(got #{inspect(owner)}) — a NULL owner is invisible to BlockedSweeper forever"
    end
  end

  # The busy/pulse rows wear a random park word (the chat's spinner
  # personality) — assert against the canonical list, never a pinned word.
  defp spinner_word_shown?(html) do
    Enum.any?(BarkparkWeb.Studio.ChatLive.spinner_words(), &(html =~ &1 <> "…"))
  end

  # WHICH park word is currently showing (nil if none) — for asserting the
  # tick rotation actually swaps it.
  defp shown_spinner_word(html) do
    Enum.find(BarkparkWeb.Studio.ChatLive.spinner_words(), &(html =~ &1 <> "…"))
  end
end
