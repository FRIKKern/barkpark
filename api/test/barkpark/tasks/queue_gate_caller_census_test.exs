defmodule Barkpark.Tasks.QueueGateCallerCensusTest do
  @moduledoc """
  THE QUESTION `QueueGate` ANSWERS IS DECIDED AND STATED HERE, NOT ASSUMED
  (task-f48b0d7c943fc3a5).

  `live_claim_worker/1` grew a third part — a lease that has not lapsed — so
  `execution_class/2` now says `foreign_claimed` only while somebody ACTUALLY
  holds the row. That is a behaviour change for every reader of the function,
  and the row's own scope note refused to let it be assumed: "QueueGate may
  have callers for which 'was claimed and never closed' is the right question.
  Deriving WHO those callers are, and whether they want liveness or history, is
  part of the work."

  THE CALLER SET IS DERIVED, NOT LISTED. `derive_call_sites/1` globs `lib/` and
  matches a CALL SHAPE (`name(`), excluding definitions, `@spec` heads and
  comment lines. An enumeration is a snapshot; this is the predicate that
  produces one, and it is re-run on every test run. A caller added tomorrow in
  a file nobody thought of is found by the glob, not by anyone's memory.

  AND THE METHOD IS CONTROLLED. Two controls, because "every caller" is an
  ABSENCE claim and an absence is never caught by inspection:

    * POSITIVE CONTROL ON REAL SOURCE — the derivation must hit each of the
      five KNOWN caller files. A regex that had silently stopped matching would
      report a clean, empty, entirely false "no callers".
    * HIDDEN-CALLER CONTROL — a caller the census was never told about is
      planted in a file the glob must find, and `account/2` must REFUSE,
      naming the file. This is the arm that proves the census would actually
      SEE a new caller rather than merely never having met one.

  THE DENOMINATOR: 11 call sites across 5 files under `api/lib`. Every one of
  them wants a LIVE LEASE. Stated per file, with the reason:

    * `barkpark/tasks/queue_gate.ex` (2) — LIVE. `execution_class/2` calling
      `live_claim_worker/1` IS the definition of the question, and
      `executable?/2` gates a claim ATTEMPT, which is a right-now question by
      construction.
    * `barkpark/tasks.ex` (1) — LIVE by pass-through. A `defdelegate` re-export
      that makes no decision of its own; it is counted because it is a public
      door onto the predicate.
    * `barkpark/tasks/mutate_guards.ex` (1) — LIVE. `live_claim?/1` refuses a
      create-family write that would fork a row SOMEBODY IS WORKING ON. A row
      whose holder left six days ago is not being worked on, and refusing that
      write would strand an importer on residue.
    * `barkpark_web/controllers/tasks_controller.ex` (5) — LIVE. Every site is
      in `not_ready_arm/2`, whose whole subject is "who holds this row NOW and
      who do I ask". This is the arm task-4753f80a2ec47d03 fixed for the same
      reason.
    * `barkpark_web/controllers/tasks_controller/params.ex` (2) — LIVE. Both
      render `execution_class` into the API payload `bp` reads, and a machine
      reader keys on the field.

  SO THE FIX IS ONE PREDICATE, and that conclusion is derived rather than
  assumed. NO CALLER WANTS HISTORY FROM THIS FUNCTION — and the reason is
  structural, not luck: the historical fact is available WITHOUT it. The raw
  claim map is rendered beside the derived class on the very same payload
  (`params.ex`'s `claim: content |> Map.get("claim") |> with_lease_horizon()`),
  carrying `worker`, `closed_by` and `closed_at` untouched. A reader who wants
  "was this ever claimed, and by whom" reads that map; `execution_class/2` is
  not the door to it and never was.
  """

  use ExUnit.Case, async: true

  # file (relative to api/) => number of CALL SITES, and what that file wants.
  # `:live` means the caller is asking "does anybody hold this row right now".
  # `:history` would mean "was this row ever claimed" — no caller wants that,
  # and a future one that does must be added here DELIBERATELY, which is the
  # point of pinning the count rather than the mere file name.
  @census %{
    "lib/barkpark/tasks.ex" => {1, :live},
    "lib/barkpark/tasks/queue_gate.ex" => {2, :live},
    "lib/barkpark/tasks/mutate_guards.ex" => {1, :live},
    "lib/barkpark_web/controllers/tasks_controller.ex" => {5, :live},
    "lib/barkpark_web/controllers/tasks_controller/params.ex" => {2, :live}
  }

  @expected_denominator 11

  @call_shape ~r/(execution_class|live_claim_worker|claim_lease_live\?)\s*\(/
  @definition ~r/^\s*defp?\s+(execution_class|live_claim_worker|claim_lease_live\?)/
  @not_a_call ~r/^\s*(#|@spec\s|@doc\s)/

  describe "the caller set is DERIVED from the source, and every caller is decided" do
    test "the census accounts for every call site under lib/, and the denominator holds" do
      sites = derive_call_sites(lib_sources())

      assert account(sites, @census) == :ok

      assert length(sites) == @expected_denominator,
             "the DENOMINATOR moved: #{length(sites)} call sites, census says " <>
               "#{@expected_denominator}. Sites: #{inspect(sites, limit: :infinity)}"

      # The decision is STATED for every file the derivation found — not for a
      # list someone typed. A file present in the sites but absent from the
      # census is exactly what `account/2` refuses above; this asserts the
      # other half, that each stated decision is one of the two real answers.
      for {_path, {_count, wants}} <- @census do
        assert wants in [:live, :history]
      end

      assert Enum.all?(@census, fn {_p, {_c, wants}} -> wants == :live end),
             "a caller now wants HISTORY, so the fix is no longer one predicate — " <>
               "task-f48b0d7c943fc3a5's own scope note says the row must say so."
    end

    test "POSITIVE CONTROL: the derivation hits every known caller file" do
      paths = lib_sources() |> derive_call_sites() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      for known <- Map.keys(@census) do
        assert known in paths,
               "the derivation stopped seeing a KNOWN caller (#{known}). An empty or " <>
                 "shrunken result from this method is not evidence of no callers."
      end
    end

    test "HIDDEN-CALLER CONTROL: a caller the census never heard of is FOUND and REFUSED" do
      dir = Path.join(System.tmp_dir!(), "qg-census-#{System.unique_integer([:positive])}/lib")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(Path.dirname(dir)) end)

      planted = Path.join(dir, "sneaky_caller.ex")

      File.write!(planted, """
      defmodule Sneaky do
        # a comment mentioning execution_class( must NOT count
        def peek(content), do: QueueGate.execution_class(content, nil)
      end
      """)

      sites = derive_call_sites(sources_under(Path.dirname(dir)))

      assert length(sites) == 1,
             "the glob+regex missed a planted caller, so its silence on lib/ proves nothing"

      [{path, _line, text}] = sites
      assert path == "lib/sneaky_caller.ex"
      assert text =~ "QueueGate.execution_class"

      # ... and the census REFUSES it, naming the file. Without this arm the
      # derivation could be perfect and the accounting still vacuous.
      {:error, message} = account(sites, @census)
      assert message =~ "lib/sneaky_caller.ex"
      assert message =~ "not in the census"
    end
  end

  # --- the derivation itself -------------------------------------------------

  defp lib_sources, do: sources_under(File.cwd!())

  defp sources_under(root) do
    root
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.map(fn abs -> {Path.relative_to(abs, root), File.read!(abs)} end)
    |> Enum.sort()
  end

  defp derive_call_sites(sources) do
    Enum.flat_map(sources, fn {path, source} ->
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _n} -> call_site?(line) end)
      |> Enum.map(fn {line, n} -> {path, n, String.trim(line)} end)
    end)
  end

  # A DEFINITION LINE CAN ALSO BE A CALL SITE, and dropping the whole line
  # missed one: `defp claim_lease_live?(content), do: QueueGate.claim_lease_live?(content)`
  # in `tasks_controller.ex` DEFINES a private alias on its left and CALLS the
  # real predicate on its right. A rule that threw the line away read 4 sites
  # where there are 5 — and it would have gone on reading 4 forever, silently,
  # because a shortfall in a derivation looks exactly like a clean result. So a
  # definition head is STRIPPED, not skipped: only the body after `, do:`
  # survives, and a head with no inline body contributes nothing.
  defp call_site?(line) do
    body =
      if Regex.match?(@definition, line) do
        case String.split(line, ", do:", parts: 2) do
          [_head, body] -> body
          [_head_only] -> ""
        end
      else
        line
      end

    Regex.match?(@call_shape, body) and not Regex.match?(@not_a_call, line)
  end

  # Does every derived site fall under a file the census has DECIDED, in the
  # count it recorded? Returns a message rather than asserting, so the
  # hidden-caller control can prove the refusal fires.
  defp account(sites, census) do
    by_file = Enum.group_by(sites, &elem(&1, 0))

    unknown = Map.keys(by_file) -- Map.keys(census)

    cond do
      unknown != [] ->
        {:error,
         "call site(s) in #{Enum.join(unknown, ", ")} are not in the census — decide " <>
           "whether that caller wants a LIVE lease or the historical fact that a claim " <>
           "once existed, then record it in @census."}

      true ->
        drift =
          for {path, {expected, _wants}} <- census,
              actual = by_file |> Map.get(path, []) |> length(),
              actual != expected,
              do: "#{path}: census #{expected}, derived #{actual}"

        if drift == [], do: :ok, else: {:error, Enum.join(drift, "; ")}
    end
  end
end
