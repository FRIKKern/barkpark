defmodule BarkparkWeb.Studio.ClaudeChatCloudSessionTest do
  @moduledoc """
  The two-turn invocation-counting CAPSTONE (connectors Wave 15, charter
  D144–D146; task connectors-w14-two-turn-stub-proof). W14 landed the
  multi-turn Cloud session mechanism — W14-1's session-identity argv
  (`--session-id`/`--resume` + `--keep-sandbox`/`--sandbox-id`) and W14-2's
  `chat_sessions.cloud_sandbox_id` binding — but only ASSERTED, never RUN
  together across two consecutive turns. This file makes it RUN.

  A stub `cloud-sandbox-runner` (a chmod+x `sh`, no live Vercel Sandbox, no
  ANTHROPIC key — the same offline technique as `bogus_key_shim` and
  `w14-session-sandbox-proof.sh`) drives the REAL
  `Recorder.ensure → Runtime.open → Port.open` pipeline TWICE on the same
  Barkpark Chat Session:

    * Turn 1 — no `--sandbox-id` in the shim's OWN argv ⇒ it emits a
      `bp_sandbox` sideband frame binding `sbx-stub-1`, then a terminal
      `result`, then EXITS (no trailing `cat`). The Recorder swallows the
      binding onto the Session row, `{:stop, :normal}`s.
    * Turn 2 — a FRESH Recorder re-reads the persisted `cloud_sandbox_id` at
      init (recorder.ex:295), so the shim's OWN argv now carries
      `--sandbox-id sbx-stub-1` and the claude segment `--resume` (never
      `--session-id`). It emits a `result` only.

  The invocation-counting proof: the shim appends `create`/`reuse` to a shared
  counter keyed on `--sandbox-id` presence in its argv. Exactly ONE create
  across both turns (a broken always-create shim would read
  `["create","create"]`). Everything offline, nothing fabricated.

  Scope honesty (D146): the claude segment's `--env ANTHROPIC_API_KEY` is
  shim-INTERNAL (`cloud-sandbox-runner.mjs runTurn`) — NOT emitted by the
  Elixir argv builder — and is deliberately NOT asserted here; it is covered at
  the scripts layer. `[error]` Postgrex "disconnected" lines during the run are
  known DataCase drain noise, not failures.
  """
  # async: false + Barkpark.DataCase ⇒ shared sandbox mode (data_case.ex:82):
  # the Recorder runs under the RuntimeSupervisor DynamicSupervisor, a separate
  # process that must reach this test's DB connection.
  use Barkpark.DataCase, async: false

  # Plugins-off: the studio_chat capability owns the chat supervisors, registries and /v1/chat routes
  @moduletag :requires_plugins

  alias Barkpark.Connectors.CloudPolicy
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias BarkparkWeb.Studio.ClaudeChat

  # A concrete workspace principal — a Cloud turn hard-fails on nil/:global
  # (D110). No Workspace row is needed: with zero tool descriptors the argv
  # builder never touches connector_installs, it only threads the id as a string.
  @workspace_id "11111111-2222-3333-4444-555555555555"
  @sandbox_id "sbx-stub-1"

  describe "two-turn invocation-counting Cloud session (connectors D137/D139 — the W14 capstone)" do
    test "turn 1 CREATES + binds a sandbox, turn 2 REUSES it — one create across both turns" do
      argv1 = capture_path("argv1")
      argv2 = capture_path("argv2")
      counter = capture_path("counter")

      put_chat_config(
        enabled: true,
        execution_profile: :cloud,
        sandbox_runner: two_turn_shim(argv1, argv2, counter)
      )

      sid = Ecto.UUID.generate()
      {:ok, _session} = StudioChat.create_session(%{id: sid, mode: "plan"}, :global)

      # Subscribe BEFORE the first spawn so we can prove the bp_sandbox binding
      # frame never reaches a viewer (the Recorder swallows it — recorder.ex:522).
      :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.topic(sid))

      # ── TURN 1 ────────────────────────────────────────────────────────────
      {:ok, _rec1} =
        Recorder.ensure(%{
          session_id: sid,
          mode: "plan",
          execution_target: "managed",
          workspace_id: @workspace_id
        })

      # The stub exits after its frames; the Session dies :normal, the Recorder
      # {:stop, :normal}s. Wait for that BEFORE reading the binding / spawning
      # turn 2 — never a Process.exit kill (a shared-mode ownership artifact).
      assert_recorder_gone(sid)

      # BINDING: the swallowed bp_sandbox frame persisted onto the Session row…
      assert %{cloud_sandbox_id: @sandbox_id} =
               wait_for_session(sid, &match?(%{cloud_sandbox_id: @sandbox_id}, &1))

      # …and it was NOT broadcast to viewers and appended NO chat_messages row.
      events1 = drain_chat_events()

      assert Enum.any?(events1, &(&1["type"] == "result")),
             "the result frame must flow to the topic (non-vacuity: the pipeline ran)"

      refute Enum.any?(events1, &(&1["type"] == "bp_sandbox")),
             "the bp_sandbox binding frame must never reach a viewer"

      assert StudioChat.list_messages(sid, :global) == [],
             "the bp_sandbox frame appends no chat_messages row"

      # ARGV shape — the shim's OWN argv, captured verbatim (empty args preserved).
      a1 = read_argv(argv1)
      {pre1, ["--" | post1]} = Enum.split_while(a1, &(&1 != "--"))

      assert consecutive?(pre1, ["--workspace", @workspace_id])
      assert "--keep-sandbox" in pre1
      refute "--sandbox-id" in a1, "turn 1 is a fresh create — no --sandbox-id"
      refute "--resume" in a1, "turn 1 mints a session, it does not resume"
      assert consecutive?(post1, ["--session-id", sid])
      assert_w12_belt_intact(a1)

      # ── TURN 2 ────────────────────────────────────────────────────────────
      {:ok, _rec2} =
        Recorder.ensure(%{
          session_id: sid,
          mode: "plan",
          execution_target: "managed",
          workspace_id: @workspace_id
        })

      assert_recorder_gone(sid)

      a2 = read_argv(argv2)
      {pre2, ["--" | post2]} = Enum.split_while(a2, &(&1 != "--"))

      assert consecutive?(pre2, ["--workspace", @workspace_id])

      assert consecutive?(pre2, ["--sandbox-id", @sandbox_id]),
             "turn 2 reuses the bound sandbox pre-`--`"

      assert "--keep-sandbox" in pre2
      assert consecutive?(post2, ["--resume", sid]), "turn 2 resumes the same session uuid"
      refute "--session-id" in a2, "a resume turn never re-mints --session-id"
      assert_w12_belt_intact(a2)

      # THE invocation count: exactly ONE create, then ONE reuse. This is the
      # capstone assertion — the second sandboxed one-shot demonstrably received
      # turn 1's session state at the config/argv layer.
      assert read_lines(counter) == ["create", "reuse"]
    end
  end

  describe "amnesia transport (charter D108 — a Cloud turn is a one-shot, not a held subprocess)" do
    test "the shim exit stops the Session :normal; send_message on the dead pid is {:error, {:not_running, _}}" do
      put_chat_config(
        enabled: true,
        execution_profile: :cloud,
        sandbox_runner: exit_shim()
      )

      {:ok, session} =
        ClaudeChat.start_session(%{
          sink: self(),
          session_opts: %{workspace_id: @workspace_id, session_id: Ecto.UUID.generate()}
        })

      ref = Process.monitor(session)
      # The one-shot shim emits its result and EXITS → the Port closes →
      # the Session GenServer {:stop, :normal}s (claude_chat.ex:1319-1324).
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 2_000
      refute Process.alive?(session)

      # The regression pin (zero production code — claude_chat.ex:922 already
      # catches the :exit): a send onto the dead session is an honest failed
      # dispatch, never a false :ok. Continuity must ride the SESSION (the
      # persisted sandbox binding above), because the subprocess is gone.
      assert {:error, {:not_running, _reason}} = ClaudeChat.send_message(session, "still there?")
    end
  end

  describe "dead-sandbox binding clears on a loud reuse failure (connectors D139 half B / D152–D156)" do
    test "turn 3 mints FRESH after the bound sandbox vanishes on turn 2 — honest reset, not --resume into the void" do
      argv1 = capture_path("argv1")
      argv2 = capture_path("argv2")
      argv3 = capture_path("argv3")
      counter = capture_path("counter")

      put_chat_config(
        enabled: true,
        execution_profile: :cloud,
        sandbox_runner: three_turn_reset_shim(argv1, argv2, argv3, counter)
      )

      sid = Ecto.UUID.generate()
      {:ok, _session} = StudioChat.create_session(%{id: sid, mode: "plan"}, :global)

      # ── TURN 1 — fresh create binds sbx-stub-1 ─────────────────────────────
      {:ok, _rec1} =
        Recorder.ensure(%{
          session_id: sid,
          mode: "plan",
          execution_target: "managed",
          workspace_id: @workspace_id
        })

      assert_recorder_gone(sid)

      assert %{cloud_sandbox_id: "sbx-stub-1"} =
               wait_for_session(sid, &match?(%{cloud_sandbox_id: "sbx-stub-1"}, &1))

      a1 = read_argv(argv1)
      refute "--sandbox-id" in a1, "turn 1 is a fresh create — no --sandbox-id"
      refute "--resume" in a1, "turn 1 mints a session, it does not resume"
      assert "--keep-sandbox" in a1
      assert_w12_belt_intact(a1)

      # ── TURN 2 — the bound sandbox is GONE: reuse exits nonzero, zero frames ─
      {:ok, _rec2} =
        Recorder.ensure(%{
          session_id: sid,
          mode: "plan",
          execution_target: "managed",
          workspace_id: @workspace_id
        })

      assert_recorder_gone(sid)

      # THE binding-clear assertion (fail-first: reds on origin/main with
      # `right: %Session{cloud_sandbox_id: "sbx-stub-1"}` — the dead binding
      # survives the loud failure and would --resume the NEXT turn into an empty
      # filesystem). After wiring, the loud nonzero exit clears it inline.
      session_after = wait_for_session(sid, &match?(%{cloud_sandbox_id: nil}, &1))

      assert match?(%{cloud_sandbox_id: nil}, session_after),
             "a loud reuse failure (nonzero exit) must clear the dead sandbox binding (#{inspect(session_after.cloud_sandbox_id)})"

      # Non-vacuity: turn 2 genuinely ATTEMPTED to reuse the dead sandbox —
      # its own argv carried --sandbox-id sbx-stub-1 (the gaslighting scenario).
      a2 = read_argv(argv2)

      assert consecutive?(a2, ["--sandbox-id", "sbx-stub-1"]),
             "turn 2 tried to reuse the bound (now-dead) sandbox"

      # ── TURN 3 — a fresh Recorder re-reads the CLEARED column → fresh shape ─
      {:ok, _rec3} =
        Recorder.ensure(%{
          session_id: sid,
          mode: "plan",
          execution_target: "managed",
          workspace_id: @workspace_id
        })

      assert_recorder_gone(sid)

      a3 = read_argv(argv3)
      {pre3, ["--" | post3]} = Enum.split_while(a3, &(&1 != "--"))

      assert consecutive?(pre3, ["--workspace", @workspace_id])
      assert "--keep-sandbox" in pre3

      refute "--sandbox-id" in a3,
             "turn 3 mints fresh — the cleared binding means no --sandbox-id"

      refute "--resume" in a3, "turn 3 mints a NEW session id, it does not resume the void"
      assert consecutive?(post3, ["--session-id", sid]), "turn 3 is an honest fresh --session-id"
      assert_w12_belt_intact(a3)

      # …and it RE-BOUND a DIFFERENT sandbox (proving re-establish, not stale reuse).
      session_after = wait_for_session(sid, &match?(%{cloud_sandbox_id: "sbx-stub-2"}, &1))

      assert match?(%{cloud_sandbox_id: "sbx-stub-2"}, session_after),
             "turn 3's fresh sandbox re-binds the session to a new id (#{inspect(session_after.cloud_sandbox_id)})"

      # The invocation ledger: create, a failed reuse, then a fresh create.
      assert read_lines(counter) == ["create", "reuse-fail", "create"]
    end

    test "a CREATE turn that binds a sandbox then exits NONZERO PRESERVES the fresh binding (at-spawn nil ⇒ no clear)" do
      argv = capture_path("argv")

      put_chat_config(
        enabled: true,
        execution_profile: :cloud,
        sandbox_runner: create_then_fail_shim(argv)
      )

      sid = Ecto.UUID.generate()
      {:ok, _session} = StudioChat.create_session(%{id: sid, mode: "plan"}, :global)

      {:ok, _rec} =
        Recorder.ensure(%{
          session_id: sid,
          mode: "plan",
          execution_target: "managed",
          workspace_id: @workspace_id
        })

      assert_recorder_gone(sid)

      # A fresh create turn's at-spawn binding is nil, so even a loud nonzero
      # exit must NOT clear — the bp_sandbox frame minted a LIVE box mid-turn and
      # clearing it (or re-reading the column at exit) would orphan a healthy
      # sandbox. The next turn legitimately reuses it.
      session_after = wait_for_session(sid, &match?(%{cloud_sandbox_id: "sbx-preserve-1"}, &1))

      assert match?(%{cloud_sandbox_id: "sbx-preserve-1"}, session_after),
             "a create turn (at-spawn nil) keeps the freshly-bound sandbox even on nonzero exit (#{inspect(session_after.cloud_sandbox_id)})"

      a = read_argv(argv)
      refute "--sandbox-id" in a, "the create turn spawned with no binding"
      assert "--keep-sandbox" in a
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # Mirror of claude_chat_test.exs:69 — flip the chat config on, hard-disable the
  # public-demo host (else enabled?/0 fail-closes to {:error, :disabled}), and
  # restore both on exit.
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

  # The invocation-counting stub `cloud-sandbox-runner`. Its `$@` IS the Cloud
  # argv (`cloud_build_args/2`), so it branches on whether `--sandbox-id` rides
  # its OWN argv — the one signal W14-1 uses to mark a resume turn:
  #
  #   * absent (turn 1) — write argv to `argv1`, append `create`, emit the
  #     `bp_sandbox` binding frame then a terminal `result`, EXIT.
  #   * present (turn 2) — write argv to `argv2`, append `reuse`, emit `result`,
  #     EXIT.
  #
  # It MUST exit (no trailing `cat`, unlike bogus_key_shim): the Recorder needs
  # the Session to die :normal so turn 2 spawns a FRESH Recorder that re-reads
  # the persisted binding at init (recorder.ex:295). One stdout per turn,
  # frames in order.
  defp two_turn_shim(argv1, argv2, counter) do
    script = """
    #!/bin/sh
    has_sandbox=0
    for a in "$@"; do
      case "$a" in --sandbox-id) has_sandbox=1 ;; esac
    done
    if [ "$has_sandbox" = "1" ]; then
      printf '%s\\n' "$@" > '#{argv2}'
      printf 'reuse\\n' >> '#{counter}'
      printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    else
      printf '%s\\n' "$@" > '#{argv1}'
      printf 'create\\n' >> '#{counter}'
      printf '%s\\n' '{"type":"bp_sandbox","subtype":"created","sandbox_id":"#{@sandbox_id}"}'
      printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    fi
    """

    write_shim(script)
  end

  # The three-turn honest-reset stub (charter D152/D156). Branches on whether
  # `--sandbox-id` rides its OWN argv, exactly like `two_turn_shim`, but the
  # reuse turn stands in for a VANISHED sandbox — it emits ZERO frames and exits
  # NONZERO (the D152 signature: a reuse-path failure propagates the vercel
  # child's raw nonzero code, no NDJSON, so the binding must clear):
  #
  #   * no `--sandbox-id`, first time (argv1 absent) — turn 1 fresh create,
  #     binds `sbx-stub-1`, emits `bp_sandbox` + `result`, EXIT 0.
  #   * `--sandbox-id` present — turn 2 reuse of the dead box: append
  #     `reuse-fail`, emit NOTHING, EXIT 1 → the Recorder clears the binding.
  #   * no `--sandbox-id`, second time (argv1 present) — turn 3 fresh create off
  #     the CLEARED column, binds a DIFFERENT `sbx-stub-2`, emits frames, EXIT 0.
  #
  # Turn 1-vs-3 is disambiguated by argv1's existence (deterministic, no counter
  # parsing) so the emitted id proves a genuine RE-BIND, not a stale reuse.
  defp three_turn_reset_shim(argv1, argv2, argv3, counter) do
    script = """
    #!/bin/sh
    has_sandbox=0
    for a in "$@"; do
      case "$a" in --sandbox-id) has_sandbox=1 ;; esac
    done
    if [ "$has_sandbox" = "1" ]; then
      printf '%s\\n' "$@" > '#{argv2}'
      printf 'reuse-fail\\n' >> '#{counter}'
      exit 1
    elif [ -f '#{argv1}' ]; then
      printf '%s\\n' "$@" > '#{argv3}'
      printf 'create\\n' >> '#{counter}'
      printf '%s\\n' '{"type":"bp_sandbox","subtype":"created","sandbox_id":"sbx-stub-2"}'
      printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    else
      printf '%s\\n' "$@" > '#{argv1}'
      printf 'create\\n' >> '#{counter}'
      printf '%s\\n' '{"type":"bp_sandbox","subtype":"created","sandbox_id":"sbx-stub-1"}'
      printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    fi
    """

    write_shim(script)
  end

  # A create turn that MINTS a live sandbox (bp_sandbox frame) then dies LOUD
  # (nonzero exit). The at-spawn binding was nil, so the clear must NOT fire —
  # the preserve counterfactual for D154 (a re-read at exit would orphan the
  # healthy fresh box).
  defp create_then_fail_shim(argv) do
    script = """
    #!/bin/sh
    printf '%s\\n' "$@" > '#{argv}'
    printf '%s\\n' '{"type":"bp_sandbox","subtype":"created","sandbox_id":"sbx-preserve-1"}'
    exit 3
    """

    write_shim(script)
  end

  # A minimal one-shot stub: emit a terminal result, then EXIT (no cat). Stands
  # in for a Cloud turn whose sandboxed subprocess is gone the instant it ends.
  defp exit_shim do
    script = """
    #!/bin/sh
    printf '%s\\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    """

    write_shim(script)
  end

  defp write_shim(script) do
    path =
      Path.join(System.tmp_dir!(), "cloud_session_shim_#{System.unique_integer([:positive])}.sh")

    File.write!(path, script)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  # Poll until the WHOLE turn is gone: the Recorder for `sid` AND the provider
  # Session it drove. 1000 × 10ms = 10s ceiling (widened from 2s,
  # task-38ab22218252aa45): the `kill -0`/MCP-revoke cleanup `terminate/2`
  # forks below is real OS + DB work, and a 2s ceiling was measured to flunk
  # on a plain dev box under nothing more than two OTHER copies of this same
  # suite running concurrently — not a hung process, a slow one, racing a
  # clock that stood in for "has it finished" instead of observing it. The
  # happy path still returns in well under 100ms; this only widens the floor
  # a genuinely stuck case needs to clear before FLUNKING for real.
  #
  # The Recorder alone is not enough (task-f68536c6c37a2ece). The Session sends
  # `{:claude_chat_exit, …}` to its sink and only THEN stops — its `terminate/2`
  # still forks `kill -0` (`cleanup_stderr`) and revokes the MCP token
  # (`cleanup_mcp`) while it holds its `SessionRegistry` name under the same
  # `sid`. The Recorder, meanwhile, clears the binding and stops, so
  # `Recorder.whereis/1` can read nil while the old Session is still
  # registered. A next-turn `Recorder.ensure` in that window hits
  # `{:error, {:already_started, dying}}` in `Recorder.init/1`, ADOPTS the dying
  # Session, gets its `:DOWN` and stops — the next shim never spawns
  # (CI: counter held `create\nreuse-fail\n`, argv3 never written).
  defp assert_recorder_gone(sid, tries \\ 1000) do
    cond do
      Recorder.whereis(sid) == nil and session_gone?(sid) -> :ok
      tries <= 0 -> flunk("recorder or provider session for #{sid} never terminated")
      true -> Process.sleep(10) && assert_recorder_gone(sid, tries - 1)
    end
  end

  # The single-writer Session name (provider/claude.ex `@registry`) is released
  # only once the Session process has exited and the Registry has reaped it.
  defp session_gone?(sid), do: Registry.lookup(Barkpark.StudioChat.SessionRegistry, sid) == []

  # Poll a session row until `pred` holds, or a ~30s ceiling elapses
  # (task-38ab22218252aa45, widened at task-dad9a71f6dcd2f08 — see below).
  #
  # `assert_recorder_gone` proves the Recorder's LAST `handle_info` call has
  # RETURNED — `{:claude_chat_event, bp_sandbox}`'s `Repo.update()` is
  # synchronous and strictly precedes it in the SAME process's mailbox, so
  # the write itself has already happened by then. What it does NOT prove is
  # that this test's OWN read — a SEPARATE process, under Ecto's shared-mode
  # sandbox connection but still a distinct scheduled read — observes it on
  # the very next `get_session/1` call under CI's own scheduling pressure
  # (measured: 50/50 green on an idle box, flaky under the load a real CI
  # run carries — job 113285636215, PR #22072). This is the SAME class of
  # gap `assert_recorder_gone` itself closes for process liveness, applied
  # to the DB row it gates on: a bounded retry, not a weakened assertion —
  # an outcome that is NEVER true still fails loudly, naming the value this
  # test actually saw (every call site keeps its own `assert`/`match?` after
  # calling this, so a genuine regression still reds with an honest diff).
  #
  # WIDENED at task-dad9a71f6dcd2f08: this helper's OWN original 1000x10ms
  # (~10s) bound still timed out once in CI (job 113449840671, #22154) —
  # AFTER `assert_recorder_gone` had already confirmed the process gone, so
  # this is the gap this helper exists to close, recurring past its own
  # fix. `shared: true` sandbox mode (data_case.ex) means a committed write
  # is visible to every connection in the SAME transaction with NO
  # replication-style lag, so a genuine COMMIT-VISIBILITY delay should never
  # need more than one scheduler tick — the 10s margin was never about the
  # write being slow to propagate, it is about THIS test process getting
  # SCHEDULED to look again under host-level (not just BEAM-level)
  # contention, which `Process.sleep/1`'s floor-not-ceiling semantics do not
  # bound. Tripled to 3000 tries as the next increment in this fix's own
  # escalation lineage (10s was once ~2s), and the timeout case now reports
  # elapsed wall-clock time explicitly — not a confirmed root-cause fix
  # (reproduction under load did not trigger the race locally), but a
  # widened, honestly-labeled safety margin plus the diagnostic the NEXT
  # recurrence needs to tell "genuinely never arrived" apart from "arrived
  # outside even this margin."
  defp wait_for_session(sid, pred, tries \\ 3000) do
    started_at = System.monotonic_time(:millisecond)
    wait_for_session(sid, pred, tries, started_at)
  end

  defp wait_for_session(sid, pred, tries, started_at) do
    session = StudioChat.get_session(sid)

    cond do
      pred.(session) ->
        session

      tries <= 0 ->
        elapsed = System.monotonic_time(:millisecond) - started_at

        IO.warn(
          "wait_for_session/2 timed out after #{elapsed}ms waiting on #{inspect(sid)} — " <>
            "last observed: #{inspect(session)}"
        )

        session

      true ->
        Process.sleep(10) && wait_for_session(sid, pred, tries - 1, started_at)
    end
  end

  # Non-blocking drain of every chat event already delivered to this (subscribed)
  # process. The Recorder has stopped by call time (assert_recorder_gone), so a
  # short window suffices; returns the events oldest-first.
  defp drain_chat_events(acc \\ []) do
    receive do
      {:claude_chat_event, ev} -> drain_chat_events([ev | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # The W12 tool-removal belt, asserted over a captured argv — mirror of
  # claude_chat_test.exs:1209. `--tools ""`, the exact `--disallowedTools` deny
  # set, and the SAME deny list echoed in the `--settings` JSON (no drift).
  defp assert_w12_belt_intact(args) do
    assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--tools", ""])

    disallowed = args |> Enum.drop_while(&(&1 != "--disallowedTools")) |> Enum.drop(1)
    assert disallowed == CloudPolicy.cloud_disallowed_tools()

    settings_idx = Enum.find_index(args, &(&1 == "--settings"))

    deny =
      args |> Enum.at(settings_idx + 1) |> Jason.decode!() |> get_in(["permissions", "deny"])

    assert deny == CloudPolicy.cloud_disallowed_tools()
  end

  # Whether `pair` (a 2-element list) appears as CONSECUTIVE elements of `args`.
  defp consecutive?(args, pair), do: Enum.chunk_every(args, 2, 1) |> Enum.member?(pair)

  # Read a captured argv, ONE arg per line, PRESERVING empty-string args (the
  # cloud argv carries `--tools ""`). The shim writes `printf '%s\\n' "$@"`, so
  # N args yield N lines each ending in `\\n`; split on `\\n` and drop only the
  # single trailing "" the final newline produces. A plain trim-split would eat
  # the `--tools ""` empty and break the belt check.
  defp read_argv(file) do
    parts = file |> wait_for_file() |> String.split("\n")

    case List.last(parts) do
      "" -> Enum.drop(parts, -1)
      _ -> parts
    end
  end

  defp read_lines(file), do: file |> wait_for_file() |> String.split("\n", trim: true)

  # Unique-across-runs capture path (mirror of claude_chat_test.exs:2039): the
  # OS pid pins the name to this BEAM, rm_rf-before-use belts a stale prior run.
  defp capture_path(kind) do
    file =
      Path.join(
        System.tmp_dir!(),
        "claude_chat_cloud_#{kind}_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.rm_rf(file)
    on_exit(fn -> File.rm_rf(file) end)
    file
  end

  # 400 × 20ms = 8s: under suite load the OS can take past 3s to schedule the
  # fake shell and flush its first write. The happy path returns on poll one.
  #
  # The deadline is DELIBERATELY not raised (#17605 measured that on the sibling
  # file: "moving the clock buys silence, not signal"). What is raised is what a
  # blown deadline SAYS — see `contention_report/1`.
  defp wait_for_file(file, tries \\ 400) do
    cond do
      File.exists?(file) and File.read!(file) != "" -> File.read!(file)
      tries <= 0 -> flunk(contention_report(file))
      true -> Process.sleep(20) && wait_for_file(file, tries - 1)
    end
  end

  # What a blown capture deadline prints. Row task-9ffbd1b42bcf189f
  # classified this file's `capture file never written` red as host contention
  # on the fork/exec'd `sh` stub. Row task-f68536c6c37a2ece CORRECTED that: the
  # reds were a within-test race between turns. The previous turn's provider
  # Session still held its `SessionRegistry` name (inside `terminate/2`) after
  # its Recorder had stopped, so the next turn adopted it and never spawned
  # the stub. The tell was in this very report: the counter's size (18B =
  # `create`+`reuse-fail`) covered only the turns that RAN, so the missing turn
  # never executed at all; it was not slow.
  # `assert_recorder_gone/1` now waits for both names.
  #
  # The report prints the facts that separate "the stub never ran" from "the
  # stub ran and was slow": the sibling captures that DID land, including the
  # invocation counter. Read the counter before calling it contention.
  defp contention_report(file) do
    siblings =
      file
      |> Path.dirname()
      |> Path.join("claude_chat_cloud_*_#{System.pid()}_*")
      |> Path.wildcard()
      |> Enum.map(&"#{Path.basename(&1)} (#{byte_size(File.read!(&1))}B)")

    """
    capture file never written: #{file}

    The `sh` stub did not flush this capture within 8s. Every stub run appends
    one line to the counter, so a counter (size below) that covers only the
    EARLIER turns means this turn's stub NEVER RAN: a turn-handoff race (row
    task-f68536c6c37a2ece, the previous turn's Session still registered), not
    host contention. Only a counter that includes this turn means it ran slow.

    captures this BEAM (#{System.pid()}) DID write:
    #{Enum.map_join(siblings, "\n", &("  " <> &1))}
    """
  end
end
