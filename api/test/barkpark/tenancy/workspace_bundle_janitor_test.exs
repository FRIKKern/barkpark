defmodule Barkpark.Tenancy.WorkspaceBundleJanitorTest do
  @moduledoc """
  Anti-vacuity is the whole point of this suite.

  A sweep that deletes everything passes a test that only checks "the stale
  file is gone". Every assertion below therefore names BOTH sides: what must
  disappear AND what must survive the same call.
  """
  # async: false — one case sets the node-global `:bundle_spill_dir` env to
  # prove `Janitor.spill_dir/0` reads exactly the engine's config key. That
  # value is read from Application env for the WHOLE node, so serialization is
  # the only thing that stops a concurrent async test from observing the swap
  # (the async-env-seam ratchet enforces exactly this). The janitor's public
  # API has no per-process override for that key, so `async: false` is the
  # honest, minimal isolation — not a widened guard, not an allowlist.
  use ExUnit.Case, async: false

  alias Barkpark.Tenancy.WorkspaceBundle.Archive
  alias Barkpark.Tenancy.WorkspaceBundle.Janitor

  @max_age 3600

  setup do
    dir =
      Path.join([
        System.tmp_dir!(),
        "bp-janitor-test-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir}
  end

  # Seed a file whose mtime is `age_seconds` in the past.
  defp seed(dir, name, age_seconds) do
    path = Path.join(dir, name)
    File.write!(path, "x")

    if age_seconds > 0 do
      File.touch!(path, System.os_time(:second) - age_seconds)
    end

    path
  end

  defp sweep(dir), do: Janitor.sweep(dir: dir, max_age_seconds: @max_age)

  describe "sweep/1 — exactly the abandoned files, and nothing else" do
    test "removes the stale spill while the fresh one and an unrelated file survive", %{dir: dir} do
      stale = seed(dir, "bp-ws-spill-1-documents.copy", @max_age + 600)
      fresh = seed(dir, "bp-ws-spill-2-documents.copy", 10)
      unrelated = seed(dir, "some-other-tool.tar", @max_age + 600)

      assert {:ok, result} = sweep(dir)

      refute File.exists?(stale), "the stale spill must be collected"
      assert File.exists?(fresh), "a spill inside the threshold must survive"
      assert File.exists?(unrelated), "a file outside the prefix contract must never be touched"

      assert result.removed == [stale]
      assert result.kept == 1
    end

    test "collects BOTH prefixes — the tar and the per-table spills", %{dir: dir} do
      tar = seed(dir, "bp-ws-bundle-77.tar", @max_age + 600)
      spill = seed(dir, "bp-ws-spill-77-media_files.copy", @max_age + 600)
      fresh_tar = seed(dir, "bp-ws-bundle-78.tar", 10)

      assert {:ok, result} = sweep(dir)

      refute File.exists?(tar)
      refute File.exists?(spill)
      assert File.exists?(fresh_tar)
      assert Enum.sort(result.removed) == Enum.sort([tar, spill])
    end

    test "a file exactly at the threshold is kept; the cutoff is strictly older-than", %{dir: dir} do
      at_threshold = seed(dir, "bp-ws-spill-3-edge.copy", @max_age)

      assert {:ok, result} = sweep(dir)

      assert File.exists?(at_threshold)
      assert result.removed == []
    end

    test "an empty or missing directory is a clean no-op, not a crash", %{dir: dir} do
      assert {:ok, %{removed: [], kept: 0}} = sweep(dir)
      assert {:ok, %{removed: []}} = sweep(Path.join(dir, "does-not-exist"))
    end
  end

  describe "sweep/1 — the liveness guard" do
    test "a stale spill owned by a LIVE os process survives", %{dir: dir} do
      guarded = seed(dir, "bp-ws-spill-9-live.copy", @max_age + 6000)
      unguarded = seed(dir, "bp-ws-spill-9-orphan.copy", @max_age + 6000)

      # Our own BEAM: unambiguously alive for the duration of this test.
      :ok = Janitor.own(guarded)

      assert {:ok, result} = sweep(dir)

      assert File.exists?(guarded),
             "a file whose owner is still running must survive however stale it looks"

      refute File.exists?(unguarded),
             "the identical file WITHOUT a live owner must still be collected " <>
               "(otherwise the guard is just disabling the sweep)"

      assert result.skipped_live == 1
      assert result.removed == [unguarded]
    end

    test "a stale spill owned by a DEAD os process is collected, sidecar and all", %{dir: dir} do
      path = seed(dir, "bp-ws-spill-10-dead.copy", @max_age + 6000)
      dead_pid = dead_os_pid()
      File.write!(path <> ".owner", Integer.to_string(dead_pid))

      assert {:ok, result} = sweep(dir)

      refute File.exists?(path), "a dead owner must not protect the file"
      refute File.exists?(path <> ".owner"), "the sidecar must go with its subject"
      assert result.removed == [path]
    end

    test "the sidecar is never collected on its own", %{dir: dir} do
      # A fresh file with a stale sidecar: the sidecar matches the same glob,
      # so a naive implementation would delete the ownership marker of a file
      # it correctly decided to keep.
      path = seed(dir, "bp-ws-spill-11-fresh.copy", 10)
      :ok = Janitor.own(path)
      File.touch!(path <> ".owner", System.os_time(:second) - (@max_age + 6000))

      assert {:ok, %{removed: []}} = sweep(dir)

      assert File.exists?(path)
      assert File.exists?(path <> ".owner")
    end

    test "disown/1 drops the marker and re-exposes the file to the sweep", %{dir: dir} do
      path = seed(dir, "bp-ws-spill-12-handover.copy", @max_age + 6000)
      :ok = Janitor.own(path)
      assert {:ok, %{removed: [], skipped_live: 1}} = sweep(dir)

      :ok = Janitor.disown(path)
      assert {:ok, %{removed: [^path]}} = sweep(dir)
      refute File.exists?(path)
    end
  end

  describe "configuration" do
    test "the derived default threshold clears the measured worst case" do
      # Wave 7: ~130 s server-side alone, on a ~941 MB bundle that a 1 MB/s
      # client needs ~941 s more to drain. The default must clear that sum, or
      # it deletes healthy exports mid-send_file.
      assert Janitor.max_age_seconds() > 130 + 941
    end

    test "the spill dir is configurable and is not a bare tmp dir by default" do
      refute Janitor.spill_dir() == System.tmp_dir!()

      # The SAME key the engine's Archive.spill_dir/0 reads — sweep where it
      # writes. (Set here explicitly rather than relying on config.exs, whose
      # default lands on the engine branch, not this one.)
      #
      # RESTORE the prior value, never delete it: config.exs SETS this key and
      # `Archive.spill_dir/0` reads it with `fetch_env!`, so leaving it unset
      # makes every later export in the same run raise ArgumentError. Whether
      # that lands is pure module-ordering luck, which is exactly the shape of
      # flake that took main red on seeds where this module sorts first.
      prior = Application.get_env(:barkpark, :bundle_spill_dir)

      on_exit(fn ->
        if is_nil(prior),
          do: Application.delete_env(:barkpark, :bundle_spill_dir),
          else: Application.put_env(:barkpark, :bundle_spill_dir, prior)
      end)

      Application.put_env(:barkpark, :bundle_spill_dir, "/var/lib/barkpark/spill")

      assert Janitor.spill_dir() == "/var/lib/barkpark/spill"
    end

    test "the engine and the janitor resolve the spill dir through ONE function" do
      # The two used to agree by both spelling `:bundle_spill_dir` in two places
      # — agreement by coincidence, one rename away from a silent divergence no
      # test would catch (pds-w11-janitor-engine-handshake). Now there is a
      # single resolver and this proves BOTH sides ride it: swap the key and the
      # janitor must follow the engine, not merely happen to match it.
      prior = Application.get_env(:barkpark, :bundle_spill_dir)

      on_exit(fn ->
        if is_nil(prior),
          do: Application.delete_env(:barkpark, :bundle_spill_dir),
          else: Application.put_env(:barkpark, :bundle_spill_dir, prior)
      end)

      Application.put_env(:barkpark, :bundle_spill_dir, "/var/lib/barkpark/handshake-probe")

      assert Archive.spill_dir_config() == {:ok, "/var/lib/barkpark/handshake-probe"}
      assert Janitor.spill_dir() == "/var/lib/barkpark/handshake-probe"
    end

    test "the MISSING-key policies stay deliberately different: engine raises, janitor falls back" do
      prior = Application.get_env(:barkpark, :bundle_spill_dir)

      on_exit(fn ->
        if is_nil(prior),
          do: Application.delete_env(:barkpark, :bundle_spill_dir),
          else: Application.put_env(:barkpark, :bundle_spill_dir, prior)
      end)

      Application.delete_env(:barkpark, :bundle_spill_dir)

      assert Archive.spill_dir_config() == :error

      # The engine must FAIL, not quietly pick a directory most likely to be the
      # tmpfs its own assertion exists to refuse.
      assert_raise ArgumentError, ~r/bundle_spill_dir/, fn -> Archive.spill_dir() end

      # The janitor must NOT fail: it is a boot-time `restart: :temporary` task,
      # and a reclaim sweep can never be the thing that breaks a boot.
      assert is_binary(Janitor.spill_dir())
    end

    test "every scratch path the ENGINE builds is a sweep candidate", %{dir: dir} do
      # The regression bar for a real leak: the extraction directory used to be
      # named `members-<int>`, which matches none of the janitor's three
      # prefixes, so a killed import stranded it permanently while the code's
      # own doc claimed the janitor collected it. Asserting on the engine's
      # NAMER (not on a literal retyped here) is what keeps this non-circular.
      scratch = Archive.scratch_path(dir)
      File.mkdir_p!(scratch)
      File.write!(Path.join(scratch, "member.copy"), "payload")
      File.touch!(scratch, System.os_time(:second) - (@max_age + 600))

      survivor = seed(dir, "unrelated.txt", @max_age + 600)

      assert {:ok, result} = sweep(dir)

      refute File.exists?(scratch),
             "an engine-built scratch directory was NOT collected — its prefix is outside " <>
               "the janitor's candidate glob, which is exactly the `members-` leak"

      assert scratch in result.removed

      assert File.exists?(survivor), "the sweep took an unrelated file with it"

      # And the leak itself, pinned: the OLD name is not a candidate, so if the
      # engine ever regresses to a bare `members-` the test above goes red
      # rather than the directory going quietly uncollectable.
      legacy = Path.join(dir, "members-#{System.unique_integer([:positive])}")
      File.mkdir_p!(legacy)
      File.touch!(legacy, System.os_time(:second) - (@max_age + 600))

      assert {:ok, second} = sweep(dir)

      assert File.exists?(legacy),
             "a `members-` directory is NOT sweepable — that is why the engine must not use it"

      refute legacy in second.removed
    end
  end

  describe "supervision" do
    test "child_spec/1 is a temporary one-shot task" do
      spec = Janitor.child_spec([])

      assert spec.id == Janitor
      assert spec.restart == :temporary
      assert {Task, :start_link, [fun]} = spec.start
      assert is_function(fun, 0)
    end

    test "the janitor is wired into the application supervision tree" do
      children = Barkpark.Application.child_specs([], [], [], [])
      assert Janitor in children
    end
  end

  # An OS pid that is reliably gone: spawn a real process, capture its pid
  # WHILE IT IS STILL ALIVE, then kill it and wait for the OS to reap it.
  # Picking an arbitrary high number would make this test's meaning depend on
  # the host's pid allocation.
  #
  # Spawning `true`/`echo` and reading `Port.info(port, :os_pid)` afterwards
  # races the exit: on a fast box the child is already gone and the port
  # closed, so `Port.info/2` returns nil and the read blows up with a
  # MatchError. A long-lived `sleep` keeps the port open so the pid read is
  # deterministic; we then SIGKILL it ourselves and confirm it is reaped, so
  # the returned pid is dead by construction rather than by timing.
  defp dead_os_pid do
    exe =
      System.find_executable("sleep") || flunk("no `sleep` executable to build a dead pid from")

    port = Port.open({:spawn_executable, exe}, [:binary, args: ["60"]])

    pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 -> os_pid
        other -> flunk("could not read a live os pid for the helper process: #{inspect(other)}")
      end

    {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    # The BEAM waitpid()s the child on SIGCHLD, so the zombie is reaped without
    # our help; closing the port just releases the port resource. It may have
    # auto-closed already the instant the child died, so this is best-effort.
    if Port.info(port), do: Port.close(port)

    wait_until_reaped(pid, 100)
    assert is_integer(pid) and pid > 0
    pid
  end

  defp wait_until_reaped(pid, 0), do: flunk("os pid #{pid} was never reaped")

  defp wait_until_reaped(pid, attempts) do
    case System.cmd("ps", ["-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(20)
        wait_until_reaped(pid, attempts - 1)

      _ ->
        :ok
    end
  end
end
