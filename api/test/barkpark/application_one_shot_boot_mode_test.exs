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

      on_exit(fn ->
        case original do
          {:ok, mode} -> Application.put_env(:barkpark, :boot_mode, mode)
          :error -> Application.delete_env(:barkpark, :boot_mode)
        end
      end)

      Application.put_env(:barkpark, :boot_mode, :one_shot)
      assert App.boot_mode() == :one_shot

      Application.put_env(:barkpark, :boot_mode, :one_shot_typo)
      assert_raise ArgumentError, fn -> App.boot_mode() end
    end
  end

  describe "the one-shot mix tasks use it" do
    # The four tasks the row names. A source-level guard, because no `mix test`
    # run can observe what `Mix.Task.run("app.start")` does — the test node
    # always has the full tree up. This is the arm that keeps the defect from
    # reopening under a green suite.
    @one_shot_tasks ~w(
      barkpark.edges.backfill
      barkpark.media.backfill
      barkpark.paper.backfill_block_ids
      barkpark.paper.composition_migrate
    )

    test "each names Barkpark.OneShot.boot!() and none calls app.start" do
      for task <- @one_shot_tasks do
        path =
          Path.join([__DIR__, "..", "..", "lib", "mix", "tasks", task <> ".ex"]) |> Path.expand()

        assert File.regular?(path),
               "#{task} no longer lives at #{path} — this guard is not reading it"

        source = File.read!(path)

        assert source =~ "Barkpark.OneShot.boot!()",
               "#{task} does not boot through Barkpark.OneShot — it will start the full tree"

        refute source =~ ~S<Mix.Task.run("app.start")>,
               "#{task} is back on app.start: on a live box its endpoint binds the serving slot's port"
      end
    end

    test "control: the guard's own predicate finds app.start where it really is" do
      # An absence assertion needs a positive specimen or it can pass because
      # the pattern is wrong. `barkpark.openapi` is a build-time task whose full
      # boot is intended and which is NOT in @one_shot_tasks.
      path =
        Path.join([__DIR__, "..", "..", "lib", "mix", "tasks", "barkpark.openapi.ex"])
        |> Path.expand()

      assert File.regular?(path)

      assert File.read!(path) =~ ~S<Mix.Task.run("app.start")>,
             "no mix task in the tree calls app.start any more — the refute above measures nothing"
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
