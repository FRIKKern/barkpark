defmodule Mix.Tasks.Barkpark.Coupled do
  @shortdoc "What ELSE must move in this commit: derived generated-artifact couplings"

  @moduledoc """
  Answers, mechanically, the question a fenced lane cannot answer from its fence:

      if I change something in api/, what GENERATED artifact OUTSIDE api/ must
      move in the SAME commit, who writes it, and which gate reds if it doesn't?

  Run from `api/`:

      mix barkpark.coupled            # the derived coupling table + the ruling
      mix barkpark.coupled --check    # run every producer; red if an artifact moved

  `--check` is the local mirror of the CI drift gates, derived from the SAME
  workflow text the gates are written in, so it cannot fall out of step with
  them by being a hand-kept list. It exits 1 and names the artifact, the producer
  and the gate when a producer's output differs from what is committed — i.e.
  when your change owed an out-of-fence regeneration and did not pay it. It
  leaves the regenerated files in the working tree: read the diff, check the
  numstat, and commit them WITH the change.

  ## The ruling, in one paragraph, because the next lane will otherwise re-litigate it

  Regenerating an out-of-fence GENERATED artifact IS an allowed cross-fence
  edit for the lane whose change caused it. A generated artifact is not another
  lane's AUTHORED file; it is an OUTPUT of your change, and the fence follows
  AUTHORSHIP rather than directory. The bound: ONLY the producer command may
  write it — hand-editing a generated artifact is itself the defect, even to
  "fix" a one-line drift. A third category exists and this rule must not crush
  it: a tool that REFUSES to write its own fix and PROPOSES values instead is
  asserting that a human must read them, and committing those proposed values in
  the same commit, with the derivation quoted, is the OPPOSITE of hand-editing.

  ## TWO PREDICATES

  A path is listed iff EITHER holds, and the table says which:

    * `regenerate-then-diff` — a workflow step runs a producer and then diffs
      the path (`docs/openapi.json`).
    * `pin-comparison` — a workflow step runs a repo script that compares the
      tree against a COMMITTED pin and prints a `--regen`/`--re-pin` affordance
      (`api/.sobelow-annotation-bindings`, cured by
      `api/scripts/sobelow-inline-overlap-check.sh --regen-bindings-pin`).

  `--check` treats them differently ON PURPOSE. A regenerate-then-diff producer
  is MACHINE-WRITTEN: run it, diff it. A pin producer is
  MACHINE-PROPOSED/regen-on-demand — running it would rewrite the pin and bless
  a pairing nobody read, so `--check` runs the GUARD instead and, if the guard
  reds, NAMES the affordance for a human to run and read.

  See `Barkpark.CoupledArtifacts` for both predicates, the three categories, why
  a file that merely shares a string with a generated artifact is NOT one, and
  the stated blind spot of what NEITHER predicate catches.
  """

  use Mix.Task

  alias Barkpark.CoupledArtifacts

  @requirements []

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [check: :boolean, root: :string])
    root = opts[:root] || repo_root()
    couplings = CoupledArtifacts.derive(root)

    if opts[:check] do
      check(root, couplings)
    else
      report(root, couplings)
    end
  end

  defp report(root, couplings) do
    Mix.shell().info("""
    COUPLED GENERATED ARTIFACTS — derived from #{Path.join(root, ".github/workflows")}

    THE RULING: regenerating an out-of-fence GENERATED artifact is an ALLOWED
    cross-fence edit for the lane whose change caused it — the fence follows
    AUTHORSHIP, not directory, and a generated file is an OUTPUT of your change.
    THE BOUND: only the producer command may write it. Hand-editing a generated
    artifact IS the defect. (Third arm: a tool that refuses to write and PROPOSES
    values is asking a human to read them; committing those, in the same commit,
    with the derivation quoted, is not hand-editing. `mix help barkpark.coupled`.)

    ORDER: rebase onto origin/main FIRST, then regenerate — the gates judge the MERGE.
    AFTER regenerating, report `git diff --numstat <artifact>`: one line is a
    RE-PIN, many lines is a BURIAL, and only the numstat tells you which.
    """)

    for c <- couplings do
      Mix.shell().info("""
      #{if c.required?, do: "REQUIRED", else: "advisory"}  #{kind_label(c.kind)}  #{Enum.join(c.gates, ", ")}
        artifacts : #{Enum.join(c.artifacts, "\n                    ")}
        producer  : #{Enum.join(c.producer, " && ")}   (run from #{c.producer_dir}/)#{guard_line(c)}
        gate      : #{c.workflow}:#{c.line}  job #{c.job}
        step      : #{c.step}
      """)
    end

    Mix.shell().info("""
    #{length(couplings)} coupling(s) derived; #{Enum.count(couplings, & &1.required?)} behind a REQUIRED context.

    #{Enum.count(couplings, &(&1.kind == :regenerate_then_diff))} by regenerate-then-diff, #{Enum.count(couplings, &(&1.kind == :pin_comparison))} by pin-comparison.

    NOT LISTED IS NOT A LIST. A path appears above iff some workflow step runs a
    producer and then diffs that path (predicate 1), or runs a repo script that
    compares the tree against a committed pin and offers to re-pin it
    (predicate 2). A file that merely contains the same sentences as a generated
    artifact satisfies neither, so it is absent by the PREDICATE, not by anyone
    remembering to exclude it — and it must be left alone: no hand-edit, no
    "regenerate for consistency". What NEITHER predicate can see is written
    down: `h Barkpark.CoupledArtifacts` — "WHAT NEITHER PREDICATE CATCHES".
    """)
  end

  defp kind_label(:regenerate_then_diff), do: "regenerate-then-diff"
  defp kind_label(:pin_comparison), do: "pin-comparison"

  defp guard_line(%{kind: :pin_comparison, guard: [g | _]}),
    do: "\n  guard     : #{g}   (what --check runs; the producer above is YOURS to run and READ)"

  defp guard_line(_), do: ""

  defp check(root, couplings) do
    # A pin guard is ~1s and never writes, so it is checked whether or not its
    # context is required — the cost of asking is nil and the red is exact.
    targets = Enum.filter(couplings, &(&1.required? or &1.kind == :pin_comparison))

    Mix.shell().info(
      "coupled --check: #{length(targets)} coupling(s) " <>
        "(#{Enum.count(targets, &(&1.kind == :regenerate_then_diff))} regenerate-then-diff, " <>
        "#{Enum.count(targets, &(&1.kind == :pin_comparison))} pin-comparison)\n"
    )

    violations = CoupledArtifacts.violations(targets, &dirty_artifacts(root, &1))

    if violations == [] do
      Mix.shell().info(
        "OK — every derived producer reproduced its committed artifact byte-for-byte."
      )
    else
      for {c, dirty} <- violations do
        Mix.shell().error("""

        ================================================================
        COUPLED ARTIFACT OUT OF DATE — it must move in THIS commit.

          artifact(s) : #{Enum.join(dirty, ", ")}
          producer    : #{Enum.join(c.producer, " && ")}   #{producer_note(c)}
          gate        : #{c.step}
                        #{c.workflow}:#{c.line} — #{Enum.join(c.gates, ", ")} (REQUIRED)

        This is not someone else's drift and it is not noise: the producer just
        ran on YOUR tree and produced different bytes than what is committed.
        Regenerating is PART OF the change, not a follow-up PR — splitting them
        leaves main inconsistent between the two merges.

        NEXT, in order:
          0. #{next_zero(c)}
          1. git diff --numstat #{Enum.join(dirty, " ")}
             one line moved = a RE-PIN; many = a BURIAL. Read the hunk either way.
          2. git add #{Enum.join(dirty, " ")} and commit it WITH the source change.
        Do NOT hand-edit these files to make the diff go away.
        ================================================================
        """)
      end

      exit({:shutdown, 1})
    end
  end

  # THE TWO ARMS. Predicate 1: run the producer, then diff. Predicate 2: run the
  # GUARD and read its exit code — never the regen, which would rewrite the pin
  # and bless a pairing nobody read.
  defp dirty_artifacts(root, %{kind: :regenerate_then_diff} = c) do
    Enum.each(c.producer, &run_producer(root, &1, c.producer_dir))
    # `add -N` first: a brand-new untracked artifact is invisible to
    # `git diff`, which is how a drift check passes vacuously.
    git(root, ["add", "-N", "--"] ++ c.artifacts)
    dirty(root, c.artifacts)
  end

  defp dirty_artifacts(root, %{kind: :pin_comparison} = c) do
    [cmd | _] = c.guard
    Mix.shell().info("  running guard (never the regen): #{cmd}")
    [exe | args] = String.split(cmd, ~r/\s+/, trim: true)
    {_out, status} = System.cmd(exe, args, cd: root, stderr_to_stdout: true, env: env())
    if status == 0, do: [], else: c.artifacts
  end

  defp run_producer(root, cmd, dir) do
    [exe | args] = String.split(cmd, ~r/\s+/, trim: true)
    Mix.shell().info("  running producer: #{cmd}")
    System.cmd(exe, args, cd: Path.join(root, dir), stderr_to_stdout: true, env: env())
  end

  defp producer_note(%{kind: :pin_comparison}),
    do: "(NOT run — a pin is regen-on-demand; run it yourself and READ the diff)"

  defp producer_note(_), do: "(already run; output is in your tree)"

  defp next_zero(%{kind: :pin_comparison} = c),
    do: "run the producer above — #{Enum.join(c.producer, " && ")} — then:"

  defp next_zero(_), do: "(the producer already ran; its output is in your tree)"

  defp env, do: [{"MIX_ENV", System.get_env("MIX_ENV") || "dev"}]

  defp dirty(root, paths) do
    {out, _} = System.cmd("git", ["diff", "--name-only", "--"] ++ paths, cd: root)
    out |> String.split("\n", trim: true) |> Enum.sort()
  end

  defp git(root, args), do: System.cmd("git", args, cd: root, stderr_to_stdout: true)

  defp repo_root do
    {out, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(out)
  end
end
