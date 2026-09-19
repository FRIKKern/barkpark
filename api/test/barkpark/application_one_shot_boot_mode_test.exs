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
      # RESTORE BY DELETION when it was unset. `put_env(:boot_mode, nil)` is NOT
      # the same state as "never set": `Barkpark.ApplicationBootModeTest`
      # asserts `fetch_env(:barkpark, :boot_mode) == :error`, and a nil restore
      # reddened it from this file. `fetch_env` is what distinguishes the two.
      original = Application.fetch_env(:barkpark, :boot_mode)

      # `persistent: true` on BOTH the write and the restore (2026-09-18). The
      # production writer is `Barkpark.OneShot.boot!/0`, which is persistent, and
      # a NON-persistent delete does not retract a persistent record: OTP keeps
      # the persistent value in its own table and re-applies it the next time
      # `:barkpark` is loaded. A restore that cannot undo every write this test
      # makes is not a restore, and the value it leaves behind is node-global —
      # `Barkpark.ApplicationBootModeTest` is the module that reads it next.
      on_exit(fn ->
        case original do
          {:ok, mode} -> Application.put_env(:barkpark, :boot_mode, mode, persistent: true)
          :error -> Application.delete_env(:barkpark, :boot_mode, persistent: true)
        end
      end)

      Application.put_env(:barkpark, :boot_mode, :one_shot, persistent: true)
      assert App.boot_mode() == :one_shot

      Application.put_env(:barkpark, :boot_mode, :one_shot_typo, persistent: true)
      assert_raise ArgumentError, fn -> App.boot_mode() end
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
