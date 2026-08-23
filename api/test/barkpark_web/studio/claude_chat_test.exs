defmodule BarkparkWeb.Studio.ClaudeChatTest do
  @moduledoc """
  Gate + subprocess behavior of the Studio Claude chat seam. No real `claude`
  anywhere: the command is overridden with `cat` (echo server — a written
  NDJSON user message rides straight back through the real Port + parse
  path) and tiny `sh -c` scripts (canned init events, exit statuses).
  """
  use ExUnit.Case, async: false

  alias BarkparkWeb.Studio.ClaudeChat

  # A stub bridge for the TOOL-connector seam (connectors D69/D73). It plays the
  # `fetch_tool_descriptors/1` role WITHOUT a running Node process, and — the
  # non-vacuous part — it DECODES the ticket and only answers a descriptor when
  # the runner signed a real TOOL-SESSION ticket (provider `tool-session`) for
  # the expected workspace. So a config file that ends up with the `github`
  # server PROVES `setup_mcp` minted the right ticket for the right workspace,
  # not that a canned value was stuffed in.
  defmodule ToolBridgeStub do
    @behaviour Barkpark.Connectors.Bridge

    @impl true
    def validate(_ticket, _credential), do: {:error, :unreachable}
    @impl true
    def connect(_ticket, _credential, _chat_token), do: {:error, :unreachable}
    @impl true
    def disconnect(_ticket, _install_key), do: {:error, :unreachable}
    @impl true
    def stage_pending(_ticket, _chat_token), do: {:error, :unreachable}

    @impl true
    def fetch_tool_descriptors(ticket) do
      with [body, _sig] <- String.split(ticket, ".", parts: 2),
           {:ok, json} <- Base.url_decode64(body, padding: false),
           {:ok, %{"p" => "tool-session", "w" => ws}} <- Jason.decode(json),
           ^ws <- Application.get_env(:barkpark, :tool_stub_ws) do
        {:ok,
         [
           %{
             "provider" => "github",
             "type" => "http",
             "url" => "https://api.githubcopilot.com/mcp/",
             "headersHelper" =>
               "curl -sS -X POST -d '{\"ticket\":\"#{ticket}\"}' " <>
                 "http://127.0.0.1:4020/connectors/connect/tool-headers/github"
           }
         ]}
      else
        _ -> {:ok, []}
      end
    end
  end

  # Set `config :barkpark, Barkpark.Connectors, …`, restoring on exit. The tool
  # seam reads `connect_secret` (to sign the ticket) and `bridge` (to dispatch)
  # from here — the default is `connect_secret: nil`, i.e. no tool servers.
  defp put_connectors_config(overrides) do
    prev = Application.get_env(:barkpark, Barkpark.Connectors)
    merged = Keyword.merge(prev || [], overrides)
    Application.put_env(:barkpark, Barkpark.Connectors, merged)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, Barkpark.Connectors, prev),
        else: Application.delete_env(:barkpark, Barkpark.Connectors)
    end)
  end

  defp put_chat_config(config) do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, config)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)
  end

  describe "enabled?/0 (fail-closed gate)" do
    test "off when the flag is explicitly disabled" do
      put_chat_config(enabled: false, command: {"cat", []})
      refute ClaudeChat.enabled?()
    end

    test "on with the default flag — binary presence no longer gates (the inversion)" do
      put_chat_config(command: {"cat", []})
      assert ClaudeChat.enabled?()
    end

    test "hard-refuses public-demo hosts regardless of the flag" do
      put_chat_config(enabled: true, command: {"cat", []})
      Application.put_env(:barkpark, :public_demo_studio, true)
      refute ClaudeChat.enabled?()
    end

    # FLIPPED by the chat-task-hands gate inversion (charter decision 4): a
    # missing binary used to hide the tab and redirect the mount — now the
    # surface stays and the onboarding card names the state instead. The
    # security-posture gates (flag-off, public-demo, non-admin) still refuse.
    test "STAYS on when the binary is not installed — the card speaks, not a vanish" do
      put_chat_config(enabled: true, command: {"definitely-not-a-real-binary-bp", []})
      assert ClaudeChat.enabled?()
    end

    test "start_session refuses when disabled" do
      put_chat_config(enabled: false, command: {"cat", []})
      assert {:error, :disabled} = ClaudeChat.start_session(%{sink: self()})
    end
  end

  @unauthed_fixture Path.expand("../../fixtures/claude_chat/unauthed_stream.ndjson", __DIR__)

  defp unauthed_frames do
    @unauthed_fixture
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.reject(&(&1["type"] == "fixture_provenance"))
  end

  describe "runtime auth guard classifiers (chat-task-hands, decision 5)" do
    test "the captured unauthed stream's assistant AND result frames both classify as auth failures" do
      frames = unauthed_frames()

      assistant = Enum.find(frames, &(&1["type"] == "assistant"))
      result = Enum.find(frames, &(&1["type"] == "result"))

      # The fixture carries the exact footgun (wire truth, charter Verified
      # ground 2026-07-11): result says subtype success, but the error facts win.
      assert result["subtype"] == "success"
      assert result["is_error"] == true
      assert result["terminal_reason"] == "api_error"
      assert assistant["error"] == "authentication_failed"

      assert ClaudeChat.auth_failure?(assistant)
      assert ClaudeChat.auth_failure?(result)
    end

    test "subtype:success alone is NEVER trusted — result_success? demands the error facts agree" do
      [result] = Enum.filter(unauthed_frames(), &(&1["type"] == "result"))

      # The lying frame: subtype success + is_error true → never a success.
      refute ClaudeChat.result_success?(result)

      # The honest frame: same subtype, no error facts → a real success.
      assert ClaudeChat.result_success?(%{"type" => "result", "subtype" => "success"})

      refute ClaudeChat.result_success?(%{
               "type" => "result",
               "subtype" => "error_during_execution"
             })

      refute ClaudeChat.result_success?(%{"type" => "assistant"})
    end

    test "ordinary frames never classify as auth failures" do
      refute ClaudeChat.auth_failure?(%{"type" => "assistant", "message" => %{"content" => []}})
      refute ClaudeChat.auth_failure?(%{"type" => "result", "subtype" => "success"})

      # An interrupted turn (is_error without the api_error terminus) is an
      # interrupt, never a login card.
      refute ClaudeChat.auth_failure?(%{
               "type" => "result",
               "subtype" => "error_during_execution",
               "is_error" => true,
               "terminal_reason" => "aborted_streaming"
             })

      refute ClaudeChat.auth_failure?(nil)
      refute ClaudeChat.auth_failure?(%{"type" => "system", "subtype" => "init"})
    end
  end

  describe "parse_chunk/2 (NDJSON line assembly)" do
    test "decodes complete lines and keeps the partial tail" do
      chunk = ~s({"type":"a"}\n{"type":"b"}\n{"ty)
      assert {[%{"type" => "a"}, %{"type" => "b"}], ~s({"ty)} = ClaudeChat.parse_chunk("", chunk)
    end

    test "joins a split line across chunks" do
      {[], rest} = ClaudeChat.parse_chunk("", ~s({"type":"sys))
      assert {[%{"type" => "system"}], ""} = ClaudeChat.parse_chunk(rest, ~s(tem"}\n))
    end

    test "drops non-JSON lines without crashing" do
      chunk = "not json\n{\"ok\":true}\n"
      assert {[%{"ok" => true}], ""} = ClaudeChat.parse_chunk("", chunk)
    end

    test "ignores blank lines" do
      assert {[%{"a" => 1}], ""} = ClaudeChat.parse_chunk("", "\n{\"a\":1}\n\n")
    end
  end

  describe "permission modes" do
    test "the stdio permission bridge ships in ALL modes, plan included (charter D33)" do
      {_exe, plan_args} = with_default_command(fn -> ClaudeChat.command("plan") end)
      # A real six-mode ASK mode (charter D48 — `default` is retired; acceptEdits
      # is a genuine non-plan mode that still routes asks to us).
      {_exe, ask_args} = with_default_command(fn -> ClaudeChat.command("acceptEdits") end)

      # Plan mode is the product default and every plan session hits
      # ExitPlanMode — without the flag that ask never reaches Barkpark, so the
      # proposed-plan card could never render.
      assert Enum.chunk_every(plan_args, 2, 1)
             |> Enum.member?(["--permission-prompt-tool", "stdio"])

      assert Enum.chunk_every(plan_args, 2, 1) |> Enum.member?(["--permission-mode", "plan"])

      assert Enum.chunk_every(ask_args, 2, 1)
             |> Enum.member?(["--permission-prompt-tool", "stdio"])

      assert Enum.chunk_every(ask_args, 2, 1)
             |> Enum.member?(["--permission-mode", "acceptEdits"])
    end

    test "the six real modes are offered; the retired default is not" do
      assert ClaudeChat.modes() == ~w(plan acceptEdits auto dontAsk manual bypassPermissions)
      refute "default" in ClaudeChat.modes()
    end

    test "a legacy stored `default` mode still spawns --permission-mode default verbatim" do
      # No data migration, no read-time rewrite (charter D48): an existing row
      # carrying `default` keeps spawning it byte-for-byte — build_args passes the
      # mode through untouched.
      args = ClaudeChat.build_args("default", %{})
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--permission-mode", "default"])
    end

    test "normalize_mode fails closed to plan" do
      assert ClaudeChat.normalize_mode("acceptEdits") == "acceptEdits"
      # FAIL-CLOSED LAW (charter D48): an untrusted string never fails OPEN into
      # bypass — bypassPermissions is the one road-blocked mode.
      assert ClaudeChat.normalize_mode("bypassPermissions") == "plan"
      assert ClaudeChat.normalize_mode(nil) == "plan"
      # every real ask mode round-trips
      for m <- ~w(auto dontAsk manual), do: assert(ClaudeChat.normalize_mode(m) == m)
    end

    defp with_default_command(fun) do
      prev = Application.get_env(:barkpark, :claude_chat)
      Application.put_env(:barkpark, :claude_chat, enabled: true)

      try do
        fun.()
      after
        if prev,
          do: Application.put_env(:barkpark, :claude_chat, prev),
          else: Application.delete_env(:barkpark, :claude_chat)
      end
    end
  end

  # The session-identity seam (charter D8/D9). build_args/2 is pure and public
  # precisely so flag behavior is asserted WITHOUT spawning a Port and WITHOUT
  # routing through the `:command` override (which returns its tuple verbatim,
  # bypassing build_args — a vacuous-green trap for any flag assertion).
  describe "build_args/2 (pure session-args seam)" do
    @uuid "3f9a1c2e-0b7d-4a11-9c33-77e6a2b4d501"

    test "a fresh session pins --session-id and never --resume" do
      args = ClaudeChat.build_args("plan", %{session_id: @uuid})
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--session-id", @uuid])
      refute "--resume" in args
    end

    test "resume uses --resume and refuses --session-id (mutually exclusive)" do
      args = ClaudeChat.build_args("plan", %{session_id: @uuid, resume: true})
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--resume", @uuid])
      refute "--session-id" in args
    end

    test "resume: false pins a fresh --session-id (not a resume)" do
      args = ClaudeChat.build_args("plan", %{session_id: @uuid, resume: false})
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--session-id", @uuid])
      refute "--resume" in args
    end

    test "absent session_opts adds neither flag (back-compat)" do
      args = ClaudeChat.build_args("plan", %{})
      refute "--session-id" in args
      refute "--resume" in args
    end

    test "session args are appended onto the mode's base args" do
      args = ClaudeChat.build_args("acceptEdits", %{session_id: @uuid})
      # the base permission args survive the append
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--permission-mode", "acceptEdits"])
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--permission-prompt-tool", "stdio"])
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--session-id", @uuid])
    end

    # Charter D33 — proved through the PURE seam (never `:command`, which bypasses
    # build_args): plan mode carries the stdio bridge exactly like the asking
    # modes, so ExitPlanMode asks reach Barkpark and the plan card can render.
    test "plan mode carries --permission-prompt-tool stdio (D33)" do
      args = ClaudeChat.build_args("plan", %{session_id: @uuid})
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--permission-prompt-tool", "stdio"])
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--permission-mode", "plan"])
    end

    test "command/2 threads session_opts through the default args" do
      {_exe, args} =
        with_default_command(fn -> ClaudeChat.command("plan", %{session_id: @uuid}) end)

      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--session-id", @uuid])
    end
  end

  # Charter D63/D64 — the loopback flags, proven through the PURE seam (D9):
  # Session.init writes the temp config file; build_args only references it.
  describe "mcp loopback args (charter D63/D64, pure D9 seam)" do
    @cfg "/tmp/barkpark-claude-x.mcp.json"

    test "an mcp config path rides as --mcp-config <path> --strict-mcp-config" do
      args = ClaudeChat.build_args("plan", %{session_id: @uuid, mcp_config_path: @cfg})
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--mcp-config", @cfg])
      # strict: ours is the ONLY server — the host's saved MCP config (whose
      # bp inherits host ADMIN, proven live) must never merge in.
      assert "--strict-mcp-config" in args
    end

    test "absent mcp config ⇒ neither flag (back-compat)" do
      args = ClaudeChat.build_args("plan", %{session_id: @uuid})
      refute "--mcp-config" in args
      refute "--strict-mcp-config" in args
    end

    test "mcp_config/1 shape: bp mcp serve --tools all + a COMPLETE env block" do
      config = ClaudeChat.mcp_config("bpcs_secret")
      assert %{"mcpServers" => %{"barkpark" => server}} = config
      assert server["command"] == "bp"
      assert server["args"] == ["mcp", "serve", "--tools", "all"]
      # BOTH url and token pinned: the child bp never falls back to the
      # host's saved credentials (no admin inheritance — D63).
      assert %{"BARKPARK_API_URL" => url, "BARKPARK_API_TOKEN" => "bpcs_secret"} =
               server["env"]

      assert is_binary(url) and url != ""
    end

    test "mcp_config/2 with no descriptors == mcp_config/1 (back-compat, connectors D69)" do
      assert ClaudeChat.mcp_config("bpcs_x", []) == ClaudeChat.mcp_config("bpcs_x")
    end

    test "mcp_config/2 FOLDS a tool descriptor as a SECOND mcpServers key (D69/D71)" do
      helper =
        "curl -sS -X POST -d '{\"ticket\":\"t\"}' " <>
          "http://127.0.0.1:4020/connectors/connect/tool-headers/github"

      descriptor = %{
        "provider" => "github",
        "type" => "http",
        "url" => "https://api.githubcopilot.com/mcp/",
        "headersHelper" => helper
      }

      servers = ClaudeChat.mcp_config("bpcs_secret", [descriptor])["mcpServers"]

      # The loopback server survives UNSHADOWED, still carrying the minted token —
      # a tool connector is ADDITIVE, never a replacement.
      assert servers["barkpark"]["env"]["BARKPARK_API_TOKEN"] == "bpcs_secret"

      # …and github lands as a SECOND key, DERIVED from the descriptor (provider,
      # transport, url, and the non-secret headersHelper that fetches the PAT).
      assert servers["github"] == %{
               "type" => "http",
               "url" => "https://api.githubcopilot.com/mcp/",
               "headersHelper" => helper
             }

      assert map_size(servers) == 2
    end

    test "a SECOND tool connector is a SECOND mcpServers key — the acceptance bar (D69)" do
      descriptors = [
        %{
          "provider" => "github",
          "type" => "http",
          "url" => "https://api.githubcopilot.com/mcp/",
          "headersHelper" => "curl github"
        },
        %{
          "provider" => "linear",
          "type" => "http",
          "url" => "https://mcp.linear.app/sse",
          "headersHelper" => "curl linear"
        }
      ]

      servers = ClaudeChat.mcp_config("bpcs", descriptors)["mcpServers"]
      # ZERO core-loop change: two tool connectors, two entries, no special-case.
      assert Enum.sort(Map.keys(servers)) == ["barkpark", "github", "linear"]
    end

    test "mcp_config/2 FAILS CLOSED on malformed / reserved-name descriptors (never shadows barkpark)" do
      bad = [
        # no url/type
        %{"provider" => "github"},
        # reserved name — must NEVER override the loopback server's minted token
        %{"provider" => "barkpark", "type" => "http", "url" => "https://evil.example/"},
        # no provider
        %{"type" => "http", "url" => "https://x.example/"},
        # non-http transport (only http is a tool transport today, D71)
        %{"provider" => "linear", "type" => "stdio", "url" => "x"},
        # blank url
        %{"provider" => "zed", "type" => "http", "url" => ""}
      ]

      servers = ClaudeChat.mcp_config("bpcs_secret", bad)["mcpServers"]
      # ONLY the loopback server, and its token intact — no rogue shadow.
      assert map_size(servers) == 1
      assert servers["barkpark"]["env"]["BARKPARK_API_TOKEN"] == "bpcs_secret"
    end

    test "a tool descriptor with no headersHelper folds a URL-only server (fail-soft)" do
      descriptor = %{"provider" => "github", "type" => "http", "url" => "https://x.example/mcp/"}
      servers = ClaudeChat.mcp_config("bpcs", [descriptor])["mcpServers"]
      assert servers["github"] == %{"type" => "http", "url" => "https://x.example/mcp/"}
      refute Map.has_key?(servers["github"], "headersHelper")
    end

    test "plan mode road-blocks Workflow (D65/D68 fail-closed until S3's verdict)" do
      args = ClaudeChat.build_args("plan", %{session_id: @uuid})
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--disallowedTools", "Workflow"])
    end

    test "an UNARMED bypass falls back to plan and carries the road-block too" do
      args = ClaudeChat.build_args("bypassPermissions", %{session_id: @uuid})
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--permission-mode", "plan"])
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--disallowedTools", "Workflow"])
    end

    test "asking modes do NOT road-block Workflow (their asks reach the human)" do
      for mode <- ["acceptEdits", "auto", "dontAsk", "manual"] do
        args = ClaudeChat.build_args(mode, %{session_id: @uuid})
        refute "--disallowedTools" in args, "#{mode} unexpectedly disallows tools"
      end
    end
  end

  # Charter D64/D65 — the loopback tool vocabulary (fail-closed allowlist).
  describe "loopback tool vocabulary (charter D64/D65)" do
    test "mcp_tool?/1 matches ONLY our server's prefix" do
      assert ClaudeChat.mcp_tool?("mcp__barkpark__task_ready")
      assert ClaudeChat.mcp_tool?("mcp__barkpark__bp_search_query")
      refute ClaudeChat.mcp_tool?("Bash")
      refute ClaudeChat.mcp_tool?("mcp__github__get_issue")
      refute ClaudeChat.mcp_tool?(nil)
    end

    test "mcp_tool_name/1 strips our prefix; nil for everything else" do
      assert ClaudeChat.mcp_tool_name("mcp__barkpark__task_ready") == "task_ready"
      assert ClaudeChat.mcp_tool_name("mcp__barkpark__bp_doc_get") == "bp_doc_get"
      assert ClaudeChat.mcp_tool_name("Read") == nil
      assert ClaudeChat.mcp_tool_name("mcp__github__x") == nil
    end

    test "read-only loopback tools auto-approve (D65)" do
      for tool <- ~w(task_ready task_show task_prime bp_task_get bp_doc_get
                     bp_doc_ls bp_doc_query bp_search_query) do
        assert ClaudeChat.mcp_auto_approved?("mcp__barkpark__#{tool}"),
               "#{tool} should auto-approve"
      end
    end

    test "herd read tools auto-approve; herd write tools stay approval-gated (herd-s4)" do
      # herd-s4: fleet OBSERVATION (read the wire) auto-approves; anything that
      # spawns or sends a message MUTATES and lands the D31 approval card.
      for tool <- ~w(chat_read_tail chat_wait_for_state) do
        assert ClaudeChat.mcp_auto_approved?("mcp__barkpark__#{tool}"),
               "#{tool} (herd read) should auto-approve"
      end

      for tool <- ~w(chat_spawn_session chat_send) do
        refute ClaudeChat.mcp_auto_approved?("mcp__barkpark__#{tool}"),
               "#{tool} (herd write) must NOT auto-approve"
      end
    end

    test "mutating (and merely unlisted) tools NEVER auto-approve — fail closed" do
      # task_next CLAIMS a task; create/close/publish write; auth_* mutate
      # credentials; anything unknown fails closed onto the approval card.
      for tool <- ~w(task_next task_create task_close bp_doc_create bp_doc_patch
                     bp_doc_publish bp_auth_login bp_secret_get bp_never_heard_of_it) do
        refute ClaudeChat.mcp_auto_approved?("mcp__barkpark__#{tool}"),
               "#{tool} must NOT auto-approve"
      end

      refute ClaudeChat.mcp_auto_approved?("Bash")
      refute ClaudeChat.mcp_auto_approved?("mcp__github__get_issue")
      refute ClaudeChat.mcp_auto_approved?(nil)
    end

    test "mcp_connected?/1 derives the Capabilities.mcp_tools truth off the init frame" do
      assert ClaudeChat.mcp_connected?(%{
               "mcp_servers" => [%{"name" => "barkpark", "status" => "connected"}]
             })

      refute ClaudeChat.mcp_connected?(%{
               "mcp_servers" => [%{"name" => "barkpark", "status" => "failed"}]
             })

      refute ClaudeChat.mcp_connected?(%{
               "mcp_servers" => [%{"name" => "github", "status" => "connected"}]
             })

      refute ClaudeChat.mcp_connected?(%{"mcp_servers" => []})
      refute ClaudeChat.mcp_connected?(%{})
      refute ClaudeChat.mcp_connected?(nil)
    end
  end

  describe "permission bridge (control protocol)" do
    @can_use_tool ~s({"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/tmp/x"},"title":"Claude wants to write /tmp/x"}})

    test "can_use_tool asks become {:claude_chat_permission, ...} sink messages" do
      script = ~s(printf '%s\n' '#{@can_use_tool}'; cat)
      put_chat_config(command: {"sh", ["-c", script]})

      {:ok, _session} = ClaudeChat.start_session(%{sink: self()})

      assert_receive {:claude_chat_permission,
                      %{
                        request_id: "req-1",
                        tool_name: "Write",
                        input: %{"file_path" => "/tmp/x"},
                        title: "Claude wants to write /tmp/x"
                      }},
                     2_000
    end

    test "a bare allow with no tracked ask echoes an empty updatedInput (charter D32)" do
      put_chat_config(command: {"cat", []})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      ClaudeChat.respond_permission(session, "req-9", :allow)

      # Even a bare allow ALWAYS carries updatedInput — a `{"behavior":"allow"}`
      # with no updatedInput FAILS ExitPlanMode on the real binary (D32). With
      # no ask tracked for this id the echo is the empty map.
      assert_receive {:claude_chat_event,
                      %{
                        "type" => "control_response",
                        "response" => %{
                          "subtype" => "success",
                          "request_id" => "req-9",
                          "response" => %{"behavior" => "allow", "updatedInput" => %{}}
                        }
                      }},
                     2_000
    end

    test "a plain allow echoes the ORIGINAL tracked ask input as updatedInput (D32)" do
      # The script emits a can_use_tool ask (so the Session tracks its input by
      # request_id), then `cat` loops the control_response back to us.
      script = ~s(printf '%s\n' '#{@can_use_tool}'; cat)
      put_chat_config(command: {"sh", ["-c", script]})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      assert_receive {:claude_chat_permission, %{request_id: "req-1"}}, 2_000

      # A PLAIN :allow — the caller never round-trips the input; the Session
      # echoes the tracked ask input verbatim.
      ClaudeChat.respond_permission(session, "req-1", :allow)

      assert_receive {:claude_chat_event,
                      %{
                        "type" => "control_response",
                        "response" => %{
                          "request_id" => "req-1",
                          "response" => %{
                            "behavior" => "allow",
                            "updatedInput" => %{"file_path" => "/tmp/x"}
                          }
                        }
                      }},
                     2_000
    end

    test "an allowed ExitPlanMode reports the plan-approve fact to the sink" do
      exit_plan =
        ~s({"type":"control_request","request_id":"req-plan","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{"plan":"# The plan"},"title":"Ready to code?"}})

      script = ~s(printf '%s\n' '#{exit_plan}'; cat)
      put_chat_config(command: {"sh", ["-c", script]})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      assert_receive {:claude_chat_permission, %{request_id: "req-plan"}}, 2_000

      ClaudeChat.respond_permission(session, "req-plan", :allow)

      # The fact fires AFTER the control_response is on the wire (stdio order:
      # the CLI's own plan→default flip happens first, then any policy steer).
      assert_receive {:claude_chat_event, %{"type" => "control_response"}}, 2_000
      assert_receive {:claude_chat_plan_approved, "req-plan"}, 2_000
    end

    test "a denied ExitPlanMode (keep planning) reports NO plan-approve fact" do
      exit_plan =
        ~s({"type":"control_request","request_id":"req-plan","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{"plan":"# The plan"}}})

      script = ~s(printf '%s\n' '#{exit_plan}'; cat)
      put_chat_config(command: {"sh", ["-c", script]})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      assert_receive {:claude_chat_permission, %{request_id: "req-plan"}}, 2_000

      ClaudeChat.respond_permission(session, "req-plan", {:deny, "keep planning"})

      assert_receive {:claude_chat_event, %{"type" => "control_response"}}, 2_000
      refute_receive {:claude_chat_plan_approved, _}, 200
    end

    test "an allowed NON-plan tool reports NO plan-approve fact" do
      script = ~s(printf '%s\n' '#{@can_use_tool}'; cat)
      put_chat_config(command: {"sh", ["-c", script]})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      assert_receive {:claude_chat_permission, %{request_id: "req-1"}}, 2_000

      ClaudeChat.respond_permission(session, "req-1", :allow)

      assert_receive {:claude_chat_event, %{"type" => "control_response"}}, 2_000
      refute_receive {:claude_chat_plan_approved, _}, 200
    end

    test "an {:allow, updated} carries the CALLER's updatedInput (question answers, D32)" do
      put_chat_config(command: {"cat", []})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})

      answered = %{
        "questions" => [%{"question" => "Pick a pet"}],
        "answers" => %{"Pick a pet" => "Cat, Dog"}
      }

      ClaudeChat.respond_permission(session, "req-9", {:allow, answered})

      assert_receive {:claude_chat_event,
                      %{
                        "response" => %{
                          "response" => %{
                            "behavior" => "allow",
                            "updatedInput" => ^answered
                          }
                        }
                      }},
                     2_000
    end

    test "deny carries the message back to the model" do
      put_chat_config(command: {"cat", []})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      ClaudeChat.respond_permission(session, "req-9", {:deny, "not now"})

      assert_receive {:claude_chat_event,
                      %{
                        "response" => %{
                          "response" => %{"behavior" => "deny", "message" => "not now"}
                        }
                      }},
                     2_000
    end

    test "unsupported control requests are auto-answered with an error (never hang)" do
      req =
        ~s({"type":"control_request","request_id":"req-2","request":{"subtype":"mystery_capability"}})

      script = ~s(printf '%s\n' '#{req}'; cat)
      put_chat_config(command: {"sh", ["-c", script]})

      {:ok, _session} = ClaudeChat.start_session(%{sink: self()})

      assert_receive {:claude_chat_event,
                      %{
                        "type" => "control_response",
                        "response" => %{"subtype" => "error", "request_id" => "req-2"}
                      }},
                     2_000

      refute_receive {:claude_chat_permission, _}, 200
    end
  end

  describe "session subprocess" do
    test "round-trips a user message through a real Port (cat echo)" do
      put_chat_config(command: {"cat", []})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      ClaudeChat.send_message(session, "hello there")

      assert_receive {:claude_chat_event,
                      %{
                        "type" => "user",
                        "message" => %{
                          "content" => [%{"type" => "text", "text" => "hello there"}]
                        }
                      }},
                     2_000

      ClaudeChat.close(session)
    end

    test "a content-block list rides the user frame verbatim (text + base64 image)" do
      # Charter D25: send_message accepts a ready content-block list so a turn can
      # carry pasted/dropped images. The Port loopback (`cat`) echoes exactly what
      # was written to stdin, proving the frame's content is the blocks we passed —
      # NOT a hardcoded single text block.
      put_chat_config(command: {"cat", []})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})

      blocks = [
        %{"type" => "text", "text" => "what is this?"},
        %{
          "type" => "image",
          "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "aGVsbG8="}
        }
      ]

      ClaudeChat.send_message(session, blocks)

      assert_receive {:claude_chat_event,
                      %{
                        "type" => "user",
                        "message" => %{
                          "role" => "user",
                          "content" => [
                            %{"type" => "text", "text" => "what is this?"},
                            %{
                              "type" => "image",
                              "source" => %{
                                "type" => "base64",
                                "media_type" => "image/png",
                                "data" => "aGVsbG8="
                              }
                            }
                          ]
                        }
                      }},
                     2_000

      ClaudeChat.close(session)
    end

    test "delivers canned events and the exit status" do
      script = ~s(printf '%s\\n' '{"type":"system","subtype":"init","model":"test-model"}')
      put_chat_config(command: {"sh", ["-c", script]})

      {:ok, _session} = ClaudeChat.start_session(%{sink: self()})

      assert_receive {:claude_chat_event,
                      %{"type" => "system", "subtype" => "init", "model" => "test-model"}},
                     2_000

      assert_receive {:claude_chat_exit, 0, _tail}, 2_000
    end

    test "reports a non-zero exit status" do
      put_chat_config(command: {"sh", ["-c", "exit 3"]})

      {:ok, _session} = ClaudeChat.start_session(%{sink: self()})
      assert_receive {:claude_chat_exit, 3, _tail}, 2_000
    end

    # ── stderr capture: honest dead spawns (charter D54) ──────────────────────
    #
    # A rejected argv exits nonzero with the reason on stderr and ZERO stdout
    # frames. The exec-wrapper (`/bin/sh -c 'exec "$0" "$@" 2>>file'`) must
    # capture that reason and carry its tail on the exit message — otherwise the
    # UI keeps inviting a resume that re-dies identically.
    test "captures the child's stderr tail on a nonzero exit" do
      script = ~s(printf 'boom: unknown option --nope\\n' 1>&2; exit 1)
      put_chat_config(command: {"sh", ["-c", script]})

      {:ok, _session} = ClaudeChat.start_session(%{sink: self()})

      assert_receive {:claude_chat_exit, 1, tail}, 2_000
      assert tail =~ "boom: unknown option --nope"
    end

    # The wrapper redirects fd 2 ONLY — stdout ndjson must stay pristine even
    # when the child also writes noise to stderr (a leak would make the JSON
    # line un-parseable and this event would never arrive).
    test "stderr capture leaves stdout ndjson pristine" do
      script =
        ~s(printf '%s\\n' '{"type":"system","subtype":"init","model":"m"}'; ) <>
          ~s(printf 'noise on stderr\\n' 1>&2)

      put_chat_config(command: {"sh", ["-c", script]})

      {:ok, _session} = ClaudeChat.start_session(%{sink: self()})

      assert_receive {:claude_chat_event, %{"type" => "system", "subtype" => "init"}}, 2_000
      assert_receive {:claude_chat_exit, 0, tail}, 2_000
      assert tail =~ "noise on stderr"
    end

    # The stderr capture file must not outlive the session (charter D54). Pin a
    # session id so the path is deterministic (no shared-dir wildcard flake).
    test "removes the stderr capture file on close" do
      uuid = Ecto.UUID.generate()
      path = Path.join(System.tmp_dir!(), "barkpark-claude-#{uuid}.stderr")

      put_chat_config(command: {"cat", []})

      {:ok, session} =
        ClaudeChat.start_session(%{sink: self(), session_opts: %{session_id: uuid}})

      ref = Process.monitor(session)

      ClaudeChat.close(session)
      assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000

      refute File.exists?(path)
    end

    # ── stdout buffer ceiling (charter D126, codex-twin parity) ───────────────
    #
    # The CLI streams newline-delimited JSON, so parse_chunk normally holds only
    # the trailing partial line. A malformed/stalled stream that never emits a
    # newline would otherwise grow `state.buffer` without bound in the long-lived
    # per-session GenServer. This stub floods stdout with a NEWLINE-FREE blob well
    # past a shrunk cap: no complete line ever reaches the event path, so the cap
    # must fire at the accumulation seam. UNCAPPED code never emits the overflow
    # error (the buffer just grows until the stub exits) — this reds without the
    # cap and greens with it. Asserts threshold-crossing behavior, never bytes.
    test "caps the stdout line-reassembly buffer and stops with a named overflow" do
      put_chat_config(
        command: {"sh", ["-c", "head -c 200000 /dev/zero | tr '\\0' 'x'"]},
        max_buffer_bytes: 64 * 1024
      )

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      ref = Process.monitor(session)

      # Named error reaches the sink…
      assert_receive {:claude_chat_error, :buffer_overflow, _tail}, 2_000
      # …and the session stops cleanly (terminate/2 cleanup runs), never crashes.
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2_000
    end

    test "session dies with its sink (no leaked subprocess owner)" do
      put_chat_config(command: {"cat", []})

      test_pid = self()

      sink =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, session} = ClaudeChat.start_session(%{sink: sink})
      ref = Process.monitor(session)
      send(test_pid, :ready)
      send(sink, :stop)

      assert_receive {:DOWN, ^ref, :process, ^session, _reason}, 2_000
    end

    # send_message is a GenServer.call (charter D24): the reply carries the REAL
    # write outcome so the composer can distinguish a dispatched turn from a lost
    # one. safe_command no longer swallows failures to a false :ok.
    test "send_message reports :ok when the frame reaches the port" do
      put_chat_config(command: {"cat", []})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      assert ClaudeChat.send_message(session, "hi") == :ok

      ClaudeChat.close(session)
    end

    test "send_message reports an honest {:error} once the session/port is gone — never a false :ok" do
      put_chat_config(command: {"cat", []})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      ref = Process.monitor(session)
      ClaudeChat.close(session)
      assert_receive {:DOWN, ^ref, :process, ^session, _reason}, 2_000

      # The subprocess (and its port) is gone; the write cannot land. The seam
      # returns {:error, _}, so the LiveView withdraws the echo instead of
      # rendering a message that never sent.
      assert {:error, _reason} = ClaudeChat.send_message(session, "too late")
    end
  end

  # End-to-end proof that session identity reaches the REAL spawned process
  # argv. Uses the `:binary` override (NOT `:command`): `:binary` only swaps the
  # executable and KEEPS build_args, so the argv the process receives is the
  # true one. A `:command` override would return its tuple verbatim and prove
  # nothing (vacuous-green law, charter D9). The fake binary echoes its argv to
  # a file so we read back exactly what the OS handed the process.
  describe "spawned argv (end-to-end :binary override)" do
    test "a fresh session's real argv carries --session-id and never --resume" do
      argv_file = capture_path("argv")
      put_chat_config(binary: argv_echo_binary(argv_file))
      uuid = "11111111-2222-3333-4444-555555555555"

      {:ok, session} =
        ClaudeChat.start_session(%{sink: self(), session_opts: %{session_id: uuid}})

      argv = read_lines(argv_file)
      assert Enum.chunk_every(argv, 2, 1) |> Enum.member?(["--session-id", uuid])
      refute "--resume" in argv

      ClaudeChat.close(session)
    end

    test "a resume's real argv carries --resume and never --session-id" do
      argv_file = capture_path("argv")
      put_chat_config(binary: argv_echo_binary(argv_file))
      uuid = "66666666-7777-8888-9999-000000000000"

      {:ok, session} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{session_id: uuid, resume: true}
        })

      argv = read_lines(argv_file)
      assert Enum.chunk_every(argv, 2, 1) |> Enum.member?(["--resume", uuid])
      refute "--session-id" in argv

      ClaudeChat.close(session)
    end
  end

  # The Cloud execution-profile seam (connectors D107–D110). The profile is a
  # config-keyed resolver in `command/2` — `:self_hosted` (default) stays
  # byte-identical to the pre-D107 host-CLI argv; `:cloud` returns the
  # `cloud-sandbox-runner` shim + the D109 argv, gated on a concrete workspace
  # principal (D110). Pure tests pin the argv contract; the end-to-end tests
  # drive a chmod+x fake shim through the REAL Port + parse pipeline so a
  # bogus-key result frame proves the wire without a live sandbox.
  describe "execution profile — self-hosted default (connectors D107)" do
    test "no config ⇒ :self_hosted, and command/0 is byte-identical to the pre-D107 host argv" do
      put_chat_config([])
      assert ClaudeChat.execution_profile() == :self_hosted

      {exe, args} = ClaudeChat.command()
      assert exe == "claude"
      # Routes through build_args/2 unchanged — the :cloud branch must never
      # perturb the default path.
      assert {exe, args} == {ClaudeChat.binary(), ClaudeChat.build_args("plan", %{})}

      # Concrete interactive-argv prefix — a drift tripwire on the host path.
      assert Enum.take(args, 11) == [
               "--print",
               "--verbose",
               "--input-format",
               "stream-json",
               "--output-format",
               "stream-json",
               "--include-partial-messages",
               "--permission-mode",
               "plan",
               "--permission-prompt-tool",
               "stdio"
             ]

      assert "--disallowedTools" in args
      assert "Workflow" in args
    end

    test "an unrecognized :execution_profile value fails to :self_hosted (never silently cloud)" do
      put_chat_config(execution_profile: :bogus)
      assert ClaudeChat.execution_profile() == :self_hosted
      assert {"claude", _args} = ClaudeChat.command()
    end
  end

  describe "execution profile — cloud (connectors D108/D109/D110)" do
    # W14 session-identity fixtures (connectors D135/D137/D139): a Barkpark session
    # UUID and a bound sandbox id.
    @cloud_uuid "11111111-1111-4111-8111-111111111111"
    @cloud_sandbox "sbx_cloud_abc123"

    test ":cloud 0 installs, fresh session — shim runner + W13 belt with the ALWAYS-ON --keep-sandbox and a fresh --session-id (D141 byte-identity MODULO session flags)" do
      # The 0-install row of the D130 argv table: no `:tool_descriptors` in
      # session_opts ⇒ CloudPolicy emits `%{}` ⇒ NO `--mcp-config-b64` flag ⇒ the
      # argv is byte-identical to W12 MODULO the W14 session-identity flags. The
      # ≥1-install rows (flag present, scoped map) live in the DB-backed "cloud
      # mcp-config wiring" describe below and in cloud_policy_test.exs's argv table.
      put_chat_config(execution_profile: :cloud, sandbox_runner: "cloud-sandbox-runner")

      {exe, args} = ClaudeChat.command("plan", %{workspace_id: "ws-42", session_id: @cloud_uuid})
      assert exe == "cloud-sandbox-runner"

      # No connector-scoped MCP flag on the 0-install path.
      refute "--mcp-config-b64" in args

      # The shim's OWN pre-`--` argv: `--workspace <id>`, then the ALWAYS-ON
      # `--keep-sandbox` (no binding ⇒ NO `--sandbox-id`), then the `--` separator.
      assert Enum.take(args, 4) == ["--workspace", "ws-42", "--keep-sandbox", "--"]
      refute "--sandbox-id" in args

      # The post-`--` claude segment: the session-identity flags at the FRONT
      # (fresh ⇒ `--session-id`, never `--resume`), then the full D109 base + the
      # D116/D117 CloudPolicy belts (mode clamped, all built-ins removed, deny
      # set, deny JSON string, disallowedTools last).
      assert Enum.drop(args, 4) ==
               ["--session-id", @cloud_uuid] ++
                 [
                   "--input-format",
                   "stream-json",
                   "--output-format",
                   "stream-json",
                   "--include-partial-messages",
                   "--verbose",
                   "--permission-mode",
                   "plan",
                   "--tools",
                   "",
                   "--settings",
                   Barkpark.Connectors.CloudPolicy.settings_deny_json()
                 ] ++
                 ["--disallowedTools" | Barkpark.Connectors.CloudPolicy.cloud_disallowed_tools()]

      refute "--resume" in args
    end

    test ":cloud bound session — pre-`--` --sandbox-id + --keep-sandbox, post-`--` --resume (D135/D137)" do
      args =
        ClaudeChat.cloud_build_args("plan", %{
          workspace_id: "ws-42",
          session_id: @cloud_uuid,
          cloud_sandbox_id: @cloud_sandbox
        })

      sep = Enum.find_index(args, &(&1 == "--"))

      # Pre-`--`: the bound sandbox id then --keep-sandbox (D141's W14-1 order:
      # `--sandbox-id <id> --keep-sandbox`).
      assert Enum.take(args, sep) == [
               "--workspace",
               "ws-42",
               "--sandbox-id",
               @cloud_sandbox,
               "--keep-sandbox"
             ]

      # Post-`--`: --resume at the FRONT of the claude segment, NEVER --session-id.
      assert Enum.take(Enum.drop(args, sep + 1), 2) == ["--resume", @cloud_uuid]
      refute "--session-id" in args

      # The full W12/W13 belt is intact — a bound multi-turn session is STILL
      # locked down (multi-turn never re-opens host tools).
      assert_w12_belt_intact(args)
    end

    test "D139 LAW — resume-ness derives from the BINDING, never session_opts[:resume]/message_count" do
      # A session_opts[:resume] flag (the self-hosted transport signal) must NOT
      # force --resume on the cloud path when there is NO sandbox binding: a
      # resume into a vanished sandbox would hit an empty filesystem.
      no_binding =
        ClaudeChat.cloud_build_args("plan", %{
          workspace_id: "ws-42",
          session_id: @cloud_uuid,
          resume: true
        })

      assert Enum.chunk_every(no_binding, 2, 1) |> Enum.member?(["--session-id", @cloud_uuid])
      refute "--resume" in no_binding
      refute "--sandbox-id" in no_binding
      assert_w12_belt_intact(no_binding)

      # Conversely, a bound session resumes even with `resume: false` — the
      # binding, not the transport boolean, is the sole signal.
      bound =
        ClaudeChat.cloud_build_args("plan", %{
          workspace_id: "ws-42",
          session_id: @cloud_uuid,
          resume: false,
          cloud_sandbox_id: @cloud_sandbox
        })

      assert Enum.chunk_every(bound, 2, 1) |> Enum.member?(["--resume", @cloud_uuid])
      refute "--session-id" in bound
      assert_w12_belt_intact(bound)
    end

    test ":cloud with no session_id — neither session flag, but --keep-sandbox still rides (defensive)" do
      args = ClaudeChat.cloud_build_args("plan", %{workspace_id: "ws-42"})

      refute "--session-id" in args
      refute "--resume" in args
      assert "--keep-sandbox" in args
      refute "--sandbox-id" in args
      assert_w12_belt_intact(args)
    end

    test ":cloud DROPS the permission-prompt bridge and ALL mcp args (D109)" do
      args =
        ClaudeChat.cloud_build_args("plan", %{
          workspace_id: "ws-1",
          mcp_config_path: "/host/mcp.json"
        })

      refute "--permission-prompt-tool" in args
      refute "stdio" in args
      refute "--mcp-config" in args
      refute "--strict-mcp-config" in args
      refute "/host/mcp.json" in args
    end

    test ":cloud NEVER emits a bypass flag — not even for an ARMED bypassPermissions (structural, D109/D24)" do
      for opts <- [
            %{workspace_id: "ws-1"},
            %{workspace_id: "ws-1", bypass_armed: true},
            %{workspace_id: "ws-1", bypass_armed: true, session_id: "s-1"}
          ] do
        args = ClaudeChat.cloud_build_args("bypassPermissions", opts)
        refute "--allow-dangerously-skip-permissions" in args
        refute "--dangerously-skip-permissions" in args
      end
    end

    test ":cloud HARD-FAILS on a nil/:global/blank workspace_id — never an unattributed turn (D110)" do
      assert_raise ArgumentError, ~r/workspace_id/, fn ->
        ClaudeChat.cloud_build_args("plan", %{})
      end

      for bad <- [nil, "", "global"] do
        assert_raise ArgumentError, ~r/workspace_id/, fn ->
          ClaudeChat.cloud_build_args("plan", %{workspace_id: bad})
        end
      end
    end

    test ":cloud command/2 refuses to assemble an argv without a workspace principal" do
      put_chat_config(execution_profile: :cloud)

      assert_raise ArgumentError, ~r/workspace_id/, fn ->
        ClaudeChat.command("plan", %{})
      end
    end
  end

  # The D24 permission reversal at the ARGV layer (D116/D117): the :cloud argv
  # clamps the mode and carries CloudPolicy's three tool-removal belts. Every
  # assertion pins what the launch contract REQUESTS — the live host-denial
  # observation rides `connectors-hg-live-isolated-cloud-turn`, never faked here.
  describe "cloud policy belts — CloudPolicy on the :cloud argv (connectors D116/D117)" do
    alias Barkpark.Connectors.CloudPolicy

    # The variadic `--disallowedTools` list is emitted LAST, so everything after
    # the flag is the deny set (unambiguous argv boundary).
    defp cloud_disallowed_argv(args) do
      args |> Enum.drop_while(&(&1 != "--disallowedTools")) |> Enum.drop(1)
    end

    defp settings_deny_from_argv(args) do
      idx = Enum.find_index(args, &(&1 == "--settings"))
      json = Enum.at(args, idx + 1)
      Jason.decode!(json)["permissions"]["deny"]
    end

    test "knob 2a — `--tools \"\"` removes ALL built-in tools" do
      args = ClaudeChat.cloud_build_args("plan", %{workspace_id: "ws-1"})
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--tools", ""])
    end

    test "knob 2b — `--disallowedTools` carries the full host-FS/exec/network deny set" do
      args = ClaudeChat.cloud_build_args("plan", %{workspace_id: "ws-1"})

      assert cloud_disallowed_argv(args) == CloudPolicy.cloud_disallowed_tools()

      # The concrete built-ins that must never reach a Cloud turn.
      for tool <- ~w(Bash Edit Write Read NotebookEdit WebFetch WebSearch Task) do
        assert tool in cloud_disallowed_argv(args), "#{tool} must be denied on the cloud argv"
      end
    end

    test "knob 2c — `--settings` is a deny JSON STRING, decoding to the deny list" do
      args = ClaudeChat.cloud_build_args("plan", %{workspace_id: "ws-1"})

      assert Enum.chunk_every(args, 2, 1)
             |> Enum.member?(["--settings", CloudPolicy.settings_deny_json()])

      assert settings_deny_from_argv(args) == CloudPolicy.cloud_disallowed_tools()
    end

    test "NO-DRIFT — the argv `--disallowedTools` list equals the `--settings` deny list" do
      args = ClaudeChat.cloud_build_args("plan", %{workspace_id: "ws-1"})

      # The two belts are built from the SAME source; if a future edit forks one,
      # this reds before the divergence can ship.
      assert cloud_disallowed_argv(args) == settings_deny_from_argv(args)
    end

    test "knob 1 — a bypassPermissions mode CLAMPS to plan on the cloud argv" do
      args = ClaudeChat.cloud_build_args("bypassPermissions", %{workspace_id: "ws-1"})
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--permission-mode", "plan"])

      refute Enum.chunk_every(args, 2, 1)
             |> Enum.member?(["--permission-mode", "bypassPermissions"])
    end

    test "knob 1 — an unknown/garbage mode CLAMPS to plan on the cloud argv" do
      for bad <- ["nonsense", "", "DROP TABLE", "default"] do
        args = ClaudeChat.cloud_build_args(bad, %{workspace_id: "ws-1"})

        assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--permission-mode", "plan"]),
               "mode #{inspect(bad)} must clamp to plan"
      end
    end

    test "knob 1 — a Cloud-valid mode passes through verbatim (clamp is validity, not force-plan)" do
      for mode <- CloudPolicy.cloud_modes() do
        args = ClaudeChat.cloud_build_args(mode, %{workspace_id: "ws-1"})
        assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--permission-mode", mode])
      end
    end

    test "bypass is STILL structurally unreachable through the clamp (extends the W11 down-payment)" do
      for mode <- ["bypassPermissions", "plan", "acceptEdits"],
          opts <- [%{workspace_id: "ws-1"}, %{workspace_id: "ws-1", bypass_armed: true}] do
        args = ClaudeChat.cloud_build_args(mode, opts)
        refute "--allow-dangerously-skip-permissions" in args
        refute "--dangerously-skip-permissions" in args
      end
    end

    test "self-hosted argv NEVER carries the cloud belts (byte-identical host path)" do
      # The cloud belts live only on the cloud path; the host build_args is
      # untouched (the D107 byte-identical guarantee).
      host = ClaudeChat.build_args("plan", %{})
      refute "--tools" in host
      refute "--settings" in host
      # The host path's only --disallowedTools is the plan-mode Workflow road-block
      # (a single token), never the cloud deny set.
      refute "Bash" in host
    end
  end

  # The knob-3 CONFIG half at the ARGV layer (connectors D126/D127/D128/D130):
  # with ≥1 tool-direction install, `cloud_build_args/2` emits ONE
  # `--mcp-config-b64` pair BEFORE `--` whose decode is EXACTLY the workspace's
  # connector HTTP servers. REAL installs (raw SQL — the bridge's writer, D54) +
  # INJECTED bridge descriptors (no live bridge). The W12 deny belt is re-asserted
  # intact in every row — knob 3 ADDS connector tools, never re-opens host reach.
  describe "cloud mcp-config wiring — knob 3 CONFIG half (connectors D126/D127/D128/D130)" do
    alias Barkpark.Connectors.CloudPolicy

    setup do
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Barkpark.Repo, shared: true)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
      ws = Barkpark.TenancyFixtures.create_workspace!("cloud-mcp-argv-ws")
      {:ok, ws: ws}
    end

    # The bridge is production's only writer; tests write raw SQL (D54).
    defp insert_install(provider, key, ws_id) do
      Barkpark.Repo.query!(
        """
        INSERT INTO chat_bridge.connector_installs
          (provider, install_key, workspace_id, credential_ref, chat_token_ref, created_at)
        VALUES ($1, $2, $3, $4, $5, now())
        """,
        [provider, key, ws_id, "SEALED-CREDENTIAL-BLOB", "SEALED-CHAT-TOKEN-BLOB"]
      )
    end

    # A bridge descriptor as fetch_tool_descriptors/1 returns it — WITH a
    # headersHelper the cloud emission must STRIP (host-loopback curl is dead
    # across the Firecracker boundary — D126).
    defp tool_descriptor(provider, url) do
      %{
        "provider" => provider,
        "type" => "http",
        "url" => url,
        "headersHelper" => "curl -sS http://127.0.0.1:4020/connectors/tool-headers/#{provider}"
      }
    end

    # `--mcp-config-b64` rides BEFORE the `--` separator (shim-own); assert that,
    # then decode the base64 payload to the mcpServers document.
    defp mcp_flag_value(args) do
      sep = Enum.find_index(args, &(&1 == "--"))
      idx = Enum.find_index(args, &(&1 == "--mcp-config-b64"))
      assert is_integer(idx) and idx < sep, "--mcp-config-b64 must ride pre-`--`"
      args |> Enum.at(idx + 1) |> Base.decode64!() |> Jason.decode!()
    end

    defp assert_w12_belt_intact(args) do
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--tools", ""])

      disallowed = args |> Enum.drop_while(&(&1 != "--disallowedTools")) |> Enum.drop(1)
      assert disallowed == CloudPolicy.cloud_disallowed_tools()

      settings_idx = Enum.find_index(args, &(&1 == "--settings"))

      deny =
        args |> Enum.at(settings_idx + 1) |> Jason.decode!() |> get_in(["permissions", "deny"])

      assert deny == CloudPolicy.cloud_disallowed_tools()
    end

    # The Elixir argv NEVER carries the shim-owned host-path mcp flags (D127) —
    # even when it emits the b64 config, --mcp-config/--strict-mcp-config are the
    # shim's job in-VM.
    defp assert_no_host_mcp_path(args) do
      refute "--mcp-config" in args
      refute "--strict-mcp-config" in args
    end

    # The `--egress-host` values that ride pre-`--` (shim-own, knob 6 D238/D240 —
    # W29): each host is its OWN repeated pair, NEVER comma-joined. Returned in
    # argv order (the derivation is sorted+unique at the CloudPolicy layer).
    defp egress_hosts(args) do
      sep = Enum.find_index(args, &(&1 == "--"))

      args
      |> Enum.take(sep)
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [flag, _] -> flag == "--egress-host" end)
      |> Enum.map(fn [_, host] -> host end)
    end

    test "1 tool install — exactly that provider's HTTP server, headersHelper stripped, belt intact",
         %{ws: ws} do
      insert_install("github", "octocat/repo", ws.id)

      # A github descriptor (installed) AND a linear descriptor (NOT installed for
      # this ws): only github survives the install cross-check.
      descriptors = [
        tool_descriptor("github", "https://api.githubcopilot.com/mcp/"),
        tool_descriptor("linear", "https://mcp.linear.app/mcp")
      ]

      args =
        ClaudeChat.cloud_build_args("plan", %{workspace_id: ws.id, tool_descriptors: descriptors})

      assert mcp_flag_value(args) == %{
               "mcpServers" => %{
                 "github" => %{"type" => "http", "url" => "https://api.githubcopilot.com/mcp/"}
               }
             }

      # W29 (D237/D238): the egress allowlist is the SAME survivor set — exactly
      # github's host, never the non-installed linear's.
      assert egress_hosts(args) == ["api.githubcopilot.com"]
      refute "mcp.linear.app" in args

      assert_w12_belt_intact(args)
      assert_no_host_mcp_path(args)
    end

    test "2 tool installs (github + linear) — both HTTP servers, nothing else, belt intact",
         %{ws: ws} do
      insert_install("github", "octocat/repo", ws.id)
      insert_install("linear", "team-x", ws.id)

      descriptors = [
        tool_descriptor("github", "https://api.githubcopilot.com/mcp/"),
        tool_descriptor("linear", "https://mcp.linear.app/mcp")
      ]

      args =
        ClaudeChat.cloud_build_args("plan", %{workspace_id: ws.id, tool_descriptors: descriptors})

      assert mcp_flag_value(args) == %{
               "mcpServers" => %{
                 "github" => %{"type" => "http", "url" => "https://api.githubcopilot.com/mcp/"},
                 "linear" => %{"type" => "http", "url" => "https://mcp.linear.app/mcp"}
               }
             }

      # W29 (D237/D238): both installed connectors' declared hosts, SORTED UNIQUE,
      # as SEPARATE repeated --egress-host pairs (never comma-joined).
      assert egress_hosts(args) == ["api.githubcopilot.com", "mcp.linear.app"]
      assert Enum.count(args, &(&1 == "--egress-host")) == 2
      refute "api.githubcopilot.com,mcp.linear.app" in args
      refute "api.anthropic.com" in args

      # Every --egress-host rides pre-`--` (shim-own, not a claude flag).
      sep = Enum.find_index(args, &(&1 == "--"))

      for {flag, i} <- Enum.with_index(args), flag == "--egress-host" do
        assert i < sep, "--egress-host must ride pre-`--`"
      end

      assert_w12_belt_intact(args)
      assert_no_host_mcp_path(args)
    end

    test "a channel install never yields a tool server (github descriptor, telegram install)",
         %{ws: ws} do
      insert_install("telegram", "111:aaa", ws.id)

      # A github descriptor is injected but github has NO install for this ws ⇒
      # dropped ⇒ 0 servers ⇒ argv byte-identical to W12 (no flag).
      descriptors = [tool_descriptor("github", "https://api.githubcopilot.com/mcp/")]

      args =
        ClaudeChat.cloud_build_args("plan", %{workspace_id: ws.id, tool_descriptors: descriptors})

      refute "--mcp-config-b64" in args
      # No mcp flag, no session_id ⇒ the only pre-`--` addition is the ALWAYS-ON
      # --keep-sandbox (W14 D137). No binding ⇒ no --sandbox-id.
      assert Enum.take(args, 4) == ["--workspace", ws.id, "--keep-sandbox", "--"]
      refute "--sandbox-id" in args
      # W29 (D237): 0 surviving servers ⇒ NO egress widening — the deny-all wall is
      # preserved (a non-installed github descriptor never opens github's host).
      refute "--egress-host" in args
      assert egress_hosts(args) == []
    end
  end

  describe "cloud runtime wiring (connectors D110 — recorder→session_opts principal)" do
    test "Runtime.Claude threads workspace_id into the cloud shim argv (today dropped)" do
      argv_file = capture_path("argv")
      put_chat_config(execution_profile: :cloud, sandbox_runner: argv_echo_binary(argv_file))

      {:ok, session} =
        Barkpark.StudioChat.Runtime.Claude.start(%{
          sink: self(),
          workspace_id: "ws-threaded-99",
          session_opts: %{}
        })

      argv = read_lines(argv_file)
      assert Enum.chunk_every(argv, 2, 1) |> Enum.member?(["--workspace", "ws-threaded-99"])

      ClaudeChat.close(session)
    end

    test "Runtime.Claude refuses a cloud spawn that carries no workspace principal (fail-closed)" do
      put_chat_config(execution_profile: :cloud, sandbox_runner: "cloud-sandbox-runner")

      assert {:error, _reason} =
               Barkpark.StudioChat.Runtime.Claude.start(%{sink: self(), session_opts: %{}})
    end
  end

  # D123: the two production entry points (chat_live.ex, chat_controller.ex)
  # thread `workspace_id` correctly, but NO existing D110 test crosses
  # `Recorder.ensure` — the actual server-owned spawn path. This closes that gap:
  # a `:cloud` turn with a nil workspace must fail CLOSED all the way through the
  # real Session pipeline, and the SAME path WITH a workspace must spawn (so the
  # refusal is the workspace gate, not a broken harness). Needs live Postgres —
  # Recorder.init reads CycleFleet + acquires admission before the spawn.
  describe "Recorder-level cloud fail-close (connectors D123)" do
    alias Barkpark.StudioChat.Recorder

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Barkpark.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, {:shared, self()})
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, :manual) end)
      :ok
    end

    test ":cloud + a nil workspace fails CLOSED through Recorder.ensure — no spawn, no live recorder" do
      # A shim that WOULD record its argv if it ever launched — it must not.
      never = capture_path("never")
      put_chat_config(execution_profile: :cloud, sandbox_runner: argv_echo_binary(never))
      sid = Ecto.UUID.generate()

      assert {:error, _reason} =
               Recorder.ensure(%{session_id: sid, mode: "plan", execution_target: "managed"})

      # NON-VACUITY: were the workspace gate broken, cloud_build_args would return
      # an argv, the shim WOULD spawn, `ensure` would return `{:ok, pid}`, and the
      # argv-echo shim would have written `never`. All three refute a spawn:
      assert Recorder.whereis(sid) == nil
      refute File.exists?(never)
    end
  end

  describe "cloud turn end-to-end — fake shim through the real pipeline (connectors D113b)" do
    test "a bogus-key result frame reaches the sink via the SAME parse_chunk pipeline and classifies as an auth failure" do
      put_chat_config(execution_profile: :cloud, sandbox_runner: bogus_key_shim())

      {:ok, session} =
        ClaudeChat.start_session(%{sink: self(), session_opts: %{workspace_id: "ws-7"}})

      assert_receive {:claude_chat_event, %{"type" => "result"} = frame}, 2_000
      assert frame["is_error"] == true
      assert frame["api_error_status"] == 401
      assert frame["result"] =~ "Invalid API key"
      # The non-vacuous bar: the frame the runtime auth guard actually reads.
      assert ClaudeChat.auth_failure?(frame)
      refute ClaudeChat.result_success?(frame)

      ClaudeChat.close(session)
    end
  end

  # A chmod +x fake `cloud-sandbox-runner` that emits the canned bogus-key result
  # frame (non-volatile fields byte-matched to unauthed_stream.ndjson) then `cat`s
  # to keep the Port alive. Stands in for the real shim's terminal frame WITHOUT a
  # live Vercel Sandbox — the live sandbox proof is the committed harness
  # (w11-isolated-turn-proof.sh) and the human gate.
  defp bogus_key_shim do
    frame =
      ~s({"type":"result","subtype":"success","is_error":true,"api_error_status":401,) <>
        ~s("result":"Invalid API key","terminal_reason":"api_error"})

    path =
      Path.join(System.tmp_dir!(), "cloud_shim_#{System.unique_integer([:positive])}.sh")

    File.write!(path, "#!/bin/sh\nprintf '%s\\n' '#{frame}'\ncat\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  # The spawn-env seam (chat-task-hands charter D1/D3): the child gets bp
  # credentials injected and the BEAM's prod secrets SCRUBBED. Before this seam
  # the child inherited the FULL server env — DATABASE_URL, SECRET_KEY_BASE,
  # BARKPARK_KEK, every token (live-proven leak). OTP :env semantics (proven
  # 26–28): the list MERGES into the inherited env, `{~c"NAME", false}` unsets,
  # and both tuple sides must be charlists. The `:command` override is safe
  # here (unlike argv assertions): env: rides Port.open regardless of how the
  # command tuple was produced.
  describe "spawn env (charter D1/D3 — bp credentials in, prod secrets out)" do
    @sid "3f9a1c2e-0b7d-4a11-9c33-77e6a2b4d501"

    test "spawn_env/2 injects the three bp vars and unsets every scrubbed secret, charlists both sides" do
      env = ClaudeChat.spawn_env("bpcs_secret", "claude-chat-3f9a1c2e")

      assert {~c"BARKPARK_API_URL", String.to_charlist(ClaudeChat.mcp_api_url())} in env
      assert {~c"BARKPARK_API_TOKEN", ~c"bpcs_secret"} in env
      assert {~c"BARKPARK_WORKER_ID", ~c"claude-chat-3f9a1c2e"} in env

      for name <- ClaudeChat.scrubbed_env_names() do
        assert {String.to_charlist(name), false} in env, "#{name} must be unset"
      end

      # Every tuple side is a charlist (or the unset `false`) — a binary on
      # either side is an ArgumentError crash at Port.open.
      for {k, v} <- env do
        assert is_list(k)
        assert v == false or is_list(v)
      end
    end

    test "the denylist covers the live-proven leak set; HOME/PATH are never scrubbed" do
      scrubbed = ClaudeChat.scrubbed_env_names()

      # The leak the wave verified live, plus the two mandated extras.
      for name <- ~w(DATABASE_URL SECRET_KEY_BASE BARKPARK_KEK BARKPARK_CLOAK_KEY
                     SMTP_PASSWORD PREVIEW_JWT_SECRET MEDIA_SIGNING_SECRET
                     BOKBASEN_CLIENT_SECRET HETZNER_API_TOKEN
                     RELEASE_COOKIE BARKPARK_TOKEN) do
        assert name in scrubbed, "#{name} missing from the scrub denylist"
      end

      # The merge keeps everything unlisted — claude's OAuth lives under $HOME.
      refute "HOME" in scrubbed
      refute "PATH" in scrubbed
    end

    test "the denylist tracks secret-shaped env reads in runtime.exs" do
      runtime =
        "../../../config/runtime.exs"
        |> Path.expand(__DIR__)
        |> File.read!()

      runtime_secrets =
        ~r/System\.(?:get_env|fetch_env!?)\(\s*"([A-Z][A-Z0-9_]*)"/
        |> Regex.scan(runtime, capture: :all_but_first)
        |> List.flatten()
        |> Enum.filter(fn name ->
          name == "DATABASE_URL" or
            Regex.match?(~r/(?:^|_)(?:TOKEN|SECRET|PASSWORD|KEY|COOKIE)$/, name)
        end)
        |> Enum.uniq()
        |> Enum.sort()

      missing = runtime_secrets -- ClaudeChat.scrubbed_env_names()

      assert missing == [],
             "secret-shaped runtime env reads missing from ClaudeChat.scrubbed_env_names/0: #{inspect(missing)}"

      refute "HOME" in ClaudeChat.scrubbed_env_names()
      refute "PATH" in ClaudeChat.scrubbed_env_names()
    end

    test "the denylist covers every secret-shaped env read in api/lib (scrub-OR-allowlisted)" do
      # Widen the runtime.exs-only audit to the whole app tree (charter D173):
      # any `System.get_env/fetch_env!` of a secret-shaped name in api/lib must
      # be EITHER scrubbed from the chat child OR on the intentional-passthrough
      # allowlist. A read that is neither reds here, forcing a conscious
      # scrub-or-allowlist decision before it can ship.
      lib_root = Path.expand("../../../lib", __DIR__)

      # Secret-shape: the terminal token before the closing quote is one of
      # TOKEN|SECRET|PASSWORD|KEY|COOKIE (anchored on `_` or start), or the
      # bare DATABASE_URL. Anchoring on the terminal correctly EXCLUDES
      # PUBLIC_READ_TOKEN_FILE (…_FILE) and BARKPARK_HOME (…_HOME).
      read_re = ~r/System\.(?:get_env|fetch_env!?)\(\s*"([A-Z][A-Z0-9_]*)"/
      secret_re = ~r/(?:^|_)(?:TOKEN|SECRET|PASSWORD|KEY|COOKIE)$/

      lib_secrets =
        (lib_root <> "/**/*.ex")
        |> Path.wildcard()
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> then(&Regex.scan(read_re, &1, capture: :all_but_first))
          |> List.flatten()
        end)
        |> Enum.filter(fn name ->
          name == "DATABASE_URL" or Regex.match?(secret_re, name)
        end)
        |> Enum.uniq()
        |> Enum.sort()

      # Sanity: the scan is finding real reads, not silently matching nothing.
      assert lib_secrets != [],
             "the api/lib secret-read scan matched nothing — the regex or path is broken"

      covered = ClaudeChat.scrubbed_env_names() ++ ClaudeChat.intentional_env_passthrough_names()
      uncovered = lib_secrets -- covered

      assert uncovered == [],
             "secret-shaped env reads in api/lib that are neither scrubbed nor " <>
               "allowlisted (add to @scrubbed_env, or to @intentional_env_passthrough " <>
               "with a rationale): #{inspect(uncovered)}"

      # The allowlist is the deliberate exception — it must never leak HOME/PATH
      # or accidentally swallow the whole denylist into a passthrough.
      refute "HOME" in ClaudeChat.intentional_env_passthrough_names()
      refute "PATH" in ClaudeChat.intentional_env_passthrough_names()
    end

    test "worker_id/1 is claude-chat-<sid8> (cmux precedent — one worker per chat tab)" do
      assert ClaudeChat.worker_id(@sid) == "claude-chat-3f9a1c2e"
      assert ClaudeChat.worker_id(@sid) =~ ~r/^claude-chat-[0-9a-f]{8}$/
      # anonymous sessions degrade to the shared anon worker, never crash
      assert ClaudeChat.worker_id(nil) == "claude-chat-anon"
      assert ClaudeChat.worker_id("") == "claude-chat-anon"
    end

    test "the child's REAL env: injected vars present, a seeded secret absent, HOME survives" do
      file = capture_path("env")
      secret = "leak-me-#{System.unique_integer([:positive])}"
      System.put_env("BARKPARK_KEK", secret)
      on_exit(fn -> System.delete_env("BARKPARK_KEK") end)

      put_chat_config(command: env_dump_command(file))

      {:ok, session} =
        ClaudeChat.start_session(%{sink: self(), session_opts: %{session_id: @sid}})

      env = read_child_env(file)

      assert env["BARKPARK_API_URL"] == ClaudeChat.mcp_api_url()
      # No minter on this session ⇒ the poison sentinel — NEVER absence: bp's
      # precedence would otherwise fall through to the host's persisted
      # (possibly admin) credentials. The URL stays THIS server, so calls 401
      # here instead of resolving elsewhere.
      assert env["BARKPARK_API_TOKEN"] == ClaudeChat.mint_refused_sentinel()
      assert env["BARKPARK_WORKER_ID"] == "claude-chat-3f9a1c2e"

      # The seeded BEAM secret must NOT reach the child…
      refute Map.has_key?(env, "BARKPARK_KEK")
      # …while the untouched inherited env survives the merge.
      assert Map.has_key?(env, "HOME")
      assert Map.has_key?(env, "PATH")

      # @sid is SHARED with the next test in this describe. `close/1` is a
      # cast, so returning while teardown still holds the registry name hands
      # the next `start_session` an `{:already_started, pid}`.
      close_and_reap(session, @sid)
    end

    test "task_hands/1 is :not_attempted without a minter, :unknown once the session is gone" do
      put_chat_config(command: {"cat", []})

      {:ok, session} =
        ClaudeChat.start_session(%{sink: self(), session_opts: %{session_id: @sid}})

      assert ClaudeChat.task_hands(session) == :not_attempted

      close_and_reap(session, @sid)

      assert ClaudeChat.task_hands(session) == :unknown
    end
  end

  # The mint→env link, end-to-end with a REAL mint (charter D1 — ONE minted
  # bpcs_ token feeds BOTH consumers: the spawn env and the mcp-config file).
  # DB-backed: a shared sandbox owner covers the Session GenServer's own
  # process (this file is async: false).
  describe "spawn env with a real mint (charter D1 — one mint, two consumers)" do
    setup do
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Barkpark.Repo, shared: true)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

      ws = Barkpark.TenancyFixtures.create_workspace!("chat-spawn-env-ws")

      {:ok, minter} =
        Barkpark.Auth.create_token(
          "spawn-env-minter-#{System.unique_integer([:positive])}",
          "chat admin",
          "production",
          ["read", "write"],
          ws.id
        )

      %{ws: ws, minter: minter}
    end

    test "the ONE minted bpcs_ token reaches the child env AND the mcp-config", %{minter: minter} do
      file = capture_path("env")
      put_chat_config(command: env_dump_command(file))
      uuid = Ecto.UUID.generate()

      {:ok, session} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{session_id: uuid, minter: minter}
        })

      env = read_child_env(file)
      token = env["BARKPARK_API_TOKEN"]
      assert is_binary(token) and String.starts_with?(token, "bpcs_")
      assert env["BARKPARK_API_URL"] == ClaudeChat.mcp_api_url()
      assert env["BARKPARK_WORKER_ID"] == "claude-chat-" <> String.slice(uuid, 0, 8)

      # The SAME mint feeds the mcp-config env block — one mint, two consumers.
      config_path = Path.join(System.tmp_dir!(), "barkpark-claude-#{uuid}.mcp.json")
      config = config_path |> File.read!() |> Jason.decode!()

      assert get_in(config, ["mcpServers", "barkpark", "env", "BARKPARK_API_TOKEN"]) == token

      assert ClaudeChat.task_hands(session) == :minted

      ref = Process.monitor(session)
      ClaudeChat.close(session)
      assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000
    end

    test "a connected TOOL connector folds a SECOND mcpServers key into the ON-DISK config (D69)",
         %{minter: minter, ws: ws} do
      # A configured connect seam + a stub bridge that answers ONLY a real
      # tool-session ticket for THIS workspace (see ToolBridgeStub). No Node.
      put_connectors_config(connect_secret: "tool-seam-test-secret", bridge: ToolBridgeStub)
      Application.put_env(:barkpark, :tool_stub_ws, ws.id)
      on_exit(fn -> Application.delete_env(:barkpark, :tool_stub_ws) end)

      file = capture_path("env")
      put_chat_config(command: env_dump_command(file))
      uuid = Ecto.UUID.generate()

      {:ok, session} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{session_id: uuid, minter: minter}
        })

      # Wait for the child to boot (the env dump lands), then read the config file.
      _env = read_child_env(file)
      config_path = Path.join(System.tmp_dir!(), "barkpark-claude-#{uuid}.mcp.json")
      servers = config_path |> File.read!() |> Jason.decode!() |> Map.fetch!("mcpServers")

      # The loopback server still carries the minted token …
      assert servers["barkpark"]["env"]["BARKPARK_API_TOKEN"] |> String.starts_with?("bpcs_")

      # … AND github landed as a SECOND server, DERIVED from the bridge descriptor.
      # This only happens if setup_mcp signed a REAL tool-session ticket bound to
      # THIS workspace — the stub returns [] otherwise (non-vacuous, D69/D38).
      assert servers["github"]["type"] == "http"
      assert servers["github"]["url"] == "https://api.githubcopilot.com/mcp/"
      assert servers["github"]["headersHelper"] =~ "/connect/tool-headers/github"

      ref = Process.monitor(session)
      ClaudeChat.close(session)
      assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000
    end

    test "no connect seam ⇒ NO tool servers, config unchanged (fail-soft, D69)", %{minter: minter} do
      # The default instance: connect_secret nil. sign_tool short-circuits BEFORE
      # any bridge call, so the config is byte-identical to the pre-wave shape.
      file = capture_path("env")
      put_chat_config(command: env_dump_command(file))
      uuid = Ecto.UUID.generate()

      {:ok, session} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{session_id: uuid, minter: minter}
        })

      _env = read_child_env(file)
      config_path = Path.join(System.tmp_dir!(), "barkpark-claude-#{uuid}.mcp.json")
      servers = config_path |> File.read!() |> Jason.decode!() |> Map.fetch!("mcpServers")

      assert Map.keys(servers) == ["barkpark"]

      ref = Process.monitor(session)
      ClaudeChat.close(session)
      assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000
    end

    test "a failed mcp-config write keeps ENV hands — same token, MCP lane lost", %{
      minter: minter
    } do
      file = capture_path("env")
      put_chat_config(command: env_dump_command(file))
      uuid = Ecto.UUID.generate()

      # A DIRECTORY squatting on the config path forces File.write to fail
      # ({:error, :eisdir}) — the env injection must still carry the REAL token.
      config_path = Path.join(System.tmp_dir!(), "barkpark-claude-#{uuid}.mcp.json")
      File.mkdir_p!(config_path)
      on_exit(fn -> File.rm_rf(config_path) end)

      {:ok, session} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{session_id: uuid, minter: minter}
        })

      env = read_child_env(file)
      assert is_binary(env["BARKPARK_API_TOKEN"])
      assert String.starts_with?(env["BARKPARK_API_TOKEN"], "bpcs_")
      assert ClaudeChat.task_hands(session) == :minted

      ref = Process.monitor(session)
      ClaudeChat.close(session)
      assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000
    end

    test "a REFUSED mint poisons the child env with the sentinel and reports :mint_refused", %{
      ws: ws
    } do
      # A read-only member fails the up-front :write authorize — the proven
      # refusal path (auth_session_token_test), exercised end-to-end here.
      {:ok, reader} =
        Barkpark.Auth.create_token(
          "spawn-env-reader-#{System.unique_integer([:positive])}",
          "read-only member",
          "production",
          ["read"],
          ws.id
        )

      file = capture_path("env")
      put_chat_config(command: env_dump_command(file))
      uuid = Ecto.UUID.generate()

      {:ok, session} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{session_id: uuid, minter: reader}
        })

      env = read_child_env(file)
      # Poison, never absence — and the URL still points HERE, so the child's
      # bp 401s against THIS server instead of resolving somewhere else.
      assert env["BARKPARK_API_TOKEN"] == ClaudeChat.mint_refused_sentinel()
      assert env["BARKPARK_API_URL"] == ClaudeChat.mcp_api_url()

      assert ClaudeChat.task_hands(session) == :mint_refused

      # No config file was written (nothing to leak, no --mcp-config lane).
      refute File.exists?(Path.join(System.tmp_dir!(), "barkpark-claude-#{uuid}.mcp.json"))

      ref = Process.monitor(session)
      ClaudeChat.close(session)
      assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000
    end
  end

  # Outbound control frames (charter D10/D12), wire-proven against the real
  # binary 2026-07-09. These tests capture the EXACT bytes we write to stdin (a
  # `head -n 1` fake drains the first frame to a file). They prove the frame is
  # WRITTEN CORRECTLY — NOT that `--print` honors it: the real-binary harness
  # proved honoring (interrupt → ack + result terminal_reason
  # "aborted_streaming" + session survives; set_permission_mode → response
  # echoes {"mode": …}). Loopback-via-`cat` would NOT work here: our own
  # dispatch auto-answers any inbound control_request, mangling the echo — so we
  # capture the raw stdin bytes instead.
  describe "outbound control frames (write path)" do
    test "interrupt/1 writes a control_request with subtype 'interrupt'" do
      file = capture_path("frame")
      put_chat_config(command: frame_capture_command(file))

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      {:ok, request_id} = ClaudeChat.interrupt(session)

      frame = read_frame(file)
      assert frame["type"] == "control_request"
      assert frame["request"]["subtype"] == "interrupt"
      assert frame["request_id"] == request_id

      ClaudeChat.close(session)
    end

    test "set_permission_mode/2 writes subtype 'set_permission_mode' with the literal key 'mode'" do
      file = capture_path("frame")
      put_chat_config(command: frame_capture_command(file))

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      {:ok, request_id} = ClaudeChat.set_permission_mode(session, "acceptEdits")

      frame = read_frame(file)
      assert frame["request"]["subtype"] == "set_permission_mode"
      # The real binary silently no-ops the alt key 'permission_mode'; assert
      # the literal 'mode' key is what we wrote, and nothing else.
      assert Map.fetch(frame["request"], "mode") == {:ok, "acceptEdits"}
      refute Map.has_key?(frame["request"], "permission_mode")
      assert frame["request_id"] == request_id

      ClaudeChat.close(session)
    end

    test "set_model/2 writes subtype 'set_model' with the model" do
      file = capture_path("frame")
      put_chat_config(command: frame_capture_command(file))

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      {:ok, request_id} = ClaudeChat.set_model(session, "claude-sonnet-4-5")

      frame = read_frame(file)
      assert frame["request"]["subtype"] == "set_model"
      assert frame["request"]["model"] == "claude-sonnet-4-5"
      assert frame["request_id"] == request_id

      ClaudeChat.close(session)
    end

    test "initialize/1 writes a control_request with subtype 'initialize' (charter D36a)" do
      file = capture_path("frame")
      put_chat_config(command: frame_capture_command(file))

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      {:ok, request_id} = ClaudeChat.initialize(session)

      frame = read_frame(file)
      assert frame["type"] == "control_request"
      assert frame["request"]["subtype"] == "initialize"
      assert frame["request_id"] == request_id

      ClaudeChat.close(session)
    end

    test "each control frame mints a distinct request_id" do
      file = capture_path("frame")
      put_chat_config(command: frame_capture_command(file))

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      {:ok, id1} = ClaudeChat.interrupt(session)
      {:ok, id2} = ClaudeChat.interrupt(session)

      assert id1 != id2
      ClaudeChat.close(session)
    end

    test "inbound control_response acks reach the sink as chat events" do
      # A control_response the CLI would send to ack our control_request. It is
      # NOT a control_request, so it flows through the fallback dispatch to the
      # sink — this is how the LiveView matches acks by request_id.
      ack =
        ~s({"type":"control_response","response":{"subtype":"success","request_id":"bp-req-abc","response":{"mode":"acceptEdits"}}})

      script = ~s(printf '%s\\n' '#{ack}'; cat)
      put_chat_config(command: {"sh", ["-c", script]})

      {:ok, _session} = ClaudeChat.start_session(%{sink: self()})

      assert_receive {:claude_chat_event,
                      %{
                        "type" => "control_response",
                        "response" => %{
                          "subtype" => "success",
                          "request_id" => "bp-req-abc",
                          "response" => %{"mode" => "acceptEdits"}
                        }
                      }},
                     2_000
    end
  end

  # Typed control-response dispatch (charter D17/D23). A control_response whose
  # request_id matches one WE minted must reach the sink as a TYPED
  # {:claude_chat_control, kind, request_id, response} — not fall through the
  # generic dispatch into the ChatLive catch-all (which drops it). The dispatch
  # carries the request_id so the consumer can correlate the ack to the SPECIFIC
  # outbound request (latest-outstanding wins; a stale ack is ignored). The
  # reflector fake reads our outbound control_request, extracts its (randomly
  # minted) request_id, and echoes a control_response with that SAME id — the only
  # deterministic way to prove the request_id → kind map since we mint the id.
  describe "typed control-response dispatch (charter D17/D23)" do
    test "a set_permission_mode ack dispatches {:claude_chat_control, :set_mode, rid, echo}" do
      put_chat_config(command: {"sh", ["-c", mode_reflector()]})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      {:ok, rid} = ClaudeChat.set_permission_mode(session, "acceptEdits")

      # The ack carries OUR minted request_id back — that is the correlation key.
      assert_receive {:claude_chat_control, :set_mode, ^rid, %{"mode" => "acceptEdits"}}, 2_000
      ClaudeChat.close(session)
    end

    test "an interrupt ack dispatches {:claude_chat_control, :interrupt, rid, _}" do
      put_chat_config(command: {"sh", ["-c", mode_reflector()]})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      {:ok, rid} = ClaudeChat.interrupt(session)

      assert_receive {:claude_chat_control, :interrupt, ^rid, response}, 2_000
      assert is_map(response)
      ClaudeChat.close(session)
    end

    test "an initialize ack dispatches {:claude_chat_control, :initialize, rid, commands} (charter D36a)" do
      put_chat_config(command: {"sh", ["-c", commands_reflector()]})

      {:ok, session} = ClaudeChat.start_session(%{sink: self()})
      {:ok, rid} = ClaudeChat.initialize(session)

      assert_receive {:claude_chat_control, :initialize, ^rid, response}, 2_000
      assert [%{"name" => "compact"} | _] = response["commands"]
      ClaudeChat.close(session)
    end

    test "an UNTRACKED control_response (id we never sent) still flows as a plain event" do
      # request_id "bp-req-abc" was never minted by this session — it is not in
      # pending_controls, so it must degrade to the generic sink event (the
      # pre-D17 behavior for any ack the LiveView can't correlate).
      ack =
        ~s({"type":"control_response","response":{"subtype":"success","request_id":"bp-req-abc","response":{"mode":"acceptEdits"}}})

      script = ~s(printf '%s\\n' '#{ack}'; cat)
      put_chat_config(command: {"sh", ["-c", script]})

      {:ok, _session} = ClaudeChat.start_session(%{sink: self()})

      assert_receive {:claude_chat_event,
                      %{
                        "type" => "control_response",
                        "response" => %{"request_id" => "bp-req-abc"}
                      }},
                     2_000

      refute_receive {:claude_chat_control, _, _, _}, 200
    end
  end

  # Single-writer discipline (charter D20). A pinned/resumed session registers
  # under its minted uuid in Barkpark.StudioChat.SessionRegistry, so a SECOND
  # tab on the same session gets `{:already_started, pid}` and ADOPTS the running
  # process instead of spawning a second `claude --resume` writer on the CLI's
  # own transcript. adopt_sink swaps ownership: the old sink is detached, and the
  # session's lifetime follows the NEW sink.
  describe "single-writer registry + adopt_sink (charter D20)" do
    test "a pinned session registers — a second start on the same id is already_started" do
      put_chat_config(command: {"cat", []})
      uuid = Ecto.UUID.generate()

      {:ok, s1} = ClaudeChat.start_session(%{sink: self(), session_opts: %{session_id: uuid}})

      # NOT a new process: the registry returns the incumbent pid, so no second
      # writer is spawned against the same transcript.
      assert {:error, {:already_started, ^s1}} =
               ClaudeChat.start_session(%{sink: self(), session_opts: %{session_id: uuid}})

      ClaudeChat.close(s1)
    end

    test "a resume keys on the SAME uuid — it collides with a live pinned session" do
      put_chat_config(command: {"cat", []})
      uuid = Ecto.UUID.generate()

      {:ok, s1} = ClaudeChat.start_session(%{sink: self(), session_opts: %{session_id: uuid}})

      assert {:error, {:already_started, ^s1}} =
               ClaudeChat.start_session(%{
                 sink: self(),
                 session_opts: %{session_id: uuid, resume: true}
               })

      ClaudeChat.close(s1)
    end

    test "distinct session ids each start their own process" do
      put_chat_config(command: {"cat", []})

      {:ok, a} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{session_id: Ecto.UUID.generate()}
        })

      {:ok, b} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{session_id: Ecto.UUID.generate()}
        })

      assert a != b
      ClaudeChat.close(a)
      ClaudeChat.close(b)
    end

    test "anonymous sessions (no session id) stay unnamed — two coexist" do
      put_chat_config(command: {"cat", []})

      {:ok, a} = ClaudeChat.start_session(%{sink: self()})
      {:ok, b} = ClaudeChat.start_session(%{sink: self()})

      assert a != b
      ClaudeChat.close(a)
      ClaudeChat.close(b)
    end

    test "adopt_sink detaches the old sink and re-homes the session on the new one" do
      put_chat_config(command: {"cat", []})
      uuid = Ecto.UUID.generate()
      observer = self()

      old_sink = spawn_sink(observer, :old)
      new_sink = spawn_sink(observer, :new)

      {:ok, session} =
        ClaudeChat.start_session(%{sink: old_sink, session_opts: %{session_id: uuid}})

      ref = Process.monitor(session)

      ClaudeChat.adopt_sink(session, new_sink)

      # The old tab is told it lost ownership (→ honest banner in the LV).
      assert_receive {:old, {:claude_chat_detached}}, 2_000

      # Old sink death no longer stops the session — it was demonitored.
      Process.exit(old_sink, :kill)
      refute_receive {:DOWN, ^ref, :process, ^session, _}, 400

      # The session's lifetime now follows the NEW sink (single owner).
      Process.exit(new_sink, :kill)
      assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000
    end

    test "adopting into the same sink is a harmless no-op (no self-detach)" do
      put_chat_config(command: {"cat", []})
      uuid = Ecto.UUID.generate()

      {:ok, session} =
        ClaudeChat.start_session(%{sink: self(), session_opts: %{session_id: uuid}})

      ClaudeChat.adopt_sink(session, self())
      refute_receive {:claude_chat_detached}, 300

      ClaudeChat.close(session)
    end
  end

  # A bare receiver that forwards every message it gets to `observer`, tagged, so
  # a test can watch what each sink receives (detach notice, DOWN, …).
  defp spawn_sink(observer, tag) do
    spawn(fn -> sink_loop(observer, tag) end)
  end

  defp sink_loop(observer, tag) do
    receive do
      msg ->
        send(observer, {tag, msg})
        sink_loop(observer, tag)
    end
  end

  # --- capture helpers (argv echo + stdin frame capture) --------------------

  # Reads our first outbound control_request, extracts its minted request_id, and
  # echoes back a control_response carrying that id (subtype:success, mode echo).
  # `printf` before an external `cat` flushes the frame promptly (same proven
  # pattern the canned-event tests rely on).
  defp mode_reflector do
    """
    IFS= read -r line
    rid=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"mode":"acceptEdits"}}}\\n' "$rid"
    cat
    """
  end

  # Reads our outbound initialize control_request, extracts its minted
  # request_id, and echoes a control_response carrying a `commands` list keyed by
  # that id — the shape the real binary answers `initialize` with (charter D36a).
  defp commands_reflector do
    """
    IFS= read -r line
    rid=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
    printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"commands":[{"name":"compact","description":"Compact the conversation","argumentHint":null}]}}}\\n' "$rid"
    cat
    """
  end

  # Capture file names must be unique ACROSS `mix test` runs, not just within
  # one: `System.unique_integer/1` restarts every BEAM boot, and a fake command
  # can flush its capture file AFTER the owning test's on_exit rm_rf already ran
  # (the port outlives the test by a beat) — a later RUN that mints the same
  # small integer would then `read_frame` a STALE frame from a previous run and
  # fail on a request_id that nobody in this run minted. The OS pid pins the
  # name to this BEAM instance; rm_rf-before-use belts-and-suspenders it.
  defp capture_path(kind) do
    file =
      Path.join(
        System.tmp_dir!(),
        "claude_chat_#{kind}_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.rm_rf(file)
    on_exit(fn -> File.rm_rf(file) end)
    file
  end

  # A chmod +x fake `claude` binary that echoes its argv (one arg per line) to
  # `argv_file`, then `cat`s to keep stdin open so the Port stays alive.
  defp argv_echo_binary(argv_file) do
    path =
      Path.join(System.tmp_dir!(), "claude_echo_#{System.unique_integer([:positive])}.sh")

    File.write!(path, "#!/bin/sh\nprintf '%s\\n' \"$@\" > '#{argv_file}'\ncat\n")
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  # Close a PINNED session and wait until its registry name is actually FREE.
  #
  # `close/1` is a cast and `terminate/2` does real teardown work (Port.close,
  # child reap, capture + mcp-config cleanup), so a test that closes a pinned
  # session and returns immediately leaves the uuid registered in
  # Barkpark.StudioChat.SessionRegistry for as long as teardown takes — and the
  # NEXT test to pin the SAME uuid gets `{:error, {:already_started, pid}}`
  # (CI run 32627503939 red exactly this way on the @sid pair, this file's
  # env-dump test into task_hands). The DOWN alone is not the whole story:
  # Registry sweeps its entry AFTER the process dies, so poll the lookup until
  # it answers [].
  defp close_and_reap(session, sid) do
    ref = Process.monitor(session)
    ClaudeChat.close(session)
    assert_receive {:DOWN, ^ref, :process, ^session, _}, 5_000

    assert await_unregistered(sid, 200),
           "session #{sid} is DOWN but still registered — the registry sweep never freed the name"
  end

  # Bounded poll (10ms x rounds) for the registry entry's removal.
  defp await_unregistered(_sid, 0), do: false

  defp await_unregistered(sid, rounds) do
    if Registry.lookup(Barkpark.StudioChat.SessionRegistry, sid) == [] do
      true
    else
      Process.sleep(10)
      await_unregistered(sid, rounds - 1)
    end
  end

  # `head -n 1` drains exactly the first written frame to a file (flushing on
  # exit), then `cat` keeps the Port alive.
  defp frame_capture_command(file), do: {"sh", ["-c", "head -n 1 > '#{file}'; cat"]}

  # Dumps the child's REAL environment to `file` (write-then-rename so the
  # reader never sees a partial dump), then `cat` keeps the Port alive. This is
  # the one place the `:command` override is legitimate for spawn assertions:
  # env: rides Port.open regardless of how the command tuple was produced (the
  # vacuous-green law is about argv, which :command bypasses via build_args).
  defp env_dump_command(file),
    do: {"sh", ["-c", "env > '#{file}.tmp' && mv '#{file}.tmp' '#{file}'; cat"]}

  # The child env as a map. `parts: 2` keeps values containing `=` intact;
  # continuation lines of a rare multi-line value simply don't parse as pairs.
  defp read_child_env(file) do
    file
    |> wait_for_file()
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [k, v] -> Map.put(acc, k, v)
        _ -> acc
      end
    end)
  end

  defp read_lines(file), do: file |> wait_for_file() |> String.split("\n", trim: true)

  defp read_frame(file), do: file |> wait_for_file() |> String.trim() |> Jason.decode!()

  # 400 × 20ms = 8s ceiling: under full-suite load the OS can take well past the
  # old 3s to schedule the fake-binary shell and flush its first write (observed
  # as a "capture file never written" flake). The happy path still returns on
  # the first poll; only a genuinely-dead fake pays the ceiling.
  defp wait_for_file(file, tries \\ 400) do
    cond do
      File.exists?(file) and File.read!(file) != "" -> File.read!(file)
      tries <= 0 -> flunk("capture file never written: #{file}")
      true -> Process.sleep(20) && wait_for_file(file, tries - 1)
    end
  end

  describe "build_args/2 model choice (wave 5)" do
    test "a chosen model rides the spawn as --model" do
      args = ClaudeChat.build_args("plan", %{session_id: "u-1", model: "opus"})
      assert ["--model", "opus"] == Enum.slice(args, Enum.find_index(args, &(&1 == "--model")), 2)
      assert "--session-id" in args
    end

    test "a resume carries the model too" do
      args = ClaudeChat.build_args("plan", %{session_id: "u-1", resume: true, model: "sonnet"})
      assert "--resume" in args
      assert "--model" in args
    end

    test "absent or nil model emits NO --model flag" do
      refute "--model" in ClaudeChat.build_args("plan", %{session_id: "u-1"})
      refute "--model" in ClaudeChat.build_args("plan", %{session_id: "u-1", model: nil})
    end

    test "normalize_model fail-closes unknown strings to nil (never raw argv)" do
      assert ClaudeChat.normalize_model("opus") == "opus"
      assert ClaudeChat.normalize_model("fable") == "fable"
      assert ClaudeChat.normalize_model("gpt-4; rm -rf /") == nil
      assert ClaudeChat.normalize_model(nil) == nil
    end
  end

  describe "build_args/2 effort choice (wave 9, charter D48)" do
    test "a chosen effort tier rides the spawn as --effort" do
      args = ClaudeChat.build_args("plan", %{session_id: "u-1", effort: "high"})

      assert ["--effort", "high"] ==
               Enum.slice(args, Enum.find_index(args, &(&1 == "--effort")), 2)

      assert "--session-id" in args
    end

    test "a resume carries the effort too" do
      args = ClaudeChat.build_args("plan", %{session_id: "u-1", resume: true, effort: "xhigh"})
      assert "--resume" in args

      assert ["--effort", "xhigh"] ==
               Enum.slice(args, Enum.find_index(args, &(&1 == "--effort")), 2)
    end

    test "absent or nil effort emits NO --effort flag" do
      refute "--effort" in ClaudeChat.build_args("plan", %{session_id: "u-1"})
      refute "--effort" in ClaudeChat.build_args("plan", %{session_id: "u-1", effort: nil})
    end

    test "every allowlisted tier is accepted; junk omits the flag (fail-closed)" do
      for e <- ~w(low medium high xhigh max) do
        assert "--effort" in ClaudeChat.build_args("plan", %{effort: e})
      end

      refute "--effort" in ClaudeChat.build_args("plan", %{effort: "ultra"})
      refute "--effort" in ClaudeChat.build_args("plan", %{effort: "high; rm -rf /"})
    end

    test "normalize_effort fail-closes unknown strings to nil" do
      assert ClaudeChat.normalize_effort("high") == "high"
      assert ClaudeChat.normalize_effort("max") == "max"
      assert ClaudeChat.normalize_effort("ludicrous") == nil
      assert ClaudeChat.normalize_effort(nil) == nil
    end
  end

  describe "build_args/2 bypass arming (wave 9, charter D48 — the two-key gate)" do
    test "armed bypass emits BOTH --permission-mode bypassPermissions and the danger flag" do
      args = ClaudeChat.build_args("bypassPermissions", %{session_id: "u-1", bypass_armed: true})

      assert Enum.chunk_every(args, 2, 1)
             |> Enum.member?(["--permission-mode", "bypassPermissions"])

      assert "--allow-dangerously-skip-permissions" in args
    end

    test "UNARMED bypass falls back to plan and emits NO danger flag (fail-closed)" do
      args = ClaudeChat.build_args("bypassPermissions", %{session_id: "u-1", bypass_armed: false})
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--permission-mode", "plan"])
      refute "bypassPermissions" in args
      refute "--allow-dangerously-skip-permissions" in args
    end

    test "a missing bypass_armed key is treated as unarmed (fail-closed to plan)" do
      args = ClaudeChat.build_args("bypassPermissions", %{session_id: "u-1"})
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--permission-mode", "plan"])
      refute "--allow-dangerously-skip-permissions" in args
    end

    test "bypass_armed alone (non-bypass mode) never emits the danger flag" do
      args = ClaudeChat.build_args("acceptEdits", %{session_id: "u-1", bypass_armed: true})
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--permission-mode", "acceptEdits"])
      refute "--allow-dangerously-skip-permissions" in args
    end
  end
end
