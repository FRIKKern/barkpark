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
      assert %{cloud_sandbox_id: @sandbox_id} = StudioChat.get_session(sid)
      # …and it was NOT broadcast to viewers and appended NO chat_messages row.
      events1 = drain_chat_events()

      assert Enum.any?(events1, &(&1["type"] == "result")),
             "the result frame must flow to the topic (non-vacuity: the pipeline ran)"

      refute Enum.any?(events1, &(&1["type"] == "bp_sandbox")),
             "the bp_sandbox binding frame must never reach a viewer"

      assert StudioChat.list_messages(sid) == [],
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
      assert %{cloud_sandbox_id: "sbx-stub-1"} = StudioChat.get_session(sid)

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
      session_after = StudioChat.get_session(sid)

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
      session_after = StudioChat.get_session(sid)

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
      session_after = StudioChat.get_session(sid)

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

  # Poll until the Recorder for `sid` is gone (its Session died and it
  # {:stop, :normal}ed). 200 × 10ms = 2s ceiling; the happy path returns fast.
  defp assert_recorder_gone(sid, tries \\ 200) do
    cond do
      Recorder.whereis(sid) == nil -> :ok
      tries <= 0 -> flunk("recorder for #{sid} never terminated")
      true -> Process.sleep(10) && assert_recorder_gone(sid, tries - 1)
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
  defp wait_for_file(file, tries \\ 400) do
    cond do
      File.exists?(file) and File.read!(file) != "" -> File.read!(file)
      tries <= 0 -> flunk("capture file never written: #{file}")
      true -> Process.sleep(20) && wait_for_file(file, tries - 1)
    end
  end
end
