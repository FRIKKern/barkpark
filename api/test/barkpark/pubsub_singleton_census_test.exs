defmodule Barkpark.PubSubSingletonCensusTest do
  @moduledoc """
  THE RATCHET for the third sandbox hazard shape.

  `Barkpark.Quiz.Bridge` cost one CI run 1,310 failures because a boot-time,
  PubSub-subscribed singleton reached `Repo` and nothing in the test harness
  could see it: `DataCase.drain_owned_tasks/3` walks the two `Task.Supervisor`s
  via `$callers`, and a GenServer is in neither. Fixing that one module fixes one
  module. This file is what stops the NEXT one from being written silently.

  ## What is derived and what is declared

  DERIVED FROM SOURCE (this file, at run time): the CLASS — every module under
  `api/lib` that is `use GenServer` AND calls `Phoenix.PubSub.subscribe`. That is
  the shape `$callers` cannot reach. LiveViews, Channels and Controllers also
  subscribe, but they are per-connection processes started by the test's own
  connection and are not in this class; none of them is a `GenServer`, so the
  filter excludes them without a hand-maintained deny-list.

  DECLARED BY A HUMAN (`Barkpark.PubSubSingletons`): the CLASSIFICATION of each
  member — `drained/0` (reaches `Repo`, so the barrier must quiesce it) or
  `no_repo/0` (does not, so it needs none).

  The assertion below is SET EQUALITY between the two. That is what makes this
  able to lose: a new boot-time PubSub singleton that nobody classified reds
  here, naming the file, rather than reaching `Repo` unnoticed and poisoning a
  pool six months later. Deleting a module reds it too, so the registry cannot
  rot into a list of ghosts.

  ## The honest limit of the `no_repo` arm

  `assert_no_direct_repo/1` proves a `no_repo` member contains no DIRECT `Repo`
  reference. It does NOT prove the module reaches no database transitively —
  `Quiz.Bridge` itself says `Repo` nowhere; it calls `Quiz.load_question/2`,
  which is three hops from `Ecto.Repo.Queryable.one/3`. So the `no_repo` arm is a
  cheap tripwire on top of a human judgement, NOT a proof, and it is written down
  that way rather than dressed up. The load-bearing guard here is set equality;
  the `no_repo` check only catches the crudest regression.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PubSubSingletons

  @lib_root Path.expand("../../lib", __DIR__)

  # The source-level marks that define the class.
  @genserver_mark "use GenServer"
  @subscribe_mark "Phoenix.PubSub.subscribe"

  describe "the class of boot-time PubSub-subscribed singletons" do
    test "the derivation itself finds something (anti-vacuity)" do
      # A census whose scanner silently matches nothing would pass every other
      # assertion in this file by construction. Pin that it reads real source.
      files = elixir_sources()

      assert length(files) > 500,
             "expected to scan the whole api/lib tree, got #{length(files)} file(s) — " <>
               "the scanner is looking in the wrong place (#{@lib_root})"

      assert Enum.any?(files, &String.ends_with?(&1, "quiz/bridge.ex")),
             "the known member quiz/bridge.ex was not scanned at all"
    end

    test "every derived member is classified, and every classified member still exists" do
      derived = MapSet.new(derived_class())
      declared = MapSet.new(PubSubSingletons.all())

      unclassified = MapSet.difference(derived, declared)
      ghosts = MapSet.difference(declared, derived)

      assert MapSet.size(unclassified) == 0,
             """
             A boot-time PubSub-subscribed singleton is not classified in
             Barkpark.PubSubSingletons:

               #{unclassified |> Enum.map(&inspect/1) |> Enum.join("\n  ")}

             This is the shape that cost CI run 29710726459 1,310 failures. It is
             invisible to DataCase.drain_owned_tasks/3, because that walks Task
             supervisors via $callers and a GenServer is in neither.

             Decide which it is and add it to the right list:

               * it reaches Repo (directly or through a context call) -> @drained,
                 and DataCase's on_exit will quiesce it before stopping the owner;
               * it never reaches Repo -> @no_repo, with the reason written down.
             """

      assert MapSet.size(ghosts) == 0,
             """
             Barkpark.PubSubSingletons declares modules that are no longer in the
             class (deleted, or no longer a PubSub-subscribing GenServer):

               #{ghosts |> Enum.map(&inspect/1) |> Enum.join("\n  ")}

             Remove them, so the registry keeps describing the tree it guards.
             """
    end

    test "the members this suite already knows about are still in the class" do
      # Guards the derivation, not the registry: if a refactor stopped these two
      # from matching, set equality above would still pass (both sides empty) and
      # this file would quietly guard nothing.
      derived = derived_class()

      assert Barkpark.Quiz.Bridge in derived,
             "Quiz.Bridge dropped out of the derived class — the scanner's marks " <>
               "(#{@genserver_mark} / #{@subscribe_mark}) no longer describe it"

      assert Barkpark.StudioChat.FleetHub in derived,
             "StudioChat.FleetHub dropped out of the derived class"
    end
  end

  describe "the classification's own claims" do
    test "every @no_repo member is free of a direct Repo reference" do
      for module <- PubSubSingletons.no_repo() do
        source = module |> source_path!() |> File.read!()

        refute source =~ ~r/\bRepo\./,
               """
               #{inspect(module)} is declared @no_repo but its source references Repo
               directly. Either it now reaches the database — move it to @drained so
               the sandbox barrier covers it — or the reference is inert and the
               declaration needs re-examining by hand.
               """
      end
    end

    test "the barrier can actually find every @drained member" do
      # The trap this catches: `drain!/1` locates a member with
      # `Process.whereis/1`, which answers only for a module-NAMED process. Add
      # a `{:via, Registry, …}` member (Recorder runs one per live chat
      # session) without teaching `@registries` about it and `whereis` returns
      # nil, `quiesce/2` takes the "not running" arm, and the barrier is a
      # silent no-op that READS as coverage. Derived from source, so it loses
      # on the next such member rather than on this one.
      for module <- PubSubSingletons.drained() do
        source = module |> source_path!() |> File.read!()
        module_named? = source =~ ~r/name:\s*__MODULE__/
        registry = PubSubSingletons.registry_of(module)

        assert module_named? or registry != nil,
               """
               #{inspect(module)} is declared @drained but is not registered under
               `name: __MODULE__`, and Barkpark.PubSubSingletons.registry_of/1 has
               no Registry for it. drain!/1 would call Process.whereis/1, get nil,
               and quiesce nothing — the barrier would be decoration.

               Add it to @registries with the Registry it is named under.
               """
      end
    end

    test "@drained and @no_repo are disjoint" do
      overlap =
        MapSet.intersection(
          MapSet.new(PubSubSingletons.drained()),
          MapSet.new(PubSubSingletons.no_repo())
        )

      assert MapSet.size(overlap) == 0,
             "a singleton cannot be both drained and repo-free: #{inspect(overlap)}"
    end
  end

  describe "the barrier is wired into the sandbox lifecycle" do
    # DataCase's on_exit runs AFTER any on_exit a test body registers (ExUnit
    # runs them LIFO, and DataCase registers first), so no test can observe the
    # ordering from the inside. The wiring is therefore pinned at the source
    # level — crude, but it can lose: delete the call or reorder the three steps
    # and this reds.
    test "data_case.ex drains tasks, then singletons, then stops the owner — in that order" do
      source = File.read!(Path.join(@lib_root, "../test/support/data_case.ex"))

      drain_tasks = index_of!(source, "drain_owned_tasks(test_pid, tags)", "the task drain")

      drain_singletons =
        index_of!(source, "Barkpark.PubSubSingletons.drain!()", """
        the singleton barrier. DataCase.setup_sandbox/1 must call
        Barkpark.PubSubSingletons.drain!/1 in its on_exit; without it a boot-time
        PubSub singleton is still mid-read when stop_owner/1 fires.
        """)

      stop_owner = index_of!(source, "Sandbox.stop_owner(pid)", "the owner stop")

      assert drain_tasks < drain_singletons,
             "tasks must drain BEFORE the singletons: a draining task can itself " <>
               "broadcast the mutation that wakes one, so quiescing first leaves " <>
               "exactly the in-flight read the barrier exists to prevent"

      assert drain_singletons < stop_owner,
             "the singleton barrier must run BEFORE stop_owner/1, or it is decoration"
    end
  end

  # ── derivation ─────────────────────────────────────────────────────────────

  defp derived_class do
    for path <- elixir_sources(),
        source = File.read!(path),
        String.contains?(source, @genserver_mark),
        String.contains?(source, @subscribe_mark),
        module = defmodule_of(source),
        module != nil,
        do: module
  end

  defp elixir_sources do
    @lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
  end

  defp defmodule_of(source) do
    case Regex.run(~r/^defmodule\s+([A-Za-z0-9_.]+)\s+do/m, source) do
      [_, name] -> Module.concat([name])
      _ -> nil
    end
  end

  defp source_path!(module) do
    found =
      Enum.find(elixir_sources(), fn path ->
        defmodule_of(File.read!(path)) == module
      end)

    found ||
      flunk("could not find the source file defining #{inspect(module)} under #{@lib_root}")
  end

  defp index_of!(source, needle, what) do
    case :binary.match(source, needle) do
      {pos, _} ->
        pos

      :nomatch ->
        flunk("""
        Could not find #{what} in api/test/support/data_case.ex.

        Looked for, verbatim:
            #{needle}
        """)
    end
  end
end
