defmodule Barkpark.PdsResidueLensTest do
  @moduledoc """
  The PDS status-only residue lens (`scripts/pds-status-only-residue.exs`) has
  had exit codes since wave 41 and no job that runs them. This case is the job:
  `api/test/**` rides the already-required `Elixir gate` context, so an ExUnit
  case that shells the lens's `--selftest` wires the instrument to a required
  gate without touching a single byte of `.github/`.

  ## Why `System.cmd` and not `Code.require_file`

  The repo's prior art for shelling a script from a test
  (`api/test/barkpark/async_global_seam_guard_test.exs:24`) uses
  `Code.require_file`. It does not transfer: the residue lens is a self-running
  script that ends in `System.halt(code)`, so requiring it would halt the WHOLE
  ExUnit suite at the lens's chosen exit code. It has to be a subprocess.

  ## Why the assertion is on prose, not on an arm count

  `SELFTEST GREEN — exit 0` is the lens's own verdict sentence. The arm count
  (15 today) moves whenever somebody adds an honest arm, which is the most
  likely innocent reason for this case to red — so it is not asserted on.

  ## Why the fail-demo is mandatory

  Wave 36 R5 pinned that a gate on the OTHER instrument's `--selftest` would be
  the purest vacuous green available: that census silently ignores unknown
  ARGV, so `--selftest` there runs the ordinary path and exits 0 regardless.
  The lens differs only because `Argv` carries a real `@known_flags` allowlist
  that REFUSES unknown flags. That difference is PROVEN here, not asserted: a
  one-token mutant of the lens must exit 1 with `SELFTEST RED`.

  `async: false`: the case shells a subprocess that writes a fixture tree into
  `System.tmp_dir!/0` and burns ~0.6s of CPU; it has no business racing the
  async lane.
  """
  use ExUnit.Case, async: false

  # The "../../../scripts/…" STRING LITERAL is load-bearing, not cosmetic:
  # scripts/elixir-path-escape-check.sh resolves exactly these literals to build
  # the path set elixir.yml dispatches on. Without it (and its matching
  # ELIXIR_TEST_ONLY_PATHS entry) a PR touching ONLY the lens would compute
  # changes.outputs.test == 'false', mix-test would be LEGITIMATELY skipped, and
  # the instrument's own guard would not run on the very PR that changed it.
  @lens_rel "../../../scripts/pds-status-only-residue.exs"

  # A ONE-TOKEN mutant: the write-classifier's `Repo` recognition. It makes the
  # "Repo.update_all => write" arm answer false, and nothing else — the fixture
  # arms route through the mutation-vocab branch, so the lens still runs to
  # completion and reds on its own verdict rather than crashing.
  @mutant_from "last == :Repo and f in @write_calls"
  @mutant_to "last == :NotRepo and f in @write_calls"

  setup_all do
    lens = Path.expand(@lens_rel, __DIR__)

    unless File.regular?(lens) do
      flunk(
        "the gate is pointed at nothing: #{lens} does not exist. " <>
          "Do not skip this test — a skip here is D26 (green fixtures executed by nothing). " <>
          "Fix the path or delete the instrument, but never both quietly."
      )
    end

    elixir =
      System.find_executable("elixir") ||
        flunk(
          "the gate is pointed at nothing: no `elixir` executable on PATH, so the residue " <>
            "lens's --selftest cannot be run. Failing loud rather than skipping."
        )

    {:ok, lens: lens, elixir: elixir, root: Path.expand("../../..", __DIR__)}
  end

  test "the residue lens's --selftest is GREEN", ctx do
    {out, rc} =
      System.cmd(ctx.elixir, [ctx.lens, "--selftest"],
        cd: ctx.root,
        stderr_to_stdout: true
      )

    assert rc == 0, "expected `elixir #{@lens_rel} --selftest` to exit 0, got #{rc}:\n#{out}"

    assert out =~ "SELFTEST GREEN — exit 0",
           "the lens exited 0 without printing its own green verdict — an exit code alone is " <>
             "not a receipt (the epic's law since wave 22). Output:\n#{out}"
  end

  test "the gate CAN red: a one-token mutant of the lens exits 1 with SELFTEST RED", ctx do
    source = File.read!(ctx.lens)

    assert String.contains?(source, @mutant_from),
           "the mutation anchor #{inspect(@mutant_from)} is gone from the lens, so this " <>
             "fail-demo proves nothing. Re-anchor it on a live one-token site rather than " <>
             "deleting the demo."

    mutant_dir =
      Path.join(
        System.tmp_dir!(),
        "pds-residue-lens-mutant-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(mutant_dir)
    on_exit(fn -> File.rm_rf!(mutant_dir) end)

    mutant = Path.join(mutant_dir, "pds-status-only-residue.exs")
    File.write!(mutant, String.replace(source, @mutant_from, @mutant_to, global: false))

    {out, rc} =
      System.cmd(ctx.elixir, [mutant, "--selftest"], cd: ctx.root, stderr_to_stdout: true)

    assert rc == 1,
           "a mutated lens exited #{rc}; the --selftest cannot distinguish a broken " <>
             "classifier from a working one, which makes the green above vacuous.\n#{out}"

    assert out =~ "SELFTEST RED",
           "the mutant exited 1 without printing SELFTEST RED — the exit code did not descend " <>
             "from the arms. Output:\n#{out}"
  end

  test "the lens REFUSES an unknown flag — the allowlist that makes --selftest meaningful", ctx do
    {out, rc} =
      System.cmd(ctx.elixir, [ctx.lens, "--not-a-real-flag"],
        cd: ctx.root,
        stderr_to_stdout: true
      )

    assert rc == 2,
           "expected the lens to REFUSE an unknown flag with exit 2, got #{rc}. Wave 36 R5 " <>
             "pinned that the sibling census silently ignores unknown ARGV; if this lens ever " <>
             "does the same, its --selftest stops being a selftest.\n#{out}"

    assert out =~ "unknown flag --not-a-real-flag", out
  end
end
