defmodule BarkparkWeb.Studio.ClaudeChatTest do
  @moduledoc """
  Gate + subprocess behavior of the Studio Claude chat seam. No real `claude`
  anywhere: the command is overridden with `cat` (echo server — a written
  NDJSON user message rides straight back through the real Port + parse
  path) and tiny `sh -c` scripts (canned init events, exit statuses).
  """
  use ExUnit.Case, async: false

  alias BarkparkWeb.Studio.ClaudeChat

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

    test "on with an available command and the default flag" do
      put_chat_config(command: {"cat", []})
      assert ClaudeChat.enabled?()
    end

    test "hard-refuses public-demo hosts regardless of the flag" do
      put_chat_config(enabled: true, command: {"cat", []})
      Application.put_env(:barkpark, :public_demo_studio, true)
      refute ClaudeChat.enabled?()
    end

    test "off when the binary is not installed" do
      put_chat_config(enabled: true, command: {"definitely-not-a-real-binary-bp", []})
      refute ClaudeChat.enabled?()
    end

    test "start_session refuses when disabled" do
      put_chat_config(enabled: false, command: {"cat", []})
      assert {:error, :disabled} = ClaudeChat.start_session(%{sink: self()})
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
      {_exe, ask_args} = with_default_command(fn -> ClaudeChat.command("default") end)

      # Plan mode is the product default and every plan session hits
      # ExitPlanMode — without the flag that ask never reaches Barkpark, so the
      # proposed-plan card could never render.
      assert Enum.chunk_every(plan_args, 2, 1)
             |> Enum.member?(["--permission-prompt-tool", "stdio"])

      assert Enum.chunk_every(plan_args, 2, 1) |> Enum.member?(["--permission-mode", "plan"])

      assert Enum.chunk_every(ask_args, 2, 1)
             |> Enum.member?(["--permission-prompt-tool", "stdio"])

      assert Enum.chunk_every(ask_args, 2, 1) |> Enum.member?(["--permission-mode", "default"])
    end

    test "normalize_mode fails closed to plan" do
      assert ClaudeChat.normalize_mode("acceptEdits") == "acceptEdits"
      assert ClaudeChat.normalize_mode("bypassPermissions") == "plan"
      assert ClaudeChat.normalize_mode(nil) == "plan"
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
      args = ClaudeChat.build_args("default", %{session_id: @uuid})
      # the base permission args survive the append
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--permission-mode", "default"])
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

      assert_receive {:claude_chat_exit, 0}, 2_000
    end

    test "reports a non-zero exit status" do
      put_chat_config(command: {"sh", ["-c", "exit 3"]})

      {:ok, _session} = ClaudeChat.start_session(%{sink: self()})
      assert_receive {:claude_chat_exit, 3}, 2_000
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

  # `head -n 1` drains exactly the first written frame to a file (flushing on
  # exit), then `cat` keeps the Port alive.
  defp frame_capture_command(file), do: {"sh", ["-c", "head -n 1 > '#{file}'; cat"]}

  defp read_lines(file), do: file |> wait_for_file() |> String.split("\n", trim: true)

  defp read_frame(file), do: file |> wait_for_file() |> String.trim() |> Jason.decode!()

  defp wait_for_file(file, tries \\ 150) do
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
end
