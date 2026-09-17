defmodule Barkpark.CoupledArtifacts do
  @moduledoc """
  Derives, from the workflows themselves, the set of GENERATED artifacts that a
  change inside one fence can force to move in the SAME commit.

  ## The defect this answers

  A lane is fenced to a directory. It edits a source file inside the fence. A
  generated artifact OUTSIDE the fence is derived from that source, a REQUIRED
  gate regenerates the artifact and diffs it, and the commit is therefore only
  correct as a unit — but nothing told the lane the coupling existed. The lane
  ships, the required gate reds, and the red names a file the lane was told it
  may not touch. (task-0f8776aa215d2d4e; worked example PR #18415, where a
  sentence edited in `api/lib/barkpark/plugins/tasks.ex` moved one line of
  `docs/openapi.json`.)

  ## THE RULE IS A PREDICATE, NOT A LIST

  Nothing here enumerates artifacts. A path is a COUPLED GENERATED ARTIFACT iff
  some workflow step both

    1. runs a PRODUCER command, and then
    2. diffs that path against the working tree (`git diff --exit-code` /
       `git diff --quiet`).

  That is the gate's own definition of "generated", read off the gate. A file
  that merely mentions the same string as a generated artifact, or that a
  workflow names only in an `on: paths:` trigger, is NOT swept in — it has no
  producer and no diff step, so the predicate is false for it. This is the
  distinction `docs/cli/fixtures/full-manifest.json` exists to test: it carries
  the same sentences as `docs/openapi.json`, has NO producer anywhere in the
  tree, and doctrine forbids both hand-editing and regenerating it. A rule keyed
  on a shared grep hit sweeps it in. This rule, keyed on the GATE, does not.

  ## THE FENCE RULING (settled 2026-09-15, generalised here)

  Regenerating an out-of-fence GENERATED artifact IS an allowed cross-fence edit
  for the lane whose change caused it. The reason: a generated artifact is not
  another lane's AUTHORED file — it is an OUTPUT of your change. The fence
  follows AUTHORSHIP, not directory. A fence that forced the regen into a second
  PR would leave `main` inconsistent between the two merges, which is a fence
  applied wrongly. The ruling carries a hard bound, and three arms:

    AUTHORED by another lane ........... route it; never touch it.
    MACHINE-WRITTEN .................... ONLY the producer command may write it.
                                         Hand-editing IS the defect, even to
                                         "fix" a one-line drift.
                                         (`docs/openapi.json`, written by
                                         `mix barkpark.openapi`.)
    MACHINE-PROPOSED, HUMAN-COMMITTED .. the tool REFUSES to write and proposes
                                         instead; a human commits the proposed
                                         values, in the SAME commit, with the
                                         derivation quoted. Honouring a tool's
                                         refusal is the OPPOSITE of hand-editing
                                         a generated file. (The
                                         `scripts/pds-elixir-receipt-census.exs`
                                         exclusion anchors — `--routed-rows`
                                         proposes and never writes.)

  Only the MACHINE-WRITTEN arm is derivable from the gates, so only that arm is
  what `derive/1` returns. The other two arms are stated here because a rule
  phrased as "only the producer command may write it" would FORBID the only
  repair the third arm prescribes.

  ## THE PRODUCER IS NAMED AND ITS OUTPUT IS VERIFIED BY SIZE

  Every coupling carries the exact producer command. After regenerating, report
  `git diff --numstat <artifact>`: a regeneration that moves ONE line is a
  RE-PIN; one that moves many is a BURIAL, and only the numstat tells you which.
  Worked example to carry: PR #18415 produced exactly `1  1  docs/openapi.json`
  in a 16,000-line descriptor.

  ## ORDER

  REBASE onto current `origin/main` FIRST, then regenerate. The gates evaluate
  the MERGE, so an artifact regenerated off a stale base is already wrong on
  arrival.
  """

  # The predicate's core: a step that regenerates and then DIFFS a path is
  # declaring that path generated. Defined here because the parser uses it too.
  @diff_re ~r/git\s+diff\s+(--exit-code|--quiet)/

  @type coupling :: %{
          artifacts: [String.t()],
          producer: [String.t()],
          producer_dir: String.t(),
          workflow: String.t(),
          job: String.t(),
          step: String.t(),
          line: pos_integer(),
          gates: [String.t()],
          required?: boolean()
        }

  @doc """
  Derive every coupled generated artifact from the workflows under `repo_root`.

  Returns couplings sorted by workflow then line. Pure over the filesystem: it
  runs nothing and writes nothing.
  """
  @spec derive(String.t()) :: [coupling()]
  def derive(repo_root) do
    required = required_contexts(repo_root)

    repo_root
    |> Path.join(".github/workflows/*.yml")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(&couplings_in_workflow(&1, repo_root, required))
    |> Enum.sort_by(&{&1.workflow, &1.line})
  end

  @doc """
  The required status-check contexts, read from `.github/required-checks.json`.

  An absent or unreadable file yields `[]` — which downgrades every coupling to
  `required?: false` rather than inventing authority the repo did not grant.
  """
  @spec required_contexts(String.t()) :: [String.t()]
  # sobelow_skip ["Traversal.FileModule"]
  # The read target is a FIXED repo-relative path joined onto a caller-supplied
  # root; no user input reaches it. This is a developer tool run from a
  # checkout, never a request path.
  def required_contexts(repo_root) do
    path = Path.join(repo_root, ".github/required-checks.json")

    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      json
      |> get_in(["protection", "required_status_checks", "checks"])
      |> List.wrap()
      |> Enum.map(&Map.get(&1, "context"))
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  @doc """
  Turn couplings into violations, given a function that says which of a
  coupling's artifacts are DIRTY after its producer ran.

  The dirtiness probe is injected so the rule can be tested without running any
  producer, and so the mix task can run the real producers.
  """
  @spec violations([coupling()], (coupling() -> [String.t()])) :: [{coupling(), [String.t()]}]
  def violations(couplings, dirty_fun) when is_function(dirty_fun, 1) do
    couplings
    |> Enum.map(fn c -> {c, dirty_fun.(c)} end)
    |> Enum.reject(fn {_c, dirty} -> dirty == [] end)
  end

  @doc """
  The naive rule this module exists to NOT be: every file in the tree containing
  a given string.

  Exposed so the mutation arm in the test suite can show that the naive rule
  sweeps in `docs/cli/fixtures/full-manifest.json` while `derive/1` does not.
  It is never used to decide anything.
  """
  @spec naive_same_string_rule(String.t(), String.t()) :: [String.t()]
  def naive_same_string_rule(repo_root, needle) do
    {out, status} =
      System.cmd("git", ["grep", "-l", "--fixed-strings", needle, "--", "docs/"],
        cd: repo_root,
        stderr_to_stdout: true
      )

    case status do
      0 -> out |> String.split("\n", trim: true) |> Enum.sort()
      _ -> []
    end
  end

  # ── workflow parsing ──────────────────────────────────────────────────────
  #
  # Line-oriented on purpose: this tree carries no YAML dependency, and the
  # shapes we need (job key, `name:`, `needs:`, `- name:` steps, `run:` blocks)
  # are all unambiguous at fixed indents in GitHub's schema.

  # sobelow_skip ["Traversal.FileModule"]
  # `path` comes from Path.wildcard(".github/workflows/*.yml") under the repo
  # root — an enumeration of the checkout, not an externally supplied name.
  defp couplings_in_workflow(path, repo_root, required) do
    rel = Path.relative_to(path, repo_root)
    lines = path |> File.read!() |> String.split("\n")
    jobs = parse_jobs(lines)
    gate_jobs = gate_closure(jobs, required)

    Enum.flat_map(jobs, fn job ->
      job.steps
      |> Enum.with_index()
      |> Enum.flat_map(fn {step, i} ->
        coupling_from_step(step, Enum.take(job.steps, i), job, rel, gate_jobs, required)
      end)
    end)
  end

  defp coupling_from_step(step, prior, job, rel, gate_jobs, required) do
    run = run_block(step.body)

    case diff_paths(run) do
      [] ->
        []

      raw_paths ->
        gates =
          Enum.filter(required, fn ctx -> job.key in Map.get(gate_jobs, ctx, MapSet.new()) end)

        base = job_dir(job)
        dir = apply_cds(base, run)

        # A step that only DIFFS (no command of its own before the diff) was
        # produced by an earlier step in the same job — `npm run build` then
        # "assert the committed bundle is fresh". Walk back to the nearest step
        # that runs something. Derived by POSITION, never by naming the tool.
        producer =
          case producer_commands(run) do
            [] -> prior |> Enum.reverse() |> Enum.find_value([], &nonempty_producer/1)
            cmds -> cmds
          end

        [
          %{
            artifacts: Enum.map(raw_paths, &resolve(dir, &1)),
            producer: producer,
            producer_dir: base,
            workflow: rel,
            job: job.key,
            step: step.name,
            line: step.line,
            gates: gates,
            required?: gates != []
          }
        ]
    end
  end

  defp nonempty_producer(step) do
    case step.body |> run_block() |> producer_commands() do
      [] -> nil
      cmds -> cmds
    end
  end

  defp job_dir(job), do: normalize(Map.get(job, :working_directory, ".") || ".")

  # Only the shell inside `run: |` is evidence. YAML comments and `if:` keys are
  # prose about the step, not commands it runs — reading them as commands is how
  # a parser invents a producer that never executes.
  defp run_block(body) do
    cond do
      # block scalar: `run: |` then an indented script
      Enum.any?(body, &Regex.match?(~r/^\s*run:\s*\|/, &1)) ->
        body
        |> Enum.drop_while(&(not Regex.match?(~r/^\s*run:\s*\|/, &1)))
        |> Enum.drop(1)
        |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))

      # inline scalar: `run: npm run build`
      true ->
        body
        |> Enum.flat_map(fn l ->
          case Regex.run(~r/^\s*run:\s*(\S.*?)\s*$/, l) do
            [_, cmd] -> [cmd]
            _ -> []
          end
        end)
    end
  end

  defp apply_cds(dir, run) do
    run
    |> Enum.take_while(&(not Regex.match?(@diff_re, &1)))
    |> Enum.reduce(dir, fn line, acc ->
      case Regex.run(~r/^\s*cd\s+(\S+)\s*$/, line) do
        [_, target] -> normalize(Path.join(acc, unquote_scalar(target)))
        _ -> acc
      end
    end)
  end

  defp resolve(".", path), do: normalize(path)
  defp resolve(dir, path), do: normalize(Path.join(dir, path))

  # Path.expand/1 would anchor on the OS cwd; these paths are repo-relative.
  defp normalize(path) do
    path
    |> Path.split()
    |> Enum.reduce([], fn
      ".", acc -> acc
      "..", [prev | rest] when prev != ".." -> rest
      seg, acc -> [seg | acc]
    end)
    |> Enum.reverse()
    |> case do
      [] -> "."
      segs -> Path.join(segs)
    end
  end

  # Jobs live at indent 2; their scalar keys at indent 4; steps at indent 6.
  defp parse_jobs(lines) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce({[], nil}, fn {line, idx}, {done, current} ->
      cond do
        Regex.match?(~r/^  ([A-Za-z0-9_-]+):\s*$/, line) ->
          [_, key] = Regex.run(~r/^  ([A-Za-z0-9_-]+):\s*$/, line)
          {push(done, current), %{key: key, name: nil, needs: [], lines: [], start: idx}}

        current == nil ->
          {done, current}

        true ->
          {done, %{current | lines: [{line, idx} | current.lines]}}
      end
    end)
    |> then(fn {done, current} -> push(done, current) end)
    |> Enum.reverse()
    |> Enum.map(&finish_job/1)
    # `on:`/`env:`/`defaults:` etc. match the job-key shape too; a real job has steps.
    |> Enum.reject(&(&1.steps == [] and &1.name == nil))
  end

  defp push(done, nil), do: done
  defp push(done, job), do: [%{job | lines: Enum.reverse(job.lines)} | done]

  defp finish_job(job) do
    name =
      Enum.find_value(job.lines, fn {l, _} ->
        case Regex.run(~r/^    name:\s*(.+?)\s*$/, l) do
          [_, n] -> unquote_scalar(n)
          _ -> nil
        end
      end)

    needs =
      Enum.find_value(job.lines, fn {l, _} ->
        case Regex.run(~r/^    needs:\s*(.+?)\s*$/, l) do
          [_, n] ->
            n
            |> String.trim_leading("[")
            |> String.trim_trailing("]")
            |> String.split(",")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          _ ->
            nil
        end
      end) || []

    wd =
      Enum.find_value(job.lines, fn {l, _} ->
        case Regex.run(~r/^        working-directory:\s*(.+?)\s*$/, l) do
          [_, d] -> unquote_scalar(d)
          _ -> nil
        end
      end) || "."

    %{
      key: job.key,
      name: name,
      needs: needs,
      working_directory: wd,
      steps: parse_steps(job.lines)
    }
  end

  defp parse_steps(lines) do
    lines
    |> Enum.reduce({[], nil}, fn {line, idx}, {done, current} ->
      case Regex.run(~r/^      - name:\s*(.+?)\s*$/, line) do
        [_, name] ->
          {push_step(done, current), %{name: unquote_scalar(name), line: idx, body: []}}

        _ ->
          cond do
            current == nil -> {done, current}
            Regex.match?(~r/^      - /, line) -> {push_step(done, current), nil}
            true -> {done, %{current | body: [line | current.body]}}
          end
      end
    end)
    |> then(fn {done, current} -> push_step(done, current) end)
    |> Enum.reverse()
  end

  defp push_step(done, nil), do: done
  defp push_step(done, step), do: [%{step | body: Enum.reverse(step.body)} | done]

  defp unquote_scalar(s) do
    s |> String.trim() |> String.trim("\"") |> String.trim("'")
  end

  # ── the predicate ─────────────────────────────────────────────────────────

  @doc false
  def diff_paths(body_lines) do
    body_lines
    |> join_continuations()
    |> Enum.filter(&Regex.match?(@diff_re, &1))
    |> Enum.flat_map(&paths_from_diff_command/1)
    |> Enum.uniq()
  end

  defp paths_from_diff_command(cmd) do
    cmd
    # everything after `||`, `&&`, `;` or `then` belongs to the shell, not the diff
    |> String.split(~r/\|\||&&|;/, parts: 2)
    |> hd()
    |> String.replace(~r/^.*?git\s+diff\s+/, "")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&String.starts_with?(&1, "-"))
    |> Enum.map(&unquote_scalar/1)
    |> Enum.reject(&(&1 == "" or &1 == "--"))
  end

  # The producer is every command the step runs BEFORE its first diff, minus
  # shell plumbing. Derived from position, never from a list of known tasks.
  @plumbing ~w(cd git if then else fi exit echo set true false case esac done for while do)

  @doc false
  def producer_commands(body_lines) do
    body_lines
    |> join_continuations()
    |> Enum.take_while(&(not Regex.match?(@diff_re, &1)))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn l ->
      # `stale=0` is a shell variable, not a producer.
      l == "" or String.starts_with?(l, "#") or String.starts_with?(l, "run:") or
        String.ends_with?(l, ":") or
        Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, l) or
        hd(String.split(l, ~r/\s+/, trim: true) ++ [""]) in @plumbing
    end)
    |> Enum.uniq()
  end

  # `git diff --exit-code -- \` + continuation lines is one command.
  defp join_continuations(lines) do
    lines
    |> Enum.reduce({[], nil}, fn line, {acc, pending} ->
      text = String.trim_trailing(line)
      joined = if pending, do: pending <> " " <> String.trim(text), else: text

      if String.ends_with?(text, "\\") do
        {acc, String.trim_trailing(joined, "\\")}
      else
        {[joined | acc], nil}
      end
    end)
    |> then(fn {acc, pending} -> if pending, do: [pending | acc], else: acc end)
    |> Enum.reverse()
  end

  # ── gate attribution ──────────────────────────────────────────────────────
  #
  # A required context is published by ONE job (its `name:`). A drift step is
  # covered by that context iff its job is that job, or is in the transitive
  # `needs` closure of it.

  defp gate_closure(jobs, required) do
    by_key = Map.new(jobs, &{&1.key, &1})

    Map.new(required, fn ctx ->
      case Enum.find(jobs, &(&1.name == ctx)) do
        nil -> {ctx, MapSet.new()}
        gate -> {ctx, expand(by_key, [gate.key], MapSet.new())}
      end
    end)
  end

  defp expand(_by_key, [], seen), do: seen

  defp expand(by_key, [key | rest], seen) do
    if MapSet.member?(seen, key) do
      expand(by_key, rest, seen)
    else
      needs = by_key |> Map.get(key, %{needs: []}) |> Map.get(:needs, [])
      expand(by_key, needs ++ rest, MapSet.put(seen, key))
    end
  end
end
