defmodule BarkparkWeb.Studio.ClaudeChatRealBinaryTest do
  @moduledoc """
  END-TO-END resume proof against the REAL `claude` binary (charter D20c).

  This is the one test that spends real money and real time (~$0.43 + ~40s per
  run) and drives the actual CLI over the stream-json wire — everything else in
  the suite fakes the subprocess. It proves the whole persistence premise:

    1. a fresh session pinned with `--session-id <uuid>` (via OUR `build_args`
       seam — the `:binary` override KEEPS build_args, unlike `:command` which
       bypasses it and would prove nothing, charter D9) stamps a codeword;
    2. the process is closed;
    3. a SEPARATE process resumes the SAME uuid with `--resume` and RECALLS the
       codeword — meaning the CLI's own transcript is the resumable memory and
       our minted uuid is the single durable identity (D8).

  It also proves the single-writer invariant matters: we wait for the first
  process to fully exit (DOWN) before the resume registers under the same uuid,
  so two `--resume` writers never touch the transcript at once (D20).

  EXCLUDED by default (`@moduletag :real_binary`, appended to the test_helper
  exclude list). Opt in ONLY through `scripts/claude-chat-e2e.sh`, which resolves
  `CLAUDE_BIN` (the `claude` binary is NOT on PATH on the dev host) or refuses.
  Running it directly without `CLAUDE_BIN` set flunks with that instruction
  rather than silently passing.
  """
  use ExUnit.Case, async: false

  @moduletag :real_binary
  # Real model turns are slow; give each turn a full minute before we call it.
  @moduletag timeout: 300_000

  alias BarkparkWeb.Studio.ClaudeChat

  @turn_timeout 60_000
  @codeword "PINECONE-42"

  setup do
    bin = resolve_claude_bin()

    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

    # `:binary` (NOT `:command`) so build_args/2 still assembles the real argv,
    # including --session-id / --resume — the seam under proof.
    Application.put_env(:barkpark, :claude_chat, enabled: true, binary: bin)
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    {:ok, bin: bin}
  end

  test "a resumed session recalls a codeword stamped in a prior process" do
    uuid = Ecto.UUID.generate()

    # ── turn 1: fresh pinned session — stamp the codeword ──────────────────
    {:ok, s1} = ClaudeChat.start_session(%{sink: self(), session_opts: %{session_id: uuid}})
    ref1 = Process.monitor(s1)

    {result1, _text1} =
      run_turn(
        s1,
        "Remember this codeword exactly for later: #{@codeword}. Reply with just: ok",
        @turn_timeout
      )

    # The id we minted is the id the CLI echoes — never scraped off an init frame.
    assert result1["session_id"] == uuid

    # Close and WAIT for the process to fully exit before resuming: two
    # `--resume` writers on one transcript is the exact harm D20 forbids.
    ClaudeChat.close(s1)
    assert_receive {:DOWN, ^ref1, :process, ^s1, _reason}, 10_000

    # ── turn 2: a SEPARATE process resumes the same uuid — recall ──────────
    {:ok, s2} =
      ClaudeChat.start_session(%{sink: self(), session_opts: %{session_id: uuid, resume: true}})

    ref2 = Process.monitor(s2)

    {_result2, text2} =
      run_turn(
        s2,
        "What was the codeword I asked you to remember? Reply with only the codeword.",
        @turn_timeout
      )

    # Substring, case-folded: the model may wrap or re-case it ("PINECONE-42",
    # "Pinecone-42", "The codeword was PINECONE-42.").
    assert String.contains?(String.upcase(text2), "PINECONE"),
           "resumed session did not recall the codeword; got: #{inspect(text2)}"

    ClaudeChat.close(s2)
    assert_receive {:DOWN, ^ref2, :process, ^s2, _reason}, 10_000
  end

  # Drive one turn: send the user text, then collect assistant text until the
  # terminal `result` frame. Returns {result_frame, accumulated_assistant_text}.
  # The final `result` frame also carries the answer in "result", so we fold that
  # in too (a short reply may skip streamed assistant blocks entirely).
  defp run_turn(session, text, timeout) do
    ClaudeChat.send_message(session, text)
    await_result(timeout, "")
  end

  defp await_result(timeout, acc) do
    receive do
      {:claude_chat_event, %{"type" => "assistant", "message" => %{"content" => blocks}}}
      when is_list(blocks) ->
        await_result(timeout, acc <> assistant_text(blocks))

      {:claude_chat_event, %{"type" => "result"} = frame} ->
        {frame, acc <> to_string(frame["result"] || "")}

      {:claude_chat_event, _other} ->
        await_result(timeout, acc)

      {:claude_chat_exit, status} ->
        flunk("session exited (status #{status}) before a result frame")
    after
      timeout -> flunk("no result frame within #{timeout}ms")
    end
  end

  defp assistant_text(blocks) do
    for %{"type" => "text", "text" => t} when is_binary(t) <- blocks, into: "", do: t
  end

  # Resolve the real `claude` path from CLAUDE_BIN (set by
  # scripts/claude-chat-e2e.sh). No silent skip: an opt-in run with no binary is
  # a configuration error, so flunk with the fix rather than pass vacuously.
  defp resolve_claude_bin do
    case System.get_env("CLAUDE_BIN") do
      bin when is_binary(bin) and bin != "" ->
        cond do
          File.exists?(bin) -> bin
          exe = System.find_executable(bin) -> exe
          true -> flunk("CLAUDE_BIN=#{bin} is not an executable file")
        end

      _ ->
        flunk("""
        CLAUDE_BIN is not set. This real-binary E2E is opt-in and spends real
        API budget — run it through scripts/claude-chat-e2e.sh, which resolves
        the claude binary (it is not on PATH on this host) or refuses.
        """)
    end
  end
end
