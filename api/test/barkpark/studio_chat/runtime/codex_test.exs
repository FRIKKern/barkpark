defmodule Barkpark.StudioChat.Runtime.CodexTest do
  use ExUnit.Case, async: false

  alias Barkpark.StudioChat.Runtime.Codex
  alias Barkpark.StudioChat.Runtime.Event

  @fake_app_server Path.expand("../../../fixtures/codex_app_server/fake_app_server.py", __DIR__)

  defp fake_app_server(mode \\ :normal) do
    id = System.unique_integer([:positive])
    log = Path.join(System.tmp_dir!(), "codex_app_server_fake_#{id}.jsonl")

    on_exit(fn -> File.rm(log) end)

    {@fake_app_server, ["--scenario", Atom.to_string(mode), "--log", log], log}
  end

  test "stdio JSONL lifecycle preserves order, native ids, streaming, approvals, and terminal truth" do
    {binary, args, log} = fake_app_server()

    assert {:ok, runtime} =
             Codex.start(%{
               binary: binary,
               args: args,
               sink: self(),
               session_id: "barkpark-session",
               cwd: "/tmp",
               timeout_ms: 500
             })

    assert runtime.provider_session_id == "thread-1"

    assert :ok = Codex.send_turn(runtime, "hello")

    assert_receive {:studio_chat_runtime_event,
                    %Event{kind: :turn_started, turn_id: "turn-1", durability: :durable}}

    assert_receive {:studio_chat_runtime_event,
                    %Event{kind: :text_delta, item_id: "item-1", durability: :delta}}

    approvals =
      for _ <- 1..3 do
        assert_receive {:studio_chat_runtime_event,
                        %Event{kind: :approval_requested, approval_id: approval_id}}

        approval_id
      end

    assert approvals == ["91", "92", "93"]
    assert :ok = Codex.answer_approval(runtime, "91", :allow)
    assert :ok = Codex.answer_approval(runtime, "92", :deny)
    assert :ok = Codex.answer_approval(runtime, "93", :cancel)
    assert :ok = Codex.steer(runtime, %{content: "focus"})
    assert :ok = Codex.interrupt(runtime)

    assert_receive {:studio_chat_runtime_event,
                    %Event{kind: :turn_completed, terminal_state: :interrupted}}

    assert :ok = Codex.close(runtime)

    wire = File.read!(log)
    refute wire =~ "jsonrpc"

    assert ordered?(wire, [
             "initialize",
             "initialized",
             "account/read",
             "thread/start",
             "turn/start",
             "turn/steer",
             "turn/interrupt"
           ])

    assert wire =~ ~s("id":91,"result":{"decision":"accept"})
    assert wire =~ ~s("id":92,"result":{"decision":"decline"})
    assert wire =~ ~s("id":93,"result":{"decision":"cancel"})
  end

  test "resume uses the opaque provider thread id" do
    {binary, args, log} = fake_app_server()

    assert {:ok, runtime} =
             Codex.resume(%{
               binary: binary,
               args: args,
               sink: self(),
               session_id: "barkpark-session",
               provider_session_id: "native-thread",
               timeout_ms: 500
             })

    assert runtime.provider_session_id == "thread-resumed"
    assert File.read!(log) =~ ~s("method":"thread/resume")
    assert File.read!(log) =~ ~s("threadId":"native-thread")
    assert :ok = Codex.close(runtime)
  end

  test "request timeout and process death fail closed without hanging" do
    {malformed, malformed_args, _log} = fake_app_server(:malformed)

    assert {:error, :malformed_response} =
             Codex.start(%{
               binary: malformed,
               args: malformed_args,
               sink: self(),
               session_id: "barkpark-session",
               timeout_ms: 500
             })

    assert_receive {:studio_chat_runtime_event,
                    %Event{kind: :protocol_error, error: %{"code" => "malformed_jsonl"}}}

    {stalling, stalling_args, _log} = fake_app_server(:stall_turn)

    assert {:ok, runtime} =
             Codex.start(%{
               binary: stalling,
               args: stalling_args,
               sink: self(),
               session_id: "barkpark-session",
               timeout_ms: 500
             })

    assert {:error, :timeout} = Codex.send_turn(runtime, "wait")
    assert {:error, :timeout} = Codex.interrupt(runtime)
    assert :ok = Codex.close(runtime)

    {dying, dying_args, _log} = fake_app_server(:die_on_turn)

    assert {:ok, runtime} =
             Codex.start(%{
               binary: dying,
               args: dying_args,
               sink: self(),
               session_id: "barkpark-session",
               timeout_ms: 500
             })

    assert {:error, {:process_exit, 17}} = Codex.send_turn(runtime, "die")

    assert_receive {:studio_chat_runtime_event,
                    %Event{kind: :process_failed, terminal_state: :failed}}

    {replacement, replacement_args, replacement_log} = fake_app_server()

    assert {:ok, reconciled} =
             Codex.resume(%{
               binary: replacement,
               args: replacement_args,
               sink: self(),
               session_id: "barkpark-session",
               provider_session_id: runtime.provider_session_id,
               timeout_ms: 500
             })

    assert reconciled.provider_session_id == "thread-resumed"
    assert File.read!(replacement_log) =~ ~s("threadId":"thread-1")
    assert :ok = Codex.close(reconciled)
  end

  test "session startup rejects an incompatible app-server before initialize" do
    id = System.unique_integer([:positive])
    binary = Path.join(System.tmp_dir!(), "codex_incompatible_#{id}.sh")
    marker = Path.join(System.tmp_dir!(), "codex_incompatible_#{id}.started")

    File.write!(binary, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo 'codex-cli 0.144.4'
      exit 0
    fi
    touch '#{marker}'
    """)

    File.chmod!(binary, 0o755)

    on_exit(fn ->
      File.rm(binary)
      File.rm(marker)
    end)

    assert {:error, :incompatible_version} =
             Codex.start(%{binary: binary, args: [], sink: self(), session_id: "session"})

    refute File.exists?(marker)
  end

  test "a runaway newline-free stream is capped, not buffered — port closed, callers fail closed" do
    # A tiny canned-handshake app-server stub: it answers `--version` to cross the
    # readiness gate, walks the initialize/account/thread handshake with fixed
    # responses, then — on the first turn — floods newline-free bytes forever. With
    # no reassembly cap this pins `state.buffer` and every caller hangs to timeout;
    # with the cap the port is closed and the pending turn fails `:buffer_overflow`.
    id = System.unique_integer([:positive])
    binary = Path.join(System.tmp_dir!(), "codex_flood_#{id}.sh")

    File.write!(binary, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo 'codex-cli 0.144.1'
      exit 0
    fi
    IFS= read -r line                                    # initialize
    printf '{"id":1,"result":{}}\\n'
    IFS= read -r line                                    # initialized notification
    IFS= read -r line                                    # account/read
    printf '{"id":2,"result":{"requiresOpenaiAuth":false}}\\n'
    IFS= read -r line                                    # thread/start
    printf '{"id":3,"result":{"thread":{"id":"thread-1"}}}\\n'
    IFS= read -r line                                    # turn/start -> flood
    # DELIBERATELY pathological, and it must stay that way: the loop stops reading
    # stdin before it writes (so it never sees the EOF a port close produces) and
    # writes with the `printf` BUILTIN (so a closed pipe yields EPIPE, which the
    # shell reports and survives — SIGPIPE only kills external commands). That is
    # the wedged-provider shape the overflow path exists to stop, and the only
    # stub against which "the OS process is gone" means anything.
    #
    # The one concession to hygiene is the iteration BOUND (GH #6681): breaching a
    # 64KB cap needs ~512 iterations, so it is unreachable while the test is
    # healthy, but it caps a leaked orphan at seconds of spinning instead of the
    # 1d19h two of these actually ran for.
    i=0
    while [ "$i" -lt 500000 ]; do
      printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
      i=$((i + 1))
    done
    """)

    File.chmod!(binary, 0o755)
    on_exit(fn -> File.rm(binary) end)

    prior = Application.get_env(:barkpark, :codex_app_server)
    Application.put_env(:barkpark, :codex_app_server, max_buffer_bytes: 64 * 1024)

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, :codex_app_server, prior)
      else
        Application.delete_env(:barkpark, :codex_app_server)
      end
    end)

    assert {:ok, runtime} =
             Codex.start(%{
               binary: binary,
               sink: self(),
               session_id: "barkpark-session",
               timeout_ms: 5_000
             })

    port = :sys.get_state(runtime.runtime).port
    assert Port.info(port) != nil, "port should be open after a clean handshake"

    # Read the child's pid while the port is still open — it is both the subject
    # of the regression assertion below and the safety net: if anything in this
    # test fails early, on_exit reaps the flood loop rather than leaving it to the
    # machine (belt; the assertion is the braces).
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end)

    # Threshold-crossing assertion: the pending turn caller fails closed with the
    # bound's atom (never :timeout, which is what unbounded code returns).
    assert {:error, :buffer_overflow} = Codex.send_turn(runtime, "flood")

    assert_receive {:studio_chat_runtime_event,
                    %Event{kind: :protocol_error, error: %{"code" => "buffer_overflow"}}}

    assert Port.info(port) == nil, "port must be closed on buffer breach"

    # The port being closed proves only that the BEAM let go (GH #6681). This stub
    # cannot notice EOF and cannot die to EPIPE, so it is gone if and only if the
    # overflow path SIGNALLED it — revert the kill in `reap_port/1` and this reds
    # while every assertion above still passes.
    assert wait_until(fn -> not os_process_alive?(os_pid) end),
           "app-server OS process #{os_pid} survived the buffer breach — closing a " <>
             "{:spawn_executable, _} port sends the child no signal, so a provider that " <>
             "ignores stdin EOF is orphaned at 100% CPU (GH #6681)"

    assert :ok = Codex.close(runtime)
  end

  # `kill -0` cannot answer this: it succeeds on a zombie, and a SIGKILLed child
  # is a zombie until the BEAM's erl_child_setup reaps it. Read the state column
  # instead and count `Z` as gone — it holds no CPU and no fds.
  defp os_process_alive?(os_pid) do
    case System.cmd("ps", ["-o", "state=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        state = String.trim(out)
        state != "" and not String.starts_with?(state, "Z")

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp wait_until(fun, timeout_ms \\ 2_000, waited_ms \\ 0) do
    cond do
      fun.() ->
        true

      waited_ms >= timeout_ms ->
        false

      true ->
        Process.sleep(25)
        wait_until(fun, timeout_ms, waited_ms + 25)
    end
  end

  defp ordered?(wire, methods) do
    {ordered, _offset} =
      Enum.reduce(methods, {true, 0}, fn method, {ordered, offset} ->
        case :binary.match(wire, method, scope: {offset, byte_size(wire) - offset}) do
          {position, length} -> {ordered, position + length}
          :nomatch -> {false, offset}
        end
      end)

    ordered
  end
end
