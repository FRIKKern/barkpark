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

  setup context do
    # The wave-12 mcp-loopback probe drives the real `bp` binary, not `claude`
    # — it opts out of the CLAUDE_BIN requirement via `needs_claude: false`.
    if context[:needs_claude] == false do
      :ok
    else
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
        dump_frames("probe_workflow_shape", %{
          workflow_progress: wf_lists,
          background_tasks: bg_lists
        })

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
              assert is_integer(node["index"]),
                     "phase node missing integer index: #{inspect(node)}"

              assert is_binary(node["title"]), "phase node missing title: #{inspect(node)}"

            "workflow_agent" ->
              assert is_binary(node["label"]), "agent node missing label: #{inspect(node)}"

              assert is_integer(node["phaseIndex"]),
                     "agent node missing phaseIndex: #{inspect(node)}"

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
        assert is_list(tasks),
               "background_tasks_changed.tasks must be a flat list: #{inspect(tasks)}"

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
      # The approved plan really executes: the model creates hello.txt in the
      # CLI cwd (api/). Reap the artifact so the money lane never litters the
      # repo — an untracked hello.txt after a probe run was wave-10 review debris.
      on_exit(fn -> File.rm(Path.join(ClaudeChat.cwd(), "hello.txt")) end)

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

  # ══════════════════════════════════════════════════════════════════════════
  # PROBE 4 (wave 12) — minted-token → `bp mcp serve` end-to-end (charter D63)
  # ══════════════════════════════════════════════════════════════════════════

  describe "mcp loopback minted-token probe" do
    @describetag :probe_mcp_loopback
    @describetag needs_claude: false

    test "a minted short-TTL ApiToken injected via the env block bearer-auths bp mcp serve" do
      # The bp subprocess dials our endpoint over real HTTP — its request
      # processes are not owned by this test, so the sandbox goes shared.
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Barkpark.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Barkpark.Repo, {:shared, self()})

      url = start_local_api()
      {raw, token} = mint_session_token()
      bp = resolve_bp_bin()
      manifest = Path.join(repo_root(), "docs/cli/fixtures/full-manifest.json")
      assert File.exists?(manifest), "fixture manifest missing: #{manifest}"

      # ── leg 1: the minted token IS the credential — initialize + tools/call ─
      %{1 => init_resp, 2 => call_resp} = drive_mcp(bp, manifest, url, raw)

      refute init_resp["error"], "initialize failed: #{inspect(init_resp)}"
      assert get_in(init_resp, ["result", "serverInfo", "name"]) != nil

      refute call_resp["error"], "tools/call errored: #{inspect(call_resp)}"
      result = call_resp["result"]

      refute result["isError"] == true,
             "tools/call with the minted token must SUCCEED, got: #{inspect(result)}"

      # D64 wire law end-to-end: one text block, JSON-encoded string payload.
      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert {:ok, %{"ok" => true, "docs" => docs}} = Jason.decode(text)
      assert is_list(docs)

      # The success itself is the isolation proof for the URL leg: the minted
      # token's hash exists ONLY in this test's sandboxed DB, so the 200 can
      # only have come from OUR endpoint authenticating OUR token.

      # ── leg 2: nothing is inherited — without the env token, the host's
      # saved admin config buys ZERO access against this API ─────────────────
      no_token = drive_mcp(bp, manifest, url, nil)

      refute mcp_call_succeeded?(no_token[2]),
             "bp mcp serve WITHOUT the injected token still reached the API — " <>
               "the host's saved config leaked through (charter D63 isolation " <>
               "falsified): #{inspect(no_token[2])}"

      # ── leg 3: revocation backstop (D63: terminate/2 + short TTL) ─────────
      {:ok, _} = Barkpark.Auth.revoke_token(token)
      revoked = drive_mcp(bp, manifest, url, raw)

      refute mcp_call_succeeded?(revoked[2]),
             "a REVOKED minted token still authenticated (charter D63 " <>
               "revocation falsified): #{inspect(revoked[2])}"

      IO.puts(
        "\n[PROBE_MCP_LOOPBACK] minted-token e2e: initialize+tools/call OK via env " <>
          "block; no-token spawn denied; revoked-token spawn denied.\n"
      )
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # PROBE 5 (wave 12) — plan-mode Workflow gating under the REAL chat argv
  # (charter D68: bare-CLI probes showed ZERO gating; this decides the seam)
  # ══════════════════════════════════════════════════════════════════════════

  describe "plan-mode Workflow gating probe" do
    @describetag :probe_plan_gating

    test "does plan mode gate the Workflow tool under --permission-prompt-tool stdio?" do
      script =
        """
        export const meta = {
          name: 'echo-noop',
          description: 'One-phase probe workflow',
          phases: [ { title: 'Phase One', detail: 'Echo' } ]
        }

        phase('Phase One')
        await agent('Echo the word: ok', {label: 'echo-ok'})
        """

      # The prompt PRE-APPROVES the call and forbids the model's own detours
      # (a first run showed haiku routing through AskUserQuestion: "plan mode
      # blocks me" — model-level courtesy, which is exactly what this probe
      # must see PAST to learn what the CLI itself enforces).
      prompt =
        "This is an authorized wire probe. The user has explicitly pre-approved " <>
          "exactly one Workflow tool call. Call the Workflow tool RIGHT NOW with " <>
          "exactly this script (do not modify it). Do NOT use AskUserQuestion. " <>
          "Do NOT use ExitPlanMode. Do NOT present a plan. Your only permitted " <>
          "action is the single Workflow call itself — make it immediately:\n\n" <>
          "```\n" <> script <> "```"

      # PLAN mode through the real seam: build_args emits --permission-mode plan
      # AND --permission-prompt-tool stdio (charter D33) — the exact argv the
      # live chat spawns. The responder DENIES every ask so nothing launches.
      {:ok, s} =
        ClaudeChat.start_session(%{
          sink: self(),
          mode: "plan",
          session_opts: %{session_id: Ecto.UUID.generate(), model: "haiku"}
        })

      Process.put(:probe_session, s)
      ClaudeChat.send_message(s, prompt)

      verdict =
        observe_gating(120_000, %{attempted: false, asks: [], launched: false, said: ""})

      ClaudeChat.close(s)

      # The verdict, verbatim, for the charter D68 amendment + task evidence.
      IO.puts("\n[PROBE_PLAN_GATING] #{format_gating_verdict(verdict)}\n")

      # A decisive signal is required: either the tool_use fired (and we saw
      # what the CLI did with it), or the MODEL refused in prose — the 2026-07-10
      # capture: "Plan Mode is active, which means I cannot run non-readonly
      # tools like Workflow" / routed through an AskUserQuestion ask instead.
      # Model refusal IS the D68 verdict: the plan-mode gate lives in the
      # model's system prompt, NOT in CLI enforcement (bare-CLI probes proved
      # the CLI executes Workflow in plan mode when the model does try), so
      # the fail-closed guard (--disallowedTools Workflow) transfers to the
      # loopback slice regardless.
      assert verdict.attempted or verdict.said != "",
             "neither a Workflow tool_use nor a prose refusal was observed — " <>
               "no verdict possible; re-run (the trigger prompt may have decayed)"

      # What must NEVER happen under a scripted deny responder: an actual
      # launch after (or without) an ask.
      refute verdict.launched and not verdict.attempted,
             "a workflow LAUNCHED without any observed Workflow tool_use"

      if verdict.asks != [] do
        refute verdict.launched,
               "the Workflow LAUNCHED even though the seam ask was DENIED — " <>
                 "the deny leg of the gate is broken"
      end
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

      # Both exit shapes: the 2-tuple (pre-D54) and the 3-tuple carrying the
      # stderr tail (charter D54) — whichever the merged Session emits, a death
      # here is a specific flunk, never a silent timeout.
      {:claude_chat_exit, status} ->
        flunk("session exited (status #{status}) before a result frame")

      {:claude_chat_exit, status, stderr} ->
        flunk("session exited (status #{status}) before a result frame#{stderr_note(stderr)}")
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

        {:claude_chat_exit, _status, _stderr} ->
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

        {:claude_chat_exit, _status, _stderr} ->
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

        {:claude_chat_exit, status, stderr} ->
          flunk(
            "session exited (status #{status}) before an ExitPlanMode ask#{stderr_note(stderr)}"
          )
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

        {:claude_chat_exit, status, stderr} ->
          flunk(
            "session exited (status #{status}) before the post-approval result#{stderr_note(stderr)}"
          )
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

        {:claude_chat_exit, status, stderr} ->
          flunk(
            "session exited (status #{status}) before a post-plan init frame#{stderr_note(stderr)}"
          )
      after
        remaining -> flunk("no post-plan init within #{remaining}ms")
      end
    end
  end

  # ── PROBE 4 drivers (mcp loopback) ─────────────────────────────────────────

  # Serve the REAL BarkparkWeb.Endpoint (it is a Plug) on an ephemeral local
  # port so the bp subprocess can dial it over actual HTTP. test.exs keeps
  # `server: false`; this is a probe-scoped listener, torn down with the test.
  defp start_local_api do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port_num} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)

    start_supervised!(
      {Bandit, plug: BarkparkWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: port_num}
    )

    "http://127.0.0.1:#{port_num}"
  end

  # A D63-style session credential, minted through the Auth internals the S4
  # mint function is patterned on (auth.ex create_share_token insert block):
  # kind "api" (the ONLY kind Auth.verify_token resolves), curated REAL
  # permissions (read-only — never admin, never share-edit-*), a short session
  # TTL (15 min — clamp_ttl's 7-day floor is exactly why S4 needs its own
  # constant), label carrying the session identity.
  defp mint_session_token do
    raw = "bpsess_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, token} =
      %Barkpark.Auth.ApiToken{}
      |> Barkpark.Auth.ApiToken.changeset(%{
        token_hash: Barkpark.Auth.ApiToken.hash_token(raw),
        label: "claude-session #{Ecto.UUID.generate()}",
        permissions: ["read"],
        expires_at: DateTime.add(now, 900)
      })
      |> Barkpark.Repo.insert()

    {raw, token}
  end

  # Drive `bp mcp serve --tools tasks` over real process stdio: initialize →
  # notifications/initialized → tools/call task_ready. The manifest comes from
  # the committed fixture (the BARKPARK_MANIFEST override seam, load.go) so
  # initialize never dials the API — ONLY tools/call exercises the credential.
  # `token: nil` spawns with BARKPARK_API_TOKEN explicitly REMOVED from the
  # child env (the {name, false} Port form), the not-inherited leg.
  defp drive_mcp(bp, manifest, url, token) do
    env =
      [
        {~c"BARKPARK_MANIFEST", to_charlist(manifest)},
        {~c"BARKPARK_API_URL", to_charlist(url)},
        {~c"BARKPARK_API_TOKEN", if(token, do: to_charlist(token), else: false)}
      ]

    port =
      Port.open({:spawn_executable, bp}, [
        :binary,
        :exit_status,
        :hide,
        args: ["mcp", "serve", "--tools", "tasks"],
        env: env
      ])

    session = [
      ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bp-loopback-probe","version":"0.0.0"}}}),
      ~s({"jsonrpc":"2.0","method":"notifications/initialized"}),
      ~s({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_ready","arguments":{"limit":1}}})
    ]

    for line <- session, do: Port.command(port, line <> "\n")

    out = collect_port_until_id2(port, "", now_ms() + 30_000)

    # Close stdin/port; the server's read loop ends on EOF.
    catch_port_close(port)

    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn l ->
      case Jason.decode(l) do
        {:ok, %{"id" => id} = resp} when is_integer(id) -> [{id, resp}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp collect_port_until_id2(port, acc, deadline) do
    if String.contains?(acc, ~s("id":2)) or now_ms() > deadline do
      acc
    else
      receive do
        {^port, {:data, chunk}} ->
          collect_port_until_id2(port, acc <> chunk, deadline)

        {^port, {:exit_status, _status}} ->
          acc
      after
        max(deadline - now_ms(), 0) -> acc
      end
    end
  end

  defp catch_port_close(port) do
    if Port.info(port), do: Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  # A tools/call leg "succeeded" only when it answered with a non-error MCP
  # result whose payload decodes to ok:true — anything else (JSON-RPC error,
  # isError:true, no response at all, an auth failure envelope) is a denial.
  defp mcp_call_succeeded?(nil), do: false
  defp mcp_call_succeeded?(%{"error" => _}), do: false

  defp mcp_call_succeeded?(%{"result" => result}) do
    with false <- result["isError"] == true,
         [%{"type" => "text", "text" => text}] <- result["content"],
         {:ok, %{"ok" => true}} <- Jason.decode(text) do
      true
    else
      _ -> false
    end
  end

  defp mcp_call_succeeded?(_), do: false

  # Locate the bp binary for the loopback probe: BP_BIN when set, else build it
  # from source exactly like the Go stdio smoke does (CC=clang — the cc shim on
  # this host is not a compiler).
  defp resolve_bp_bin do
    case System.get_env("BP_BIN") do
      bin when is_binary(bin) and bin != "" ->
        if File.exists?(bin), do: bin, else: flunk("BP_BIN=#{bin} does not exist")

      _ ->
        bin = Path.join(System.tmp_dir!(), "bp-loopback-probe-#{System.system_time(:second)}")

        {out, status} =
          System.cmd(
            "go",
            ["build", "-o", bin, "github.com/FRIKKern/barkpark/cmd/barkpark"],
            cd: repo_root(),
            env: [{"CC", "clang"}],
            stderr_to_stdout: true
          )

        if status != 0, do: flunk("go build bp failed:\n#{out}")
        on_exit(fn -> File.rm(bin) end)
        bin
    end
  end

  # Module root (the dir with go.mod), mirroring mcpSmokeRepoRoot.
  defp repo_root, do: Path.expand("../../../..", __DIR__)

  # ── PROBE 5 drivers (plan-mode gating) ─────────────────────────────────────

  # Pump the session until its terminal result frame (or the deadline),
  # DENYING every permission ask, and record the three D68 signals: was a
  # Workflow tool_use attempted, did any ask reach the seam, did anything
  # actually LAUNCH (task_started / workflow_progress / non-empty bg snapshot).
  defp observe_gating(budget_ms, state) do
    deadline = now_ms() + budget_ms
    observe_gating_loop(deadline, state)
  end

  defp observe_gating_loop(deadline, state) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
      state
    else
      receive do
        {:claude_chat_permission, %{tool_name: tool, request_id: rid}} ->
          # The scripted DENY responder — nothing may actually launch.
          ClaudeChat.respond_permission(
            self_session(),
            rid,
            {:deny, "D68 gating probe: scripted deny — do not launch anything"}
          )

          observe_gating_loop(deadline, %{state | asks: [tool | state.asks]})

        {:claude_chat_event, %{"type" => "assistant", "message" => %{"content" => blocks}}}
        when is_list(blocks) ->
          attempted =
            state.attempted or
              Enum.any?(blocks, &(&1["type"] == "tool_use" and &1["name"] == "Workflow"))

          said = state.said <> assistant_text(blocks)
          observe_gating_loop(deadline, %{state | attempted: attempted, said: said})

        {:claude_chat_event, %{"subtype" => "task_started"}} ->
          observe_gating_loop(deadline, %{state | launched: true})

        {:claude_chat_event, %{"subtype" => "task_progress", "workflow_progress" => wp}}
        when is_list(wp) ->
          observe_gating_loop(deadline, %{state | launched: true})

        {:claude_chat_event, %{"subtype" => "background_tasks_changed", "tasks" => [_ | _]}} ->
          observe_gating_loop(deadline, %{state | launched: true})

        {:claude_chat_event, %{"type" => "result"} = frame} ->
          Map.put(state, :denials, frame["permission_denials"] || [])

        {:claude_chat_event, _other} ->
          observe_gating_loop(deadline, state)

        {:claude_chat_exit, status} ->
          flunk("session exited (status #{status}) before a gating verdict")

        {:claude_chat_exit, status, stderr} ->
          flunk("session exited (status #{status}) before a gating verdict#{stderr_note(stderr)}")
      after
        remaining -> state
      end
    end
  end

  defp format_gating_verdict(v) do
    outcome =
      cond do
        "Workflow" in (v.asks || []) ->
          "GATED-VIA-SEAM (can_use_tool ask reached us; denied)"

        v.launched ->
          "UNGATED (Workflow launched with NO seam ask — guard transfers to S4)"

        v.attempted and (v[:denials] || []) != [] ->
          "DENIED-BY-CLI (no seam ask; CLI denied it)"

        v.attempted ->
          "ATTEMPTED-NO-OUTCOME (tool_use fired, nothing observable followed)"

        true ->
          "MODEL-REFUSED (no tool_use; the gate is prompt-level courtesy, not CLI enforcement)"
      end

    "attempted=#{v.attempted} asks=#{inspect(Enum.reverse(v.asks || []))} " <>
      "launched=#{v.launched} denials=#{inspect(v[:denials] || [])} " <>
      "said=#{inspect(String.slice(v.said || "", 0, 300))} → #{outcome}"
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # The D54 3-tuple exit carries a bounded stderr tail — fold it into the flunk
  # so a real-lane death diagnoses itself.
  defp stderr_note(stderr) when is_binary(stderr) and stderr != "", do: " — stderr: #{stderr}"
  defp stderr_note(_), do: ""

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
