defmodule BarkparkWeb.Studio.ClaudeChatRealBinaryTest do
  @moduledoc """
  END-TO-END proofs against the REAL `claude` binary — the resume proof (charter
  D20c) plus the wave-10 PROBE SUITE (charter D52/D53/D56).

  These are the tests that spend real money and real time (haiku-pinned to stay
  under the ~$0.43/run ceiling, charter D56) and drive the actual CLI over the
  stream-json wire — everything else in the suite fakes the subprocess.

  The resume proof (`describe "resume"`) proves the persistence premise: a fresh
  session pinned with `--session-id <uuid>` (via OUR `build_args` seam — the
  `:binary` override KEEPS build_args, unlike `:command` which bypasses it and
  would prove nothing, charter D9) stamps a codeword, is closed, and a SEPARATE
  `--resume <uuid>` process recalls it.

  The wave-10 PROBES turn three wave-9 wire assumptions — built to spec but never
  proven against a real binary — into PERMANENT regression tests (charter wave-10
  "real-binary probe wave"). Each probe is its own `describe` with its own tag so
  it can run in isolation (`mix test --only probe_workflow_shape`, etc.):

    * `:probe_workflow_shape` (D52) — `workflow_progress` is a FLAT list of
      `workflow_phase`/`workflow_agent` nodes with NO `children` nesting. The
      wave-9 agents rail was built to this flat spec; a future binary emitting a
      nested tree would silently render no agents. This probe is the tripwire.
    * `:probe_postplan_mode` (D52) — the DECIDING probe: what `permissionMode`
      does the CLI report on the NEXT `system/init` after a plan is approved
      through our real `respond_permission` seam? Asserted as a RAW STRING, never
      the terminal result frame (whose `permission_mode` is null — vacuous green).
    * `:probe_spawn_flags` (D53) — RATIFICATION only, no manufactured fix: the
      `--help` enumeration (both bypass flags, five effort tiers, six mode
      choices) matches the code allowlists, and one real `--effort` haiku spawn
      reaches a result frame. NEVER a live armed-bypass spawn (D53 hard rule).

  EXCLUDED by default (`@moduletag :real_binary`, appended to the test_helper
  exclude list). Opt in through `scripts/claude-chat-e2e.sh` OR directly with
  `CLAUDE_BIN=… mix test --only real_binary <this file>` — the `claude` binary is
  NOT on PATH on the dev host, so the setup resolves `CLAUDE_BIN` or flunks with
  that instruction rather than silently passing.
  """
  use ExUnit.Case, async: false

  @moduletag :real_binary
  # Real model turns are slow; give each test a generous ceiling.
  @moduletag timeout: 300_000

  alias BarkparkWeb.Studio.ClaudeChat

  @turn_timeout 60_000
  @codeword "PINECONE-42"

  # The full set of permission-mode strings the CLI is known to report/accept —
  # the six live modes (charter D48) plus the retired-but-still-accepted `default`
  # (charter D34: approving a plan may flip the CLI's OWN mode to one of these).
  # A post-plan value OUTSIDE this set is the falsification D52 must surface.
  @known_modes ~w(plan acceptEdits auto dontAsk manual bypassPermissions default)

  # Known `workflow_agent` lifecycle states (charter D52). `start`/`done` are
  # wire-proven (wave-10 captures); the failure terminals are defensive so a real
  # error state does not red the probe, while a genuinely NEW token still trips it.
  @known_agent_states ~w(start done queued running error failed cancelled canceled timeout aborted)

  setup do
    bin = resolve_claude_bin()

    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

    # `:binary` (NOT `:command`) so build_args/2 still assembles the real argv,
    # including --session-id / --resume / --model / --effort — the seam under proof.
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

  # ══════════════════════════════════════════════════════════════════════════
  # Resume proof (charter D20c) — the original real-binary test.
  # ══════════════════════════════════════════════════════════════════════════

  describe "resume" do
    test "a resumed session recalls a codeword stamped in a prior process" do
      uuid = Ecto.UUID.generate()

      # ── turn 1: fresh pinned session — stamp the codeword ────────────────
      {:ok, s1} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{session_id: uuid, model: "haiku"}
        })

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

      # ── turn 2: a SEPARATE process resumes the same uuid — recall ────────
      {:ok, s2} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{session_id: uuid, resume: true, model: "haiku"}
        })

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
  end

  # ══════════════════════════════════════════════════════════════════════════
  # PROBE 1 — workflow_progress FLAT-LIST contract (charter D52)
  # ══════════════════════════════════════════════════════════════════════════

  describe "workflow shape probe" do
    @describetag :probe_workflow_shape

    test "workflow_progress is a flat list of phase/agent nodes with no children nesting" do
      # A fully-specified Workflow script (2 phases, haiku sub-agents echoing the
      # phase name) — deterministic so the tool actually launches. Given verbatim
      # so haiku only has to CALL the tool, not author the script.
      script =
        """
        export const meta = {
          name: 'echo-phases',
          description: 'Two-phase workflow with agents echoing phase names',
          phases: [
            { title: 'Phase One', detail: 'First phase' },
            { title: 'Phase Two', detail: 'Second phase' }
          ]
        }

        phase('Phase One')
        await agent('Echo the phase name: Phase One', {label: 'phase-one-echo'})

        phase('Phase Two')
        await agent('Echo the phase name: Phase Two', {label: 'phase-two-echo'})
        """

      prompt =
        "You have a Workflow tool. Call it RIGHT NOW, once, with exactly this " <>
          "script (do not modify it, do not ask, launch it in the background):\n\n" <>
          "```\n" <> script <> "```"

      # acceptEdits (not plan) so the model ACTS instead of proposing a plan; the
      # Workflow ask still routes to us via --permission-prompt-tool stdio and the
      # collector auto-approves it.
      {:ok, s} =
        ClaudeChat.start_session(%{
          sink: self(),
          mode: "acceptEdits",
          session_opts: %{session_id: Ecto.UUID.generate(), model: "haiku"}
        })

      # The collectors answer permission asks on this one live session.
      Process.put(:probe_session, s)
      ClaudeChat.send_message(s, prompt)

      {wf_lists, bg_lists} = collect_workflow_frames(90_000)

      ClaudeChat.close(s)

      # No vacuous pass: the probe exists to VERIFY a live workflow's wire shape,
      # so a run where the tool never launched is a probe failure, not a skip.
      if wf_lists == [] do
        dump_frames("probe_workflow_shape", %{workflow_progress: wf_lists, background_tasks: bg_lists})

        flunk("""
        No workflow_progress frames were captured — the Workflow tool never
        launched, so the flat-list contract could not be checked. Re-run (haiku
        occasionally declines the tool); if it persists the trigger prompt or the
        cmux binary's Workflow tool has changed. Raw frames dumped to the scratch
        path above.
        """)
      end

      for wp <- wf_lists do
        assert is_list(wp), "workflow_progress must be a FLAT list, got: #{inspect(wp)}"

        for node <- wp do
          assert is_map(node), "each workflow node must be a map, got: #{inspect(node)}"

          # THE falsification this probe exists to catch: a nested `children` tree
          # (or any nested node list) would neither render in the rail nor trip the
          # change-only guard — the wave-9 rail is built to a FLAT spec.
          refute Map.has_key?(node, "children"),
                 "workflow node has a nested `children` key — the rail's FLAT-LIST " <>
                   "assumption (charter D47/D52) is FALSIFIED: #{inspect(node)}"

          assert node["type"] in ["workflow_phase", "workflow_agent"],
                 "unknown workflow node type #{inspect(node["type"])}: #{inspect(node)}"

          case node["type"] do
            "workflow_phase" ->
              assert is_integer(node["index"]), "phase node missing integer index: #{inspect(node)}"
              assert is_binary(node["title"]), "phase node missing title: #{inspect(node)}"

            "workflow_agent" ->
              assert is_binary(node["label"]), "agent node missing label: #{inspect(node)}"
              assert is_integer(node["phaseIndex"]), "agent node missing phaseIndex: #{inspect(node)}"
              assert is_binary(node["model"]), "agent node missing model: #{inspect(node)}"

              assert node["state"] in @known_agent_states,
                     "agent node has an UNKNOWN state #{inspect(node["state"])} (known: " <>
                       "#{inspect(@known_agent_states)}) — a new lifecycle state the rail " <>
                       "does not handle: #{inspect(node)}"
          end
        end
      end

      # At least one real agent node was observed (the flat list actually carried
      # the crew, not just phase headers).
      assert Enum.any?(wf_lists, fn wp ->
               Enum.any?(wp, &(&1["type"] == "workflow_agent"))
             end),
             "no workflow_agent node ever appeared — captured only phase headers"

      # background_tasks_changed snapshots (if any) are ALSO flat: a `tasks` list
      # of {task_id, task_type, description} rows (charter D47).
      for tasks <- bg_lists do
        assert is_list(tasks), "background_tasks_changed.tasks must be a flat list: #{inspect(tasks)}"

        for t <- tasks do
          assert is_binary(t["task_id"]), "task row missing task_id: #{inspect(t)}"
          assert is_binary(t["task_type"]), "task row missing task_type: #{inspect(t)}"
          refute Map.has_key?(t, "children"), "task row has nested children: #{inspect(t)}"
        end
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # PROBE 2 — post-plan permissionMode verdict (charter D52; this probe DECIDES)
  # ══════════════════════════════════════════════════════════════════════════

  describe "post-plan permissionMode probe" do
    @describetag :probe_postplan_mode

    test "the next system/init after a plan approval reports a known permissionMode" do
      {:ok, s} =
        ClaudeChat.start_session(%{
          sink: self(),
          mode: "plan",
          session_opts: %{session_id: Ecto.UUID.generate(), model: "haiku"}
        })

      # The drivers answer permission asks on this one live session.
      Process.put(:probe_session, s)

      # Force an ExitPlanMode ask: propose, do not act.
      ClaudeChat.send_message(
        s,
        "Make a short plan to create a file named hello.txt containing the text " <>
          "'hi'. Do NOT create it yet — present the plan for my approval via " <>
          "ExitPlanMode and wait."
      )

      # Capture the ExitPlanMode ask (any other ask along the way is auto-approved).
      {rid, input} = await_exit_plan_ask(60_000)

      # Approve THROUGH THE REAL SEAM with the bare {:allow, input} the Approve
      # button sends: {"behavior":"allow","updatedInput":plan} — NO
      # updatedPermissions (chat_live.ex plan-approve → claude_chat respond_permission).
      ClaudeChat.respond_permission(s, rid, {:allow, input})

      # Drain the plan-execution turn to its result (auto-approving any follow-on
      # asks), then a nudge turn forces a FRESH system/init whose permissionMode
      # reflects the CLI's post-plan mode.
      drain_to_result(60_000)
      ClaudeChat.send_message(s, "Reply with just: ready")
      observed = await_next_init_permission_mode(60_000)

      ClaudeChat.close(s)

      # Asserted as a RAW STRING off the init frame — never the terminal result
      # frame (its permission_mode is null: vacuous green, charter D34).
      assert is_binary(observed) and observed != "",
             "no permissionMode string on the post-plan init frame; got: #{inspect(observed)}"

      # The verdict, recorded verbatim in the run output so the six-mode unit-test
      # fix and the charter D34/D52 amendment can be pinned to reality.
      IO.puts("\n[PROBE_POSTPLAN_MODE] post-plan permissionMode = #{inspect(observed)}\n")

      assert observed in @known_modes,
             "post-plan permissionMode #{inspect(observed)} is OUTSIDE the known set " <>
               "#{inspect(@known_modes)} — charter D52 says surface it as a system line and " <>
               "leave the stored mode alone; the observe_permission_mode guard must NOT widen " <>
               "silently to admit it."
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # PROBE 3 — spawn-flag ratification (charter D53; NO manufactured fix)
  # ══════════════════════════════════════════════════════════════════════════

  describe "spawn flags probe" do
    @describetag :probe_spawn_flags

    test "--help enumerates both bypass flags, five effort tiers, six mode choices", %{bin: bin} do
      {help, 0} = System.cmd(bin, ["--help"], stderr_to_stdout: true)

      # Two DISTINCT bypass flags exist; build_args deliberately uses the `allow`
      # variant (claude_chat.ex bypass_args). Both must be present so the choice
      # stays a real choice, not a guess.
      assert help =~ "--allow-dangerously-skip-permissions"
      assert help =~ "--dangerously-skip-permissions"

      # --effort tiers match @efforts EXACTLY (the help renders them as
      # "(low, medium, high, xhigh, max)").
      assert help =~ "--effort"

      for tier <- ClaudeChat.efforts() do
        assert help =~ tier, "--help does not enumerate effort tier #{inspect(tier)}"
      end

      # --permission-mode choices match @modes EXACTLY (help renders each quoted:
      # "acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan").
      assert help =~ "--permission-mode"

      for mode <- ClaudeChat.modes() do
        assert help =~ ~s("#{mode}"), "--help does not enumerate permission mode #{inspect(mode)}"
      end
    end

    test "a real --effort haiku spawn reaches a result frame (the flag is accepted)" do
      {:ok, s} =
        ClaudeChat.start_session(%{
          sink: self(),
          mode: "acceptEdits",
          session_opts: %{session_id: Ecto.UUID.generate(), model: "haiku", effort: "low"}
        })

      {result, _text} = run_turn(s, "Reply with just: ok", @turn_timeout)

      ClaudeChat.close(s)

      # The CLI accepted `--effort low` end-to-end: a normal result frame, never a
      # startup crash. (If --effort were rejected the process would exit before any
      # result — run_turn would flunk on the exit branch.)
      assert result["type"] == "result"
      refute result["is_error"] == true,
             "the --effort spawn errored: #{inspect(result)}"
    end
  end

  # ── shared drivers ────────────────────────────────────────────────────────

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

  # PROBE 1 collector: pump frames until the workflow signals completion (a
  # task_notification `completed`, or a drain back to an empty background snapshot
  # after a non-empty one) or the deadline. Auto-approves any permission ask so a
  # backgrounded Workflow tool actually launches. Returns
  # {workflow_progress_lists, background_tasks_lists}.
  defp collect_workflow_frames(budget_ms) do
    deadline = now_ms() + budget_ms
    collect_workflow_frames(deadline, [], [], false)
  end

  defp collect_workflow_frames(deadline, wf, bg, saw_nonempty_bg) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
      {Enum.reverse(wf), Enum.reverse(bg)}
    else
      receive do
        {:claude_chat_permission, %{request_id: rid, input: input}} ->
          ClaudeChat.respond_permission(self_session(), rid, {:allow, input})
          collect_workflow_frames(deadline, wf, bg, saw_nonempty_bg)

        {:claude_chat_event, %{"subtype" => "task_progress", "workflow_progress" => wp}}
        when is_list(wp) ->
          collect_workflow_frames(deadline, [wp | wf], bg, saw_nonempty_bg)

        {:claude_chat_event, %{"subtype" => "background_tasks_changed", "tasks" => tasks}}
        when is_list(tasks) ->
          nonempty = saw_nonempty_bg or tasks != []
          # A drain back to [] after a non-empty snapshot = the workflow finished.
          if tasks == [] and saw_nonempty_bg,
            do: {Enum.reverse(wf), Enum.reverse([tasks | bg])},
            else: collect_workflow_frames(deadline, wf, [tasks | bg], nonempty)

        {:claude_chat_event, %{"subtype" => "task_notification", "status" => "completed"}} ->
          # Give any trailing final workflow_progress frame a moment, then stop.
          collect_trailing(now_ms() + 3_000, wf, bg)

        {:claude_chat_event, _other} ->
          collect_workflow_frames(deadline, wf, bg, saw_nonempty_bg)

        {:claude_chat_exit, _status} ->
          {Enum.reverse(wf), Enum.reverse(bg)}
      after
        remaining -> {Enum.reverse(wf), Enum.reverse(bg)}
      end
    end
  end

  # Short tail-drain after a completion signal so the terminal `state: "done"`
  # workflow_progress frame is captured.
  defp collect_trailing(deadline, wf, bg) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
      {Enum.reverse(wf), Enum.reverse(bg)}
    else
      receive do
        {:claude_chat_event, %{"subtype" => "task_progress", "workflow_progress" => wp}}
        when is_list(wp) ->
          collect_trailing(deadline, [wp | wf], bg)

        {:claude_chat_event, %{"subtype" => "background_tasks_changed", "tasks" => tasks}}
        when is_list(tasks) ->
          collect_trailing(deadline, wf, [tasks | bg])

        {:claude_chat_event, _other} ->
          collect_trailing(deadline, wf, bg)

        {:claude_chat_exit, _status} ->
          {Enum.reverse(wf), Enum.reverse(bg)}
      after
        remaining -> {Enum.reverse(wf), Enum.reverse(bg)}
      end
    end
  end

  # PROBE 2: wait for the ExitPlanMode ask; auto-approve any OTHER ask on the way.
  defp await_exit_plan_ask(budget_ms) do
    deadline = now_ms() + budget_ms
    await_exit_plan_ask(deadline, budget_ms)
  end

  defp await_exit_plan_ask(deadline, _last) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
      flunk("no ExitPlanMode ask within the budget — the model never proposed a plan")
    else
      receive do
        {:claude_chat_permission, %{tool_name: "ExitPlanMode", request_id: rid, input: input}} ->
          {rid, input}

        {:claude_chat_permission, %{request_id: rid, input: input}} ->
          # Some other tool asked first — approve and keep waiting for the plan.
          ClaudeChat.respond_permission(self_session(), rid, {:allow, input})
          await_exit_plan_ask(deadline, remaining)

        {:claude_chat_event, %{"type" => "result"}} ->
          flunk("the plan turn ended with no ExitPlanMode ask — the model acted or refused")

        {:claude_chat_event, _other} ->
          await_exit_plan_ask(deadline, remaining)

        {:claude_chat_exit, status} ->
          flunk("session exited (status #{status}) before an ExitPlanMode ask")
      after
        remaining -> flunk("no ExitPlanMode ask within #{remaining}ms")
      end
    end
  end

  # Drain the current turn to its result, auto-approving any permission asks.
  defp drain_to_result(budget_ms) do
    deadline = now_ms() + budget_ms
    drain_to_result(deadline, budget_ms)
  end

  defp drain_to_result(deadline, _last) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
      flunk("the post-approval turn did not reach a result within the budget")
    else
      receive do
        {:claude_chat_permission, %{request_id: rid, input: input}} ->
          ClaudeChat.respond_permission(self_session(), rid, {:allow, input})
          drain_to_result(deadline, remaining)

        {:claude_chat_event, %{"type" => "result"}} ->
          :ok

        {:claude_chat_event, _other} ->
          drain_to_result(deadline, remaining)

        {:claude_chat_exit, status} ->
          flunk("session exited (status #{status}) before the post-approval result")
      after
        remaining -> flunk("no post-approval result within #{remaining}ms")
      end
    end
  end

  # Capture the permissionMode string off the NEXT system/init frame.
  defp await_next_init_permission_mode(budget_ms) do
    deadline = now_ms() + budget_ms
    await_next_init_permission_mode(deadline, budget_ms)
  end

  defp await_next_init_permission_mode(deadline, _last) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
      flunk("no system/init frame arrived to read permissionMode from")
    else
      receive do
        {:claude_chat_permission, %{request_id: rid, input: input}} ->
          ClaudeChat.respond_permission(self_session(), rid, {:allow, input})
          await_next_init_permission_mode(deadline, remaining)

        {:claude_chat_event, %{"type" => "system", "subtype" => "init"} = ev} ->
          ev["permissionMode"] || ev["permission_mode"]

        {:claude_chat_event, _other} ->
          await_next_init_permission_mode(deadline, remaining)

        {:claude_chat_exit, status} ->
          flunk("session exited (status #{status}) before a post-plan init frame")
      after
        remaining -> flunk("no post-plan init within #{remaining}ms")
      end
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # The collectors auto-approve permission asks, which needs the live session pid.
  # Each probe stashes its one session under `:probe_session` right after spawn.
  defp self_session, do: Process.get(:probe_session) || raise("no :probe_session set")

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
        CLAUDE_BIN is not set. This real-binary suite is opt-in and spends real
        API budget — run it through scripts/claude-chat-e2e.sh, which resolves
        the claude binary (it is not on PATH on this host) or refuses, or set
        CLAUDE_BIN explicitly:
          CLAUDE_BIN=/path/to/claude mix test --only real_binary \\
            test/barkpark_web/studio/claude_chat_real_binary_test.exs
        """)
    end
  end

  # On a probe failure, dump the raw captured frames to a scratch path so the
  # falsification can be diagnosed WITHOUT committing a fixture (S1 owns the
  # fixtures dir; probes assert in-memory, charter wave-10).
  defp dump_frames(label, data) do
    dir = System.tmp_dir!()
    path = Path.join(dir, "bp-#{label}-#{System.system_time(:second)}.json")
    File.write(path, Jason.encode!(data, pretty: true))
    IO.puts("\n[#{label}] raw frames dumped to #{path}\n")
  end
end
