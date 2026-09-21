defmodule Barkpark.ApplicationOneShotBootModeTest do
  @moduledoc """
  The `:one_shot` boot mode and the mix tasks that use it (task-557cf9a71e949768).

  THE DEFECT, measured on guerrilla 2026-09-02 08:28-08:35Z and reproduced
  locally on 2026-09-16. `mix barkpark.edges.backfill` called
  `Mix.Task.run("app.start")`, which boots the FULL application with whatever
  runtime env the invoking shell carries. Run from the live slot's environment
  (`PHX_SERVER` set) the one-shot's own endpoint tried to bind the SERVING
  node's port and the run died before the sweep started:

      [error] Running BarkparkWeb.Endpoint with Bandit 1.12.0 at http failed,
              port 4321 already in use
      ** (Mix) Could not start application barkpark: ... returned an error: killed

  The same boot put up a second `Oban` draining the live queues, the Github
  `DrainWorker`, and `SchemaBootstrap`'s onixedit codelist seeders (one hit
  `ERROR 57014 query_canceled` under the live 60 s statement_timeout).

  ANTI-VACUITY. Every absence assertion below is PAIRED with a control that
  requires the same thing to be PRESENT in `:full` mode — built from the SAME
  arguments — because an absence is never caught by inspection. If the `:full`
  control ever stops finding the child, the absence assertion beside it has
  stopped measuring anything and says so.
  """

  # async: FALSE. The `boot_mode/0` arm below mutates `:barkpark, :boot_mode`,
  # which is GLOBAL application env: run concurrently it reddened
  # `Barkpark.ApplicationBootModeTest`'s ":full default" and ":seed mode"
  # assertions in another file. A sync module runs after every async one, so the
  # mutation can no longer overlap a reader.
  use ExUnit.Case, async: false

  alias Barkpark.Application, as: App
  alias Barkpark.BootModeSandbox

  # The api/ project root, for the source-reading guards below.
  @test_root Path.expand(Path.join([__DIR__, "..", ".."]))

  # Stand-ins for the three list ARGUMENTS `:one_shot` drops. Deliberately
  # recognisable atoms rather than real child specs: what is asserted is that
  # they do not reach the list, and a real module would be indistinguishable
  # from a child the canonical list already carries.
  @plugin_children [:plugin_worker_stand_in]
  @sync_children [:sync_worker_stand_in]
  @self_update_children [:self_update_stand_in]

  @oban_config Application.compile_env!(:barkpark, Oban)

  defp one_shot_specs,
    do:
      App.child_specs(
        @plugin_children,
        @oban_config,
        @sync_children,
        @self_update_children,
        :one_shot
      )

  defp full_specs,
    do:
      App.child_specs(
        @plugin_children,
        @oban_config,
        @sync_children,
        @self_update_children,
        :full
      )

  defp has_child?(specs, module) do
    Enum.any?(specs, fn
      ^module -> true
      {^module, _arg} -> true
      %{id: ^module} -> true
      _ -> false
    end)
  end

  describe ":one_shot drops the children an operator one-shot must not start" do
    test "control: :full mode DOES carry every child the one_shot arms assert away" do
      specs = full_specs()

      assert has_child?(specs, BarkparkWeb.Endpoint),
             "the canonical list no longer carries the Endpoint — the absence arm below is vacuous"

      assert has_child?(specs, Oban),
             "the canonical list no longer carries Oban — the absence arm below is vacuous"

      assert :plugin_worker_stand_in in flatten_plugin_children(specs),
             "the canonical list no longer folds in plugin_children — its absence arm is vacuous"

      assert :sync_worker_stand_in in specs,
             "the canonical list no longer folds in sync_children — its absence arm is vacuous"

      assert :self_update_stand_in in specs,
             "the canonical list no longer folds in self_update_children — its absence arm is vacuous"
    end

    test "the endpoint is NOT in the one_shot list" do
      refute has_child?(one_shot_specs(), BarkparkWeb.Endpoint)
    end

    test "Oban is NOT in the one_shot list — not even inert, the way :seed keeps it" do
      refute has_child?(one_shot_specs(), Oban)

      # The distinction from `:seed` is load-bearing: `:seed` KEEPS Oban with
      # `queues: false, plugins: false` because a seed's document writes call
      # `Oban.insert/1`. A backfill's write path does not, so the child is
      # dropped outright and "this cannot touch the live queues" becomes a
      # property of the tree rather than of its configuration.
      assert has_child?(
               App.child_specs(
                 @plugin_children,
                 @oban_config,
                 @sync_children,
                 @self_update_children,
                 :seed
               ),
               Oban
             ),
             "the :seed contrast this test rests on has changed"
    end

    test "plugin boot workers, sync children and self-update children are all dropped" do
      specs = one_shot_specs()

      refute :plugin_worker_stand_in in flatten_plugin_children(specs)
      refute :sync_worker_stand_in in specs
      refute :self_update_stand_in in specs
    end

    test "PHX_SERVER cannot put the listener back: server: true does not add the Endpoint" do
      # PHX_SERVER's ONLY effect (config/runtime.exs) is `server: true` on the
      # endpoint config. A listener exists if and only if the Endpoint CHILD is
      # started, so the fix has to hold with `server: true` set — which is the
      # exact shape the guerrilla box ran.
      assert Keyword.get(Application.get_env(:barkpark, BarkparkWeb.Endpoint, []), :server) !=
               :absent

      refute has_child?(one_shot_specs(), BarkparkWeb.Endpoint),
             "the one_shot list carries the Endpoint — with server: true it would bind a port"
    end

    test "Barkpark.Repo IS still started — a one-shot with no repo does nothing" do
      assert has_child?(one_shot_specs(), Barkpark.Repo)
    end

    test "Barkpark.SchemaBootstrap IS still started, and it is not an oversight" do
      # MEASURED, not reasoned: dropping SchemaBootstrap took the local dev
      # corpus's projected edge count from 962 to ZERO, because the schema
      # registration it performs is what the extractor chain resolves reference
      # fields against. Only its codelist seeders are suppressed in :one_shot —
      # see Barkpark.SchemaBootstrap.init/1.
      assert has_child?(one_shot_specs(), Barkpark.SchemaBootstrap)
    end

    test "PubSub and the plugin Registry survive — the projector needs both" do
      specs = one_shot_specs()

      assert has_child?(specs, Phoenix.PubSub)
      assert has_child?(specs, Barkpark.Plugins.Registry)
    end
  end

  describe "boot_mode/0 knows :one_shot" do
    test ":one_shot is an accepted mode, and a typo is still refused" do
      # THE WRITE IS SANDBOXED, NOT MERELY UNDONE (task-086261728f14c078).
      # This test is the ONLY in-VM writer of `:barkpark, :boot_mode` in
      # api/test, and on 2026-09-18 its value reached
      # `Barkpark.ApplicationBootModeTest` 43 modules later and reddened two
      # assertions there. The previous guard — `async: false` plus an `on_exit`
      # keyed off `fetch_env` — was already in place when that happened.
      #
      # `Barkpark.BootModeSandbox.sandboxed/1` restores in a `try … after`,
      # synchronously, in this process, and then ASSERTS the key came back. Its
      # moduledoc carries the measurement for why both sides must be
      # `persistent: true`. There is no raw `Application.put_env` here any more,
      # and the predicate guard below makes that a property of the TREE rather
      # than of this file.
      BootModeSandbox.sandboxed(fn set ->
        set.(:one_shot)
        assert App.boot_mode() == :one_shot

        set.(:one_shot_typo)
        assert_raise ArgumentError, fn -> App.boot_mode() end
      end)

      # The escape this whole row is about, asserted at its source: by the time
      # the writer's test returns, the node-global key is back. A reader that
      # runs next cannot see `:one_shot`.
      assert BootModeSandbox.current() == :error,
             "the sandbox returned with :boot_mode still set — this is the leak"
    end

    test "the sandbox restores even when the block RAISES" do
      # A restore that only runs on the happy path is not a restore. The
      # `on_exit` this replaces did run on failure; a `try … after` must too, or
      # the swap is a downgrade. Asserted, not assumed.
      assert BootModeSandbox.current() == :error

      assert_raise RuntimeError, "boom", fn ->
        BootModeSandbox.sandboxed(fn set ->
          set.(:one_shot)
          raise "boom"
        end)
      end

      assert BootModeSandbox.current() == :error,
             "the sandbox leaked :boot_mode when its block raised"
    end

    test "a PRE-EXISTING value is put back, not deleted" do
      # The restore is `fetch_env`-shaped for a reason: `put_env(:boot_mode, nil)`
      # is NOT the same state as "never set", and the reader module asserts
      # `fetch_env(...) == :error` for an ordinary boot. Both directions are
      # measured here, on the same helper, so a restore-by-deletion that is
      # correct for one and wrong for the other cannot pass.
      assert BootModeSandbox.current() == :error

      BootModeSandbox.sandboxed(fn set ->
        set.(:seed)

        # Inside a sandbox whose `original` is {:ok, :seed}: the inner block
        # must be put BACK to :seed, not deleted.
        BootModeSandbox.sandboxed(fn inner -> inner.(:one_shot) end)

        assert BootModeSandbox.current() == {:ok, :seed},
               "a nested sandbox deleted a value it was supposed to restore"
      end)

      assert BootModeSandbox.current() == :error,
             "the outer sandbox left :boot_mode behind"
    end

    test "absent/1 ESTABLISHES the key's absence rather than observing it" do
      BootModeSandbox.sandboxed(fn set ->
        set.(:one_shot)

        # The state the 2026-09-18 readers were in when they reddened: the node
        # holds :one_shot. `absent/1` must not care.
        assert BootModeSandbox.absent(fn -> App.boot_mode() end) == :full

        assert BootModeSandbox.current() == {:ok, :one_shot},
               "absent/1 did not put back the value it displaced"
      end)

      assert BootModeSandbox.current() == :error
    end
  end

  describe "the restore is PERSISTENT, and that is a measured requirement" do
    # A NEGATIVE RESULT, STATED RATHER THAN HIDDEN (task-086261728f14c078):
    # dropping `persistent: true` from the sandbox's restore and running this
    # whole file leaves it GREEN — 31 tests, 0 failures, measured 2026-09-20.
    # No `mix test` run loads `:barkpark` again, so the resurrection never
    # happens in-VM and no assertion about `:barkpark` can see it.
    #
    # An unmeasurable requirement decays into a style preference and gets
    # "simplified" away. So it is measured HERE, on a throwaway application, on
    # the only thing that can actually show it: the OTP semantics themselves.
    @probe_app :bp_boot_mode_persistence_probe

    defp probe_spec do
      {:application, @probe_app,
       [
         {:description, ~c"boot-mode persistence probe"},
         {:vsn, ~c"1"},
         {:modules, []},
         {:registered, []},
         {:applications, []},
         {:env, []}
       ]}
    end

    setup do
      on_exit(fn ->
        Application.delete_env(@probe_app, :k, persistent: true)
        Application.unload(@probe_app)
      end)

      :ok
    end

    test "a NON-persistent delete does not retract a PERSISTENT write — it is resurrected by load" do
      Application.put_env(@probe_app, :k, :one_shot, persistent: true)

      # Non-persistent delete, the shape the restore would have without the
      # flag. It LOOKS clean...
      Application.delete_env(@probe_app, :k)

      assert Application.fetch_env(@probe_app, :k) == :error,
             "precondition: the delete must read as clean, or this proves nothing"

      # ...until the next load re-applies OTP's own persistent record.
      :application.load(probe_spec())

      assert Application.fetch_env(@probe_app, :k) == {:ok, :one_shot},
             "the persistent record was NOT resurrected — OTP's semantics changed and " <>
               "the `persistent: true` on the sandbox's restore can be reconsidered"

      Application.unload(@probe_app)
    end

    test "control: a PERSISTENT delete does retract it, and load brings nothing back" do
      # The arm that makes the one above a statement about PERSISTENCE rather
      # than about `load/1` inventing values. Same writes, same load, one flag
      # different, opposite answer.
      Application.put_env(@probe_app, :k, :one_shot, persistent: true)
      Application.delete_env(@probe_app, :k, persistent: true)

      assert Application.fetch_env(@probe_app, :k) == :error

      :application.load(probe_spec())

      assert Application.fetch_env(@probe_app, :k) == :error,
             "a persistent delete left a record behind"

      Application.unload(@probe_app)
    end

    test "the sandbox's every :boot_mode write carries persistent: true" do
      # The source-level half. `Barkpark.OneShot.boot!/0` — the PRODUCTION
      # writer — is persistent, so a restore that is not persistent cannot undo
      # what it does. Read off disk, so a future edit that drops the flag reds
      # here instead of in a nightly three weeks later.
      source = File.read!(Path.join(@test_root, "test/support/boot_mode_sandbox.ex"))

      writes =
        ~r/Application\.(?:put_env|delete_env)\(:barkpark, :boot_mode[^\n]*/
        |> Regex.scan(source)
        |> Enum.map(&hd/1)

      # Control: the scan found the writes at all. Without this an empty list
      # passes the loop below on nothing.
      assert length(writes) >= 3,
             "found #{length(writes)} :boot_mode write(s) in the sandbox — the scan is blind"

      for w <- writes do
        assert w =~ "persistent: true",
               "a sandbox write of :boot_mode is not persistent, so it cannot undo " <>
                 "Barkpark.OneShot.boot!/0: #{w}"
      end
    end
  end

  describe "no test outside the sandbox may write :boot_mode" do
    # A PREDICATE OVER THE TREE, not a fix to one file (the same shape as the
    # app.start guard below, and for the same reason). The 2026-09-18 escape
    # needed exactly one raw `Application.put_env(:barkpark, :boot_mode, …)` in
    # a test, and the NEXT one someone writes would be born outside any fix
    # applied here. The rule is: `Barkpark.BootModeSandbox` is the only module
    # under api/test that writes the key.
    @sandbox "test/support/boot_mode_sandbox.ex"
    @write_re ~r/Application\.(put_env|delete_env)\(\s*:barkpark\s*,\s*:boot_mode/

    defp test_sources do
      Path.wildcard(Path.join(@test_root, "test/**/*.{ex,exs}"))
      |> Enum.map(&Path.relative_to(&1, @test_root))
      |> Enum.sort()
    end

    # COMMENTS ARE NOT CODE. Three files in this walk DISCUSS the write in
    # prose — including this one, two lines above — and a predicate that counts
    # prose reports a violation nobody committed, gets waived, and the waiver
    # becomes the policy. Strip `#`-leading lines before matching, exactly as
    # the app.start guard's sibling does ("the parser reads commands, not
    # prose"). The control test below is what proves the stripping did not also
    # blind the match.
    defp writes_boot_mode?(rel) do
      @test_root
      |> Path.join(rel)
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
      |> Enum.join("\n")
      |> String.match?(@write_re)
    end

    test "the walk is reading a real, populated test tree" do
      # PRECONDITION. Every assertion below is about a SET, and an empty set
      # satisfies all of them vacuously — a moved directory would otherwise turn
      # this describe block green.
      files = test_sources()

      assert length(files) > 100,
             "only #{length(files)} test source(s) under #{@test_root}/test — the walk is blind"

      assert @sandbox in files, "#{@sandbox} is not in the walk"
      assert "test/barkpark/application_one_shot_boot_mode_test.exs" in files
    end

    test "control: the pattern finds a write where one really is" do
      # An absence assertion needs a positive specimen, or it can pass because
      # the regex is wrong rather than because the tree is clean.
      assert writes_boot_mode?(@sandbox),
             "the sandbox itself no longer writes :boot_mode — the predicate below measures nothing"

      refute writes_boot_mode?("test/barkpark/application_boot_mode_test.exs"),
             "the reader module writes :boot_mode directly again"

      # The comment-stripping arm, measured on a file that NAMES the call in
      # prose and does not make it. Without this the control above passes while
      # the predicate reads documentation.
      refute writes_boot_mode?("test/barkpark/application_one_shot_boot_mode_test.exs"),
             "this file's PROSE is being read as a write — the comment stripping is broken"
    end

    test "Barkpark.BootModeSandbox is the ONLY writer under api/test" do
      writers = Enum.filter(test_sources(), &writes_boot_mode?/1)

      assert writers == [@sandbox],
             """
             these test sources write the NODE-GLOBAL `:barkpark, :boot_mode` directly:

                 #{writers |> List.delete(@sandbox) |> Enum.join("\n    ")}

             That value is ONE value for the WHOLE NODE. A direct write makes an
             unrelated module fail later, chosen by the ExUnit seed — which is
             how elixir-nightly 35323296944 reddened two assertions in
             application_boot_mode_test.exs on 2026-09-18.

             Go through `Barkpark.BootModeSandbox.sandboxed/1` (or `absent/1`),
             which restores in a `try … after` and asserts the restore landed.
             """
    end
  end

  describe "a test that BOOTS a one-shot mix task must route it through the sandbox" do
    # THE DEFECT THIS CLOSES, and it is the one the row was filed for.
    #
    # The describe above asks "does any test source WRITE :boot_mode?" and the
    # answer was, honestly, no — and the key still leaked. PR #19480's own
    # end-of-suite probe caught it in run 35509163543: `value left behind:
    # :one_shot`, on a tree where every raw write already went through the
    # sandbox.
    #
    # The writer is `Barkpark.OneShot.boot!/0` (api/lib), whose first line is a
    # PERSISTENT put_env of :one_shot and which nothing in api/lib puts back —
    # an operator one-shot exits, so it never needs to. Seven `mix barkpark.*`
    # tasks call it. A test that calls such a task's `run/1` is therefore a
    # writer of the node-global key WITHOUT TYPING A WRITE, which is exactly why
    # a grep of api/test read the tree as clean.
    #
    # DERIVED, NOT LISTED. The task set is read out of api/lib on every run, so
    # a task that starts calling `OneShot.boot!/0` tomorrow is in scope the same
    # day. A hardcoded list would have been correct on 2026-09-20 and stale by
    # the next one.
    @one_shot_boot_re ~r/Barkpark\.(OneShot\.boot!|Release\.seed_boot!)\(\)/
    @sandbox_marker "BootModeSandbox"

    defp strip_comments(source) do
      source
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "#"))
      |> Enum.join("\n")
    end

    # Every `Mix.Tasks.…` module under api/lib whose CODE boots a narrowed tree.
    defp one_shot_task_modules do
      Path.join(@test_root, "lib/mix/tasks/**/*.ex")
      |> Path.wildcard()
      |> Enum.map(&{&1, strip_comments(File.read!(&1))})
      |> Enum.filter(fn {_path, src} -> src =~ @one_shot_boot_re end)
      |> Enum.flat_map(fn {_path, src} ->
        case Regex.run(~r/^defmodule\s+(Mix\.Tasks\.[A-Za-z0-9_.]+)\s+do/m, src) do
          [_, mod] -> [mod]
          nil -> []
        end
      end)
      |> Enum.sort()
    end

    # PURE, so the controls below can feed it a specimen instead of hoping one
    # exists in the tree. A source INVOKES a one-shot task when it both names
    # the module (the alias) and calls `run/1` on its last segment — both, so a
    # file that merely mentions the module in an assertion is not flagged, and a
    # collision with some other module called `Backfill` is not either.
    defp unsandboxed_one_shot_invocations(source, modules) do
      stripped = strip_comments(source)

      Enum.filter(modules, fn mod ->
        last = mod |> String.split(".") |> List.last()

        String.contains?(stripped, mod) and
          stripped =~ ~r/(?<![A-Za-z0-9_.])#{Regex.escape(last)}\.run\(/ and
          not String.contains?(stripped, @sandbox_marker)
      end)
    end

    test "the derived task set is real and populated" do
      # PRECONDITION. Every assertion below quantifies over this set, and an
      # empty set satisfies all of them vacuously.
      modules = one_shot_task_modules()

      assert length(modules) >= 5,
             "only #{length(modules)} one-shot mix task(s) derived from api/lib — the walk is blind"

      assert "Mix.Tasks.Barkpark.Preview.Backfill" in modules
      assert "Mix.Tasks.Barkpark.Workspace.ProvisionSchemas" in modules
    end

    test "control: the predicate FLAGS a call with no sandbox, and clears the same call with one" do
      modules = ["Mix.Tasks.Barkpark.Preview.Backfill"]

      leaky = """
      defmodule SomeTest do
        alias Mix.Tasks.Barkpark.Preview.Backfill
        test "x" do
          Backfill.run([])
        end
      end
      """

      assert unsandboxed_one_shot_invocations(leaky, modules) == modules,
             "the predicate cannot see an unsandboxed call — the guard below measures nothing"

      fixed =
        String.replace(
          leaky,
          "Backfill.run([])",
          "BootModeSandbox.protecting(fn -> Backfill.run([]) end)"
        )

      assert unsandboxed_one_shot_invocations(fixed, modules) == [],
             "the predicate flags a SANDBOXED call too — it is reporting the call, not the leak"

      # Prose is not code: a file that only DISCUSSES the call is clean.
      prose = "# Backfill.run([]) would leak\nalias Mix.Tasks.Barkpark.Preview.Backfill\n"

      assert unsandboxed_one_shot_invocations(prose, modules) == [],
             "comment stripping is broken — prose is being read as a call"
    end

    test "no test invokes a one-shot mix task outside Barkpark.BootModeSandbox" do
      modules = one_shot_task_modules()

      offenders =
        Path.join(@test_root, "test/**/*.{ex,exs}")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.flat_map(fn path ->
          case unsandboxed_one_shot_invocations(File.read!(path), modules) do
            [] -> []
            mods -> [{Path.relative_to(path, @test_root), mods}]
          end
        end)

      assert offenders == [],
             """
             these test sources invoke a one-shot mix task with no sandbox in the file:

                 #{Enum.map_join(offenders, "\n    ", fn {f, m} -> "#{f} -> #{Enum.join(m, ", ")}" end)}

             `run/1` calls `Barkpark.OneShot.boot!/0`, which writes the NODE-GLOBAL
             `:barkpark, :boot_mode` PERSISTENTLY and never puts it back. The module
             that does this makes `Barkpark.ApplicationBootModeTest` fail `left:
             :one_shot` later in the same run — measured in elixir-nightly
             35323296944 and again in run 35509163543.

                 BootModeSandbox.protecting(fn -> SomeTask.run(argv) end)

             HONEST LIMIT, stated rather than implied: this is a FILE-level rule.
             It proves the sandbox is present in a file that invokes such a task,
             not that every call site in it is wrapped. What proves THAT is the
             runtime arm — `Barkpark.BootModeLeakFormatter` reds the run and names
             the module whose `:module_finished` found the key still set.
             """
    end
  end

  describe "the one-shot mix task guard is a PREDICATE over the shape" do
    # A source-level guard, because no `mix test` run can observe what
    # `Mix.Task.run("app.start")` does — the test node always has the full tree
    # up. This is the arm that keeps the defect from reopening under a green
    # suite.
    #
    # A PREDICATE, NOT A LIST (task-12b07c13e3cc08b6). The first version of this
    # guard enumerated the four tasks #18596 moved, so it was a SNAPSHOT: ten
    # more `app.start` one-shots were live in the tree the day it was written
    # and the guard said nothing about any of them, and the NEXT one-shot
    # someone writes would be born outside it. The rule below is: EVERY mix task
    # under `lib/mix/tasks` that calls `Mix.Task.run("app.start")` is a defect,
    # unless it is in @full_boot_allowed WITH a reason. Adding a one-shot cannot
    # slip past it; adding a genuinely-full-boot task costs one line and a
    # sentence saying why.
    #
    # Scope is the whole directory, read off DISK at test time — not a compiled
    # list — so a file added, renamed or deleted moves the guard with it.
    @tasks_dir Path.expand(Path.join([__DIR__, "..", "..", "lib", "mix", "tasks"]))

    # Each entry: task file basename => why a FULL boot is correct for it.
    # These are build/inspection tasks, not operator one-shots against a live
    # box: nothing here runs on a node whose port is already held, and each
    # needs a part of the tree `:one_shot` drops.
    @full_boot_allowed %{
      # The manifest is generated by READING the running plugin `Registry`
      # exactly as a served `GET /v1/capabilities` would, and the checked-in
      # artifact must match what a FULL node answers — including the routes the
      # Endpoint owns. Narrowing the tree here would silently generate a
      # DIFFERENT contract than the one the server serves. Stated in its own
      # @moduledoc: "app.start is required because the manifest reads the
      # running plugin Registry".
      "barkpark.openapi.ex" =>
        "generates the checked-in OpenAPI/capabilities artifact off the FULL running tree; " <>
          "a narrowed tree would generate a contract the served node does not match",

      # NOT ALLOWLISTED, and the row's wording said they would be: the
      # `gen_golden_*` / `gen_*_parity` generators
      # (barkpark.chat.gen_golden_toolrows, barkpark.chat.gen_golden_transcript,
      # barkpark.paper_components.gen_golden_parity,
      # barkpark.sheets.gen_golden_parity, barkpark.portable_doc.gen_pd_parity,
      # barkpark.preview.gen_parity) call `Mix.Task.run("app.start")` NOWHERE.
      # Exempting them would be an exemption for a violation none of them
      # commits — dead allowlist weight that overstates the real exposure. The
      # "every allowlist entry is live" test below is what caught it: six
      # entries written from the row's wording all failed on first run.

      # AUDITED 2026-09-17 (task-12b07c13e3cc08b6) and deliberately NOT moved.
      # Each reason is a MEASURED property of the task's write path, not a
      # resemblance argument — the edges precedent (dropping SchemaBootstrap
      # took the projected edge count from 962 to ZERO while still exiting 0)
      # is why "looks like one that moved" is not evidence.
      "barkpark.tags.seed.ex" =>
        "writes through `Content.create_document/4` — the full writer, whose " <>
          "post-mutation fan-out reaches `Oban.insert/1` (webhooks.ex). `:one_shot` " <>
          "drops Oban OUTRIGHT, so narrowing this would raise (or silently drop the " <>
          "fan-out). Moving it needs an Oban decision first, not a boot swap.",
      "barkpark.sheets.rehydrate_embeds.ex" =>
        "`Content.Sheets.refresh_sheet_embeds/1` ends in `Broadcast.tap_broadcast/5` — " <>
          "SSE + webhook dispatch by DESIGN, and a failed delivery schedules its retry " <>
          "with `Oban.insert/1`. Same Oban decision as tags.seed; also has no dry run, " <>
          "so there is no read-only way to prove a narrowed run still does its job.",
      "barkpark.codelists.seed.ex" =>
        "path analysis says narrowing is correct (`Content.Codelists.register/3` is a " <>
          "plain `Repo.transaction`, and `:one_shot`'s suppression of the BOOT codelist " <>
          "seeders is exactly what this task then does explicitly) — but it needs a " <>
          "publisher-supplied EDItEUR XML snapshot to run at all, and with none on this " <>
          "box the move could not be proven by a RUN. Unproven, therefore unmoved.",
      "barkpark.epic_fleet.export.ex" =>
        "path analysis says narrowing is correct (`Barkpark.EpicFleet` is pure Repo — no " <>
          "endpoint read, no Oban insert), but `epic_benchmark_experiments` holds 0 rows " <>
          "on the dev corpus, so there was no experiment to export and no run to show. " <>
          "Unproven, therefore unmoved.",
      "barkpark.epic_fleet.import.ex" =>
        "same as epic_fleet.export: pure-Repo path, but nothing to round-trip on this " <>
          "corpus and importing a fabricated payload proves the fabrication, not the move.",
      "barkpark.rotate_public_read.ex" =>
        "path analysis says narrowing is correct (`Auth.PublicRead` is pure Repo), but " <>
          "the task MINTS a token, rewrites the token file and PURGES aged rows — there " <>
          "is no dry run, and running it to prove the move would mutate real credential " <>
          "state. Unproven by a safe run, therefore unmoved.",

      # Plugin-owned operator tasks, AUDITED 2026-09-19 (task-e2c484370ef8fb51).
      # The nine that task-12b07c13e3cc08b6 left unaudited and exempted: seven
      # were moved onto `Barkpark.OneShot.boot!/0` on a RUN each (identical
      # report under both boots on the dev corpus; frt.seed re-seeded a fresh
      # database to the same content_hash) — bokbasen.list, bokbasen.status,
      # frt.export, frt.seed, onix.export_proof, codelists.staleness,
      # search.eval. These two stay, for the same Oban reason as tags.seed:
      "bokbasen.replay.ex" =>
        "its non-dry-run arm IS an `Oban.insert/1` (`PublishWorker.new/1 |> Oban.insert()`, " <>
          "the task's whole job is to enqueue the publish) — `:one_shot` drops Oban OUTRIGHT, " <>
          "so a narrowed run would raise on the one thing the operator asked for. The " <>
          "`--dry-run` arm alone is pure `Export.to_iodata/1`, but the file is one task. " <>
          "Moving it needs an Oban-accepting one-shot mode (`:seed` keeps an inert Oban), " <>
          "not a boot swap.",
      "onix.import.ex" =>
        "writes through `Content.create_document/4` / `Content.delete_document/4` — the " <>
          "full writer, whose post-mutation fan-out reaches `Oban.insert/1` (webhooks.ex). " <>
          "Same Oban decision as tags.seed. Its `--dry-run` arm already boots NOTHING " <>
          "(the `app.start` is behind `unless dry_run`), so there is no narrowed run to " <>
          "prove either."
    }

    @app_start ~S<Mix.Task.run("app.start")>

    defp task_files do
      @tasks_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.sort()
    end

    defp calls_app_start?(file) do
      @tasks_dir |> Path.join(file) |> File.read!() |> String.contains?(@app_start)
    end

    test "the guard is reading a real, non-empty task directory" do
      # PRECONDITION, not decoration: every assertion below is a statement about
      # a SET, and an empty set satisfies all of them vacuously. A renamed
      # directory would otherwise turn this whole describe block green.
      files = task_files()

      assert length(files) > 20,
             "only #{length(files)} mix task file(s) under #{@tasks_dir} — the guard is not reading the tree"

      assert "barkpark.edges.backfill.ex" in files
    end

    test "no mix task calls app.start unless it is allowlisted with a reason" do
      offenders = Enum.filter(task_files(), &calls_app_start?/1)
      unexpected = offenders -- Map.keys(@full_boot_allowed)

      assert unexpected == [],
             """
             mix task(s) still boot the FULL tree with `#{@app_start}`:

                 #{Enum.join(unexpected, "\n    ")}

             On a live box a full boot binds the SERVING slot's port ("port 4001
             already in use"), puts up a second Oban on the live queues, and runs
             the onixedit codelist seeders against the 60 s statement_timeout.

             Either boot it through `Barkpark.OneShot.boot!()` (after
             `Mix.Task.run("app.config")`), or add the file to @full_boot_allowed
             in this test WITH the reason a full boot is correct for it.
             """
    end

    test "control: the predicate finds app.start where it really is" do
      # An absence assertion needs a positive specimen or it can pass because
      # the pattern is wrong. `barkpark.openapi` is the allowlisted build-time
      # task whose full boot is intended.
      assert calls_app_start?("barkpark.openapi.ex"),
             "no mix task in the tree calls app.start any more — the predicate above measures nothing"

      refute calls_app_start?("barkpark.edges.backfill.ex"),
             "the predicate matches a task that was MOVED off app.start — it is matching the wrong text"
    end

    test "every allowlist entry is live, and carries a non-trivial reason" do
      # A ratchet in the OTHER direction: an allowlist entry for a file that no
      # longer calls app.start (or no longer exists) is dead weight that makes
      # the exemption list look bigger than the real exposure.
      files = task_files()

      for {file, reason} <- @full_boot_allowed do
        assert file in files, "@full_boot_allowed names #{file}, which is not in #{@tasks_dir}"

        assert calls_app_start?(file),
               "@full_boot_allowed still exempts #{file}, but it no longer calls app.start — drop the entry"

        assert is_binary(reason) and String.length(reason) > 30,
               "@full_boot_allowed[#{file}] needs a real reason, got: #{inspect(reason)}"
      end
    end

    test "the tasks moved onto OneShot name it, and none of them calls app.start" do
      # The positive half. Derived, not enumerated: every task file that names
      # `Barkpark.OneShot.boot!()` must also have stopped calling app.start, and
      # the set must be non-empty.
      moved =
        Enum.filter(task_files(), fn file ->
          @tasks_dir
          |> Path.join(file)
          |> File.read!()
          |> String.contains?("Barkpark.OneShot.boot!()")
        end)

      assert length(moved) >= 15,
             "only #{length(moved)} task(s) boot through Barkpark.OneShot — expected the #18596 four, " <>
               "#19173's four and task-e2c484370ef8fb51's seven"

      for file <- moved do
        refute calls_app_start?(file),
               "#{file} boots through OneShot AND still calls app.start — the old boot is still live"
      end
    end
  end

  # plugin_children are folded in under Barkpark.Plugins.Supervisor's argument.
  defp flatten_plugin_children(specs) do
    Enum.flat_map(specs, fn
      {Barkpark.Plugins.Supervisor, children} when is_list(children) -> children
      _ -> []
    end)
  end
end
