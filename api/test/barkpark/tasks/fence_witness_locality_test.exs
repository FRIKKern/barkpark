defmodule Barkpark.Tasks.FenceWitnessLocalityTest.Scan do
  @moduledoc """
  The instrument behind `Barkpark.Tasks.FenceWitnessLocalityTest`: pure AST
  reads, no database, no regex over source text.

  * `refusal_terms/2` parses a fence's SOURCE and returns every refusal term it
    can return — the head atom of each literal `{:error, :atom}` /
    `{:error, {:atom, ...}}` inside a `def`/`defp` body. Comments, `@doc`
    strings and `@spec`/`@type` unions are not tuples in the AST, so they are
    never counted. `{:error, reason}` pass-throughs (a variable) are not
    refusals of THIS module and are skipped.
  * `witnessed_terms/2` parses one TEST file and returns the refusal terms it
    asserts inside a `test` block — but only if the same file calls one of the
    fence's entry points (so an atom asserted about some OTHER guard that
    happens to share the name is not read as coverage of this one).
  """

  @doc """
  `[{head_atom, {def_name, def_line}}]` for every refusal `source` returns (all
  defs, or only `{:functions, names}`), first occurrence per atom.
  """
  def refusal_terms(source, scope \\ :module) when is_binary(source) do
    ast = Code.string_to_quoted!(source, columns: false)

    ast
    |> defs()
    |> Enum.filter(fn {name, _line, _body} ->
      case scope do
        :module -> true
        {:functions, names} -> name in names
      end
    end)
    |> Enum.flat_map(fn {name, line, body} ->
      body |> error_literals() |> Enum.map(&{&1, {name, line}})
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  @doc "Refusal head atoms asserted in `test` blocks of `test_source`, if it calls an entry."
  def witnessed_terms(test_source, entries) when is_binary(test_source) do
    ast = Code.string_to_quoted!(test_source, columns: false)

    if calls_entry?(ast, entries) do
      ast |> test_bodies() |> Enum.flat_map(&error_literals/1) |> Enum.uniq()
    else
      []
    end
  end

  defp defs(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [head | rest]} = node, acc when kind in [:def, :defp] ->
          {node, [{def_name(head), meta[:line], rest} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp def_name({:when, _, [head | _]}), do: def_name(head)
  defp def_name({name, _, _}) when is_atom(name), do: name

  defp test_bodies(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:test, _, [_name | rest]} = node, acc when rest != [] -> {node, [rest | acc]}
        node, acc -> {node, acc}
      end)

    acc
  end

  defp calls_entry?(ast, entries) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, segs}, fun]}, _, args} = node, acc when is_list(args) ->
          {node, acc or {List.last(segs), fun} in entries}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp error_literals(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:error, term} = node, acc ->
          case head_atom(term) do
            nil -> {node, acc}
            atom -> {node, [atom | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    acc |> Enum.reverse() |> Enum.uniq()
  end

  defp head_atom(atom) when is_atom(atom) and atom not in [nil, true, false], do: atom
  defp head_atom({atom, _}) when is_atom(atom) and atom not in [nil, true, false], do: atom

  defp head_atom({:{}, _, [atom | _]}) when is_atom(atom) and atom not in [nil, true, false],
    do: atom

  defp head_atom(_), do: nil
end

defmodule Barkpark.Tasks.FenceWitnessLocalityTest do
  @moduledoc """
  WHERE A FENCE ARM'S WITNESS MUST LIVE (task-888cded6b75503ee).

  ## The rule

  A refusal arm of a claim/lease fence counts as COVERED only when a test file
  in the fence's HOME TEST DIRECTORY asserts it. The home directory is the
  fence source's directory with `lib/` swapped for `test/`, NOT recursive:
  `lib/barkpark/tasks/claim_fence.ex` -> `test/barkpark/tasks/*_test.exs`,
  `lib/barkpark/cycle_fleet.ex` -> `test/barkpark/*_test.exs`. "Asserts it"
  means: the file calls one of the fence's named entry points, and some `test`
  block in it holds the literal `{:error, :arm}` / `{:error, {:arm, ...}}`.

  A witness anywhere else does NOT count by default, however real it is.

  ## Why

  Two honest readings of "is this arm covered?" disagreed on
  `ClaimFence.verify/2` (task-c9361be669b85c74 / PR #19900): at file scope
  three arms had no red-capable test; at caller-corpus scope they did, in
  `studio_chat/runtime_usage_test.exs`, via `CycleFleet.prepare_runtime_attempt`.
  Both were true. The scope decides, so it is named here: the suite that owns a
  witness is the suite whose module gets refactored with it. A witness in the
  fence's home directory moves only when the fence's own context moves; a
  witness in another context's suite is disarmed, silently, by a refactor of
  THAT context — nobody editing `RuntimeUsage` is reading `ClaimFence`'s cond.
  So corpus-scope coverage is real coverage that nobody can see; home-scope
  coverage is coverage the fence's owners can see and are guarded by.

  ## When end-to-end IS the right home (the explicit exemption)

  Some arms are private to an orchestration module and only reachable through
  a fixture another suite already builds (`CycleFleet`'s
  `:runtime_attempt_conflict` arm, reached only by `runtime_usage_test.exs`).
  Forcing a home duplicate of that fixture is the rule that "reds on correct
  code" and gets waived. Those arms are listed in the fence's `exempt` map as
  `{:end_to_end, "<test file>", why}` — named, never a silent skip — and the
  guard then asserts THAT named file still witnesses the arm. An end-to-end
  witness stops being invisible: refactor it away and this file reds, naming
  the arm and the file.

  An exemption is only as true as the measurement behind it. The guard checks
  the named file at the (fence, term) level; whether that assertion actually
  reds for THIS arm (and is not masked by another guard returning the same
  atom) is a mutation fact, established when the exemption is written. Two of
  the three atoms `runtime_usage_test.exs` asserts through `CycleFleet` were
  masked exactly that way, which is why they got home tests instead.

  `{:by_design, why}` is the other exemption: a CAS-loss arm (`:stale` from a
  rev-CAS write under the per-task advisory lock) cannot be reached by a
  single-process test without injecting a concurrent writer. It is listed,
  and the guard still reds if the listed arm no longer exists (stale
  exemption).

  ## Granularity (the honest limit)

  The unit is (fence, refusal term), derived from source. Two arms of ONE
  fence returning the SAME term (e.g. `Close`'s terminal-row lost race and its
  CAS-loss, both `:stale_claim`) are one unit here; the arm-level measurement
  is the mutation table in the PR that introduced this file. A new arm with a
  NEW term is picked up with no edit to this file.

  ## Out of scope, by design

  * `Barkpark.Tasks.Claim` admission gates (`:criteria_unstated`,
    `:not_ready`, `:blocked_by_unsatisfied_deps`, `{:resource_conflict, _}`,
    `{:invalid_execution_policy, _}`) — they decide whether a lease may be
    ACQUIRED, not whether a caller matches a lease it holds.
  * `Barkpark.ChatHosts.ExecutionLease` (an Ecto schema, no refusal arms) and
    `BarkparkWeb.PaperCanvasLease` (a signed-token LiveView lease; returns
    `:pending`/`:blocked`/`:unsupported`, never `{:error, atom}`).
  """

  use ExUnit.Case, async: true

  alias Barkpark.Tasks.FenceWitnessLocalityTest.Scan

  @api_root Path.expand("../../..", __DIR__)

  @cas_loss "CAS-loss (`:stale` from the rev-CAS write under the per-task advisory " <>
              "lock) — unreachable from a single-process test without a concurrent writer"

  @runtime_usage "test/barkpark/studio_chat/runtime_usage_test.exs"
  @runtime_attempt_fixture "private cond of CycleFleet (verify_runtime_attempt_claim/3); reached " <>
                             "only through the wave + assignment + runtime-attempt fixture that " <>
                             "suite already builds"

  # Each entry is one claim/lease fence. `scope` is `:module` (every refusal
  # term the module returns — a new arm is picked up automatically) unless the
  # module is a grab-bag whose other functions are not fences, in which case
  # the fence functions are named.
  @fences [
    %{
      name: "Tasks.ClaimFence",
      source: "lib/barkpark/tasks/claim_fence.ex",
      scope: :module,
      entries: [{:ClaimFence, :verify}, {:Tasks, :verify_claim_fence}],
      exempt: %{}
    },
    %{
      name: "Tasks.Release",
      source: "lib/barkpark/tasks/release.ex",
      scope: :module,
      entries: [{:Tasks, :release}, {:Release, :release}],
      exempt: %{stale_claim: {:by_design, @cas_loss}}
    },
    %{
      name: "Tasks.Pulse",
      source: "lib/barkpark/tasks/pulse.ex",
      scope: :module,
      entries: [{:Tasks, :pulse_by_id}, {:Pulse, :pulse}],
      exempt: %{stale_claim: {:by_design, @cas_loss}}
    },
    %{
      name: "Tasks.Renew",
      source: "lib/barkpark/tasks/renew.ex",
      scope: :module,
      entries: [{:Tasks, :renew_lease_by_id}, {:Renew, :renew}],
      exempt: %{stale_claim: {:by_design, @cas_loss}}
    },
    %{
      name: "Tasks.Close",
      source: "lib/barkpark/tasks/close.ex",
      scope: :module,
      entries: [
        {:Tasks, :close},
        {:Close, :close},
        {:Close, :close_with_receipt},
        {:Tasks, :reconcile_merge_gate},
        {:Close, :reconcile_merge_gate}
      ],
      exempt: %{stale_rev: {:by_design, @cas_loss}}
    },
    %{
      name: "Tasks.Internal (holder gates)",
      source: "lib/barkpark/tasks/internal.ex",
      scope: {:functions, [:check_holder, :close_holder]},
      entries: [
        {:Internal, :check_holder},
        {:Internal, :close_holder},
        {:Tasks, :release},
        {:Tasks, :pulse_by_id},
        {:Tasks, :stamp},
        {:Tasks, :close}
      ],
      exempt: %{}
    },
    %{
      # Scoped to the ONE cond the filing named. Its sibling
      # `current_runtime_attempt_attribution/1` is NOT listed: its `with`
      # fall-through returns `:task_not_claimed`, the same term ClaimFence
      # returns through `prepare_runtime_attempt`, so an atom-level witness in
      # runtime_usage_test.exs cannot say WHICH arm it reds for (measured by
      # mutation in the PR that added this file).
      name: "CycleFleet (runtime-attempt claim fence)",
      source: "lib/barkpark/cycle_fleet.ex",
      scope: {:functions, [:verify_runtime_attempt_claim]},
      entries: [
        {:CycleFleet, :prepare_runtime_attempt},
        {:CycleFleet, :start_runtime_attempt},
        {:CycleFleet, :current_runtime_attempt_attribution}
      ],
      # :foreign_claim / :work_digest_mismatch are witnessed at HOME, in
      # test/barkpark/cycle_fleet_runtime_attempt_fence_test.exs. The
      # runtime_usage_test.exs assertions of those atoms never were: mutation
      # showed ClaimFence refuses every one of those fixtures with the same
      # atom one call later, masking the cond's arm.
      exempt: %{
        runtime_attempt_conflict: {:end_to_end, @runtime_usage, @runtime_attempt_fixture}
      }
    }
  ]

  @doc false
  def fences, do: @fences

  @doc """
  Violations for one fence, as printable strings. Empty list = every refusal
  term has a home witness or a named, still-valid exemption. `read` maps a
  path relative to the api root to its contents (a function so the instrument
  can be proved on fixtures).
  """
  def violations(fence, read, home_files) do
    terms = Scan.refusal_terms(read.(fence.source), fence.scope)

    if terms == [] do
      [
        "#{fence.name}: extracted ZERO refusal terms from #{fence.source} — the " <>
          "extraction is broken or the fence moved; refusing to pass vacuously"
      ]
    else
      witnessed =
        home_files
        |> Enum.flat_map(&Scan.witnessed_terms(read.(&1), fence.entries))
        |> MapSet.new()

      term_set = MapSet.new(terms, &elem(&1, 0))

      arm_violations =
        terms
        |> Enum.reject(fn {term, _line} -> MapSet.member?(witnessed, term) end)
        |> Enum.map(fn {term, line} -> exemption_violation(fence, term, line, read) end)
        |> Enum.reject(&(&1 == :ok))

      stale =
        for {term, _} <- fence.exempt, not MapSet.member?(term_set, term) do
          "#{fence.name}: exemption for :#{term} names an arm #{fence.source} no longer " <>
            "returns — delete the exemption"
        end

      arm_violations ++ stale
    end
  end

  defp exemption_violation(fence, term, line, read) do
    case Map.get(fence.exempt, term) do
      nil ->
        "#{fence.name}: refusal :#{term} (#{where(fence, line)}) has no witness in its " <>
          "home test directory #{home_dir(fence.source)}/ — add a test there that calls " <>
          "#{entries_text(fence.entries)} and asserts {:error, :#{term}}, or (only if the arm " <>
          "is reachable solely through another suite's fixture) add a named " <>
          "{:end_to_end, file, why} exemption"

      {:by_design, _why} ->
        :ok

      {:end_to_end, file, _why} ->
        if term in Scan.witnessed_terms(read.(file), fence.entries) do
          :ok
        else
          "#{fence.name}: refusal :#{term} (#{where(fence, line)}) is exempted as " <>
            "end-to-end-witnessed by #{file}, but that file no longer calls " <>
            "#{entries_text(fence.entries)} and asserts {:error, :#{term}} in a test — " <>
            "its last witness is gone"
        end
    end
  end

  defp where(fence, {name, line}), do: "#{name}/_ at #{fence.source}:#{line}"

  defp entries_text(entries), do: Enum.map_join(entries, " / ", fn {m, f} -> "#{m}.#{f}" end)

  @doc "`lib/a/b/x.ex` -> `test/a/b` (the home test directory, not recursive)."
  def home_dir("lib/" <> rest), do: Path.join("test", Path.dirname(rest))

  defp home_files(source) do
    Path.join([@api_root, home_dir(source), "*_test.exs"])
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, @api_root))
  end

  defp read_repo(path), do: File.read!(Path.join(@api_root, path))

  describe "every claim/lease fence arm has a home witness (or a named, live exemption)" do
    for fence <- @fences do
      @fence fence
      test "#{fence.name}" do
        home = home_files(@fence.source)
        assert home != [], "#{@fence.name}: no *_test.exs under #{home_dir(@fence.source)}/"

        violations = violations(@fence, &read_repo/1, home)
        assert violations == [], Enum.join(violations, "\n")
      end
    end
  end

  # ─── the instrument, proved on fixtures ─────────────────────────────────
  #
  # These pin the two directions the guard must hold: it REDS when an arm's
  # only home witness is removed, and it stays QUIET on an arm legitimately
  # witnessed end to end through a named exemption. Plus the vacuous-pass
  # refusal and the name-collision trap (cycle_fleet.ex's own cond returns
  # :foreign_claim / :work_digest_mismatch — an atom asserted about a different
  # guard is not coverage of this one).

  describe "the instrument" do
    @fx_source """
    defmodule Fx.Fence do
      @moduledoc "returns {:error, :in_a_doc} only in prose"
      @spec check(term()) :: :ok | {:error, :a | {:b, term()}}
      def check(x) do
        # {:error, :in_a_comment}
        cond do
          x == 1 -> {:error, :a}
          x == 2 -> {:error, {:b, x}}
          x == 3 -> {:error, {:c, x, x}}
          true -> passthrough(x)
        end
      end

      defp passthrough(x) do
        case x do
          {:error, reason} -> {:error, reason}
          _ -> :ok
        end
      end
    end
    """

    @fx_full_witness """
    defmodule Fx.FenceTest do
      use ExUnit.Case
      test "a" do
        assert {:error, :a} = Fx.Fence.check(1)
      end
      test "b and c" do
        assert Fx.Fence.check(2) == {:error, {:b, 2}}
        assert {:error, {:c, 3, 3}} = Fx.Fence.check(3)
      end
    end
    """

    @entries [{:Fence, :check}]

    defp fx(files), do: fn path -> Map.fetch!(files, path) end

    defp fx_fence(exempt \\ %{}),
      do: %{name: "Fx", source: "lib/fx.ex", scope: :module, entries: @entries, exempt: exempt}

    test "extraction reads returned literals only — not @spec, @moduledoc, comments or pass-throughs" do
      assert Scan.refusal_terms(@fx_source) |> Enum.map(&elem(&1, 0)) == [:a, :b, :c]
    end

    test "quiet when every arm has a home witness" do
      files = %{"lib/fx.ex" => @fx_source, "test/fx_test.exs" => @fx_full_witness}
      assert violations(fx_fence(), fx(files), ["test/fx_test.exs"]) == []
    end

    test "REDS, naming the arm, when the arm's only home witness is removed" do
      without_b =
        String.replace(@fx_full_witness, "assert Fx.Fence.check(2) == {:error, {:b, 2}}", "")

      files = %{"lib/fx.ex" => @fx_source, "test/fx_test.exs" => without_b}

      assert [violation] = violations(fx_fence(), fx(files), ["test/fx_test.exs"])
      assert violation =~ "refusal :b"
      assert violation =~ "lib/fx.ex"
    end

    test "a commented-out or @moduledoc-only assertion is not a witness" do
      commented =
        String.replace(
          @fx_full_witness,
          "assert Fx.Fence.check(2) == {:error, {:b, 2}}",
          "# assert Fx.Fence.check(2) == {:error, {:b, 2}}"
        )

      files = %{"lib/fx.ex" => @fx_source, "test/fx_test.exs" => commented}
      assert [violation] = violations(fx_fence(), fx(files), ["test/fx_test.exs"])
      assert violation =~ "refusal :b"
    end

    test "the name-collision trap: the same atom asserted in a file that never calls the fence is not a witness" do
      other_guard =
        String.replace(@fx_full_witness, "Fx.Fence.check", "Fx.OtherGuard.check")

      files = %{"lib/fx.ex" => @fx_source, "test/fx_test.exs" => other_guard}
      assert violations(fx_fence(), fx(files), ["test/fx_test.exs"]) |> length() == 3
    end

    test "QUIET on an arm exempted as end-to-end while the named file still witnesses it" do
      without_b =
        String.replace(@fx_full_witness, "assert Fx.Fence.check(2) == {:error, {:b, 2}}", "")

      e2e = """
      defmodule Fx.OtherContextTest do
        use ExUnit.Case
        test "b through a caller" do
          assert {:error, {:b, _}} = Fx.Fence.check(Fx.Caller.build())
        end
      end
      """

      files = %{
        "lib/fx.ex" => @fx_source,
        "test/fx_test.exs" => without_b,
        "test/other/e2e_test.exs" => e2e
      }

      fence = fx_fence(%{b: {:end_to_end, "test/other/e2e_test.exs", "fixture lives there"}})
      assert violations(fence, fx(files), ["test/fx_test.exs"]) == []

      # ...and the exemption is not a blindfold: lose the end-to-end witness
      # and the arm reds again, naming the file that used to hold it.
      files = %{files | "test/other/e2e_test.exs" => "defmodule Fx.OtherContextTest do\nend\n"}
      assert [violation] = violations(fence, fx(files), ["test/fx_test.exs"])
      assert violation =~ "refusal :b"
      assert violation =~ "test/other/e2e_test.exs"
      assert violation =~ "last witness is gone"
    end

    test "a stale exemption (the arm no longer exists) reds" do
      files = %{"lib/fx.ex" => @fx_source, "test/fx_test.exs" => @fx_full_witness}
      fence = fx_fence(%{gone: {:by_design, "was a CAS arm"}})

      assert [violation] = violations(fence, fx(files), ["test/fx_test.exs"])
      assert violation =~ "exemption for :gone"
    end

    test "an empty extraction refuses instead of passing vacuously" do
      files = %{"lib/fx.ex" => "defmodule Fx.Fence do\n  def check(_), do: :ok\nend\n"}

      assert [violation] = violations(fx_fence(), fx(files), [])
      assert violation =~ "ZERO refusal terms"
    end

    test "home_dir swaps lib/ for test/ and keeps the directory, not the file" do
      assert home_dir("lib/barkpark/tasks/claim_fence.ex") == "test/barkpark/tasks"
      assert home_dir("lib/barkpark/cycle_fleet.ex") == "test/barkpark"
    end
  end
end
