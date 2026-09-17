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

  ## TWO RULES, BOTH PREDICATES, NEITHER A LIST

  Nothing here enumerates artifacts. A path is a COUPLED GENERATED ARTIFACT iff
  EITHER predicate holds.

  **PREDICATE 1 — REGENERATE-THEN-DIFF.** Some workflow step both

    1. runs a PRODUCER command, and then
    2. diffs that path against the working tree (`git diff --exit-code` /
       `git diff --quiet`).

  **PREDICATE 2 — PIN COMPARISON.** Some workflow step runs a SCRIPT in this
  repo, and that script

    1. resolves a variable to a COMMITTED file (the file exists in the checkout)
       and reads it as the expected value,
    2. can WRITE that same file (`cp`/`mv`/`tee`/`>` onto it), and
    3. accepts, and PRINTS beside `$0` as the cure, a long option in the
       re-pin vocabulary (`--regen...` / `--re-pin...` / `--repin...` /
       `--update-...`).

  A guard of that shape never regenerates-and-diffs: it compares the tree
  against the committed pin and hands you the affordance. Predicate 1 is
  structurally blind to it, which is the whole of task-c5b0e402137a2d4f --
  measured on PR #19098, where two inline sobelow waivers added to THIS file
  reddened `api/scripts/sobelow-inline-overlap-check.sh` and the cure was
  `--regen-bindings-pin` rewriting `api/.sobelow-annotation-bindings`. Predicate
  2's producer is therefore `<script> <affordance>`, and it is
  MACHINE-PROPOSED/regen-on-demand: `--check` runs the GUARD, never the regen,
  because running the regen would silently bless a pairing nobody read.

  ## WHAT NEITHER PREDICATE CATCHES (the stated blind spot)

    * PREDICATE 1 catches an artifact a gate REGENERATES AND DIFFS in the
      workflow YAML itself -- `docs/openapi.json`, the golden-parity fixtures.
      It reads only `.github/workflows/*.yml`.
    * PREDICATE 2 catches a committed PIN/baseline a workflow-invoked script
      compares against and offers to re-pin -- `api/.sobelow-annotation-bindings`
      via `--regen-bindings-pin`. It descends ONE level: workflow step -> the
      `.sh` files that step names.
    * NEITHER catches: (a) a coupling that lives entirely inside a gate whose
      step runs a non-shell entry point (a mix task, a node script, a composite
      action) -- the descent is `.sh`-only; (b) a script invoked INDIRECTLY, by
      another script the workflow names, since there is no transitive descent;
      (c) a pin whose cure the script does not print beside `$0`, or whose
      option is spelled outside the re-pin vocabulary (`--bless`, `--accept`) --
      predicate 2 keys on the AFFORDANCE VOCABULARY, and a new verb is a new
      blind spot until the vocabulary grows; (c2) WHICH ARM of a multi-arm
      script reds — the pin is attributed to the SCRIPT, not to the arm, so
      `--check` runs the command the workflow step runs and, on a red, names
      that script's cure. For a script carrying several orthogonal ratchets
      (`sobelow-baseline-staleness-check.sh` has three) the red may belong to a
      different arm than the pin, and its output, not the named cure, is the
      thing to read; (d) a coupling enforced only by
      review or by prose, with no executing step at all; (e) a pin file that is
      absent from the checkout, since conjunct 1 requires the committed file to
      EXIST -- a deleted pin reads as "no coupling", not as a violation.
      `api/.sobelow-skips` is deliberately NOT swept in: it is read by both
      sobelow scripts but neither WRITES it and neither prints a re-pin cure for
      it, so conjuncts 2 and 3 are false. That absence is by predicate, not by
      anyone remembering to exclude it.

  A file
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
          kind: :regenerate_then_diff | :pin_comparison,
          artifacts: [String.t()],
          guard: [String.t()],
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

    workflows =
      repo_root
      |> Path.join(".github/workflows/*.yml")
      |> Path.wildcard()
      |> Enum.sort()

    regen = Enum.flat_map(workflows, &couplings_in_workflow(&1, repo_root, required))

    pinned =
      workflows
      |> Enum.flat_map(&pin_couplings_in_workflow(&1, repo_root, required))
      # The same script is named by several steps in a job (a `--selftest` arm
      # and the bare guard). They declare the SAME pin; keep the invocation with
      # the FEWEST extra arguments, which is the guard that actually judges the
      # tree. Deduped by (artifact, producer), never by remembering a step name.
      |> Enum.sort_by(&{length(hd(&1.guard) |> String.split(" ")), &1.workflow, &1.line})
      |> Enum.uniq_by(&{&1.artifacts, &1.producer})

    Enum.sort_by(regen ++ pinned, &{&1.workflow, &1.line})
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

  defp couplings_in_workflow(path, repo_root, required) do
    rel = Path.relative_to(path, repo_root)
    lines = read_lines(path)
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
            kind: :regenerate_then_diff,
            guard: [],
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

  # ── PREDICATE 2: the pin comparison ───────────────────────────────────────
  #
  # A workflow step names a `.sh` in this repo. That script is a PIN GUARD iff it
  # resolves a variable to a COMMITTED file, reads it as the expected value, can
  # write it, and prints a re-pin option beside `$0` as the cure. Everything
  # below is read off the script's own text; nothing here names a path.

  # The affordance VOCABULARY. A verb outside it is a stated blind spot, not a
  # silent one — see the moduledoc.
  @repin_vocab ~r/^--(re-?gen|re-?pin|update)[a-z0-9-]*$/

  defp pin_couplings_in_workflow(path, repo_root, required) do
    rel = Path.relative_to(path, repo_root)
    jobs = path |> read_lines() |> parse_jobs()
    gate_jobs = gate_closure(jobs, required)

    Enum.flat_map(jobs, fn job ->
      dir = job_dir(job)

      gates =
        Enum.filter(required, fn ctx -> job.key in Map.get(gate_jobs, ctx, MapSet.new()) end)

      Enum.flat_map(job.steps, fn step ->
        step.body
        |> run_block()
        |> script_invocations(dir, repo_root)
        |> Enum.flat_map(fn {script_rel, argv} ->
          Enum.map(pin_declarations(repo_root, script_rel), fn decl ->
            %{
              kind: :pin_comparison,
              artifacts: [decl.artifact],
              producer: [String.trim("bash #{script_rel} #{decl.affordance}")],
              guard: [String.trim(Enum.join(["bash", script_rel | argv], " "))],
              producer_dir: ".",
              workflow: rel,
              job: job.key,
              step: step.name,
              line: step.line,
              gates: gates,
              required?: gates != []
            }
          end)
        end)
      end)
    end)
  end

  # Every `*.sh` a run block names, with the arguments that follow it. Resolved
  # against the job dir first, then the repo root — a step whose job carries a
  # working-directory still names the script from one of those two places.
  defp script_invocations(run, dir, repo_root) do
    run
    |> join_continuations()
    |> Enum.flat_map(fn line ->
      tokens = line |> String.trim() |> String.split(~r/\s+/, trim: true)

      case Enum.split_while(tokens, &(not script_token?(&1))) do
        {_, []} ->
          []

        {_, [tok | rest]} ->
          case resolve_script(tok, dir, repo_root) do
            nil -> []
            script_rel -> [{script_rel, Enum.take_while(rest, &(not shell_break?(&1)))}]
          end
      end
    end)
    |> Enum.uniq()
  end

  defp script_token?(tok), do: String.ends_with?(unquote_scalar(tok), ".sh")

  defp shell_break?(tok), do: tok in ["&&", "||", ";", "|", ">", ">>", "2>&1"]

  defp resolve_script(tok, dir, repo_root) do
    candidate =
      tok
      |> unquote_scalar()
      |> String.replace("$GITHUB_WORKSPACE/", "")
      |> String.replace("${GITHUB_WORKSPACE}/", "")

    if String.contains?(candidate, "$") do
      nil
    else
      [resolve(dir, candidate), normalize(candidate)]
      |> Enum.uniq()
      |> Enum.find(&File.regular?(Path.join(repo_root, &1)))
    end
  end

  @doc """
  The pin declarations a script makes: `%{artifact:, affordance:, var:}` per
  committed file it guards.

  Public so the mutation arms can prove the parser is NON-UNIFORM — it must
  return `[]` for scripts of every other shape, or it is measuring nothing.
  """
  @spec pin_declarations(String.t(), String.t()) :: [
          %{artifact: String.t(), affordance: String.t(), var: String.t()}
        ]
  def pin_declarations(repo_root, script_rel) do
    abs = Path.join(repo_root, script_rel)

    if File.regular?(abs) do
      lines = read_lines(abs)
      cures = cure_flags(lines)

      if cures == [] do
        []
      else
        vars = script_vars(lines, Path.dirname(script_rel))

        for {var, value} <- Enum.sort(vars),
            File.regular?(Path.join(repo_root, value)),
            reads_var?(lines, var),
            writes_var?(lines, var) do
          flag = nearest_cure(cures, lines, var)
          %{artifact: value, affordance: cure_invocation(lines, flag), var: var}
        end
      end
    else
      []
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # Every caller passes a path this module derived itself: Path.wildcard over
  # `.github/workflows/` under a caller-supplied checkout root, or a `*.sh`
  # token read out of a workflow's own text. No request data reaches here.
  defp read_lines(path), do: path |> File.read!() |> String.split("\n")

  # A long option the script's own argument parser accepts AND prints beside
  # `$0` as the cure. Both halves matter: a `case` arm alone is a flag nobody is
  # told about, and a `$0` line alone can be prose about another tool.
  defp cure_flags(lines) do
    arms =
      lines
      |> Enum.flat_map(fn l ->
        Regex.scan(~r/^\s*(--[a-z0-9-]+)[\s|)]/, l) |> Enum.map(&Enum.at(&1, 1))
      end)
      |> MapSet.new()

    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn {l, i} ->
      if String.contains?(l, "$0") do
        ~r/--[a-z0-9-]+/
        |> Regex.scan(l)
        |> Enum.map(&hd/1)
        |> Enum.filter(&(MapSet.member?(arms, &1) and Regex.match?(@repin_vocab, &1)))
        |> Enum.map(&{&1, i})
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  # With more than one cure flag in a script, pair each pin with the cure whose
  # printed line sits nearest a line mentioning that pin's variable. Derived by
  # POSITION, never by matching the flag's name against the file's.
  defp nearest_cure([{flag, _}], _lines, _var), do: flag

  defp nearest_cure(cures, lines, var) do
    mentions =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {l, _} -> Regex.match?(var_re(var), l) end)
      |> Enum.map(&elem(&1, 1))

    {flag, _} =
      Enum.min_by(cures, fn {_f, i} ->
        Enum.min(Enum.map(mentions, &abs(&1 - i)), fn -> 1_000_000 end)
      end)

    flag
  end

  # The cure a script prints can carry arguments — `$0 --regen-tokens
  # api/deps/sobelow`. Take the LITERAL ones (a `$tree` is the script's own
  # variable and cannot be resolved from here); prefer the printed line that
  # supplies them, so the producer is runnable rather than merely named.
  defp cure_invocation(lines, flag) do
    lines
    |> Enum.filter(&(String.contains?(&1, "$0") and String.contains?(&1, flag)))
    |> Enum.map(fn l ->
      l
      |> String.split(flag, parts: 2)
      |> List.last()
      |> String.split(~r/["#]/, parts: 2)
      |> hd()
      |> String.split(~r/\s+/, trim: true)
      |> Enum.take_while(&(not String.contains?(&1, "$")))
    end)
    |> Enum.find([], &(&1 != []))
    |> then(fn args -> String.trim(Enum.join([flag | args], " ")) end)
  end

  defp var_re(var), do: ~r/\$\{?#{Regex.escape(var)}\b/

  @read_verbs ~w(diff cmp grep cat sed awk sort head tail wc comm)

  defp reads_var?(lines, var) do
    re = ~r/\b(#{Enum.join(@read_verbs, "|")})\b[^\n]*\$\{?#{Regex.escape(var)}\b/
    Enum.any?(lines, &Regex.match?(re, &1))
  end

  defp writes_var?(lines, var) do
    v = Regex.escape(var)
    cp = ~r/\b(cp|mv|tee)\b[^\n]*\$\{?#{v}\}?"?\s*$/
    redirect = ~r/>\s*"?\$\{?#{v}\b/
    Enum.any?(lines, &(Regex.match?(cp, &1) or Regex.match?(redirect, &1)))
  end

  # Top-level `NAME=...` assignments, resolved as far as this file can resolve
  # them. An RHS that still carries an unexpanded `$` is DROPPED: a half-resolved
  # path would be matched against the filesystem and answer "no such file",
  # which reads as "no coupling" — the failure this row exists to remove.
  defp script_vars(lines, script_dir) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case Regex.run(~r/^([A-Z][A-Z0-9_]*)=(.*)$/, line) do
        [_, name, rhs] ->
          case resolve_rhs(rhs, acc, script_dir) do
            nil -> acc
            value -> Map.put(acc, name, value)
          end

        _ ->
          acc
      end
    end)
  end

  @script_root_re ~r/^\$\(cd\s+--\s+"\$\(dirname\s+--\s+"\$\{BASH_SOURCE\[0\]\}"\)([^"]*)"\s*&&\s*pwd\)$/
  @cd_pwd_re ~r/^\$\(cd\s+--\s+"([^"]+)"\s*&&\s*pwd\)$/
  @default_re ~r/^\$\{[A-Z][A-Z0-9_]*:-(.*)\}$/

  defp resolve_rhs(rhs, vars, script_dir) do
    rhs = rhs |> String.trim() |> unquote_scalar()

    cond do
      m = Regex.run(@script_root_re, rhs) ->
        normalize(Path.join(script_dir, Enum.at(m, 1)))

      m = Regex.run(@cd_pwd_re, rhs) ->
        m |> Enum.at(1) |> expand_vars(vars) |> finish_path()

      m = Regex.run(@default_re, rhs) ->
        m |> Enum.at(1) |> unquote_scalar() |> expand_vars(vars) |> finish_path()

      true ->
        rhs |> expand_vars(vars) |> finish_path()
    end
  end

  defp expand_vars(nil, _vars), do: nil

  defp expand_vars(text, vars) do
    Enum.reduce(vars, text, fn {name, value}, acc ->
      acc
      |> String.replace("${#{name}}", value)
      |> String.replace("$#{name}", value)
    end)
  end

  defp finish_path(nil), do: nil

  defp finish_path(text) do
    cond do
      String.contains?(text, "$") -> nil
      text == "" or text == "." -> nil
      String.contains?(text, " ") -> nil
      true -> normalize(text)
    end
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
