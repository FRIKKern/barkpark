defmodule Barkpark.Release.LoadAppBootScopeTest do
  @moduledoc """
  `Barkpark.Release.migrate/0` must not boot the supervision tree.

  This cannot be observed on the test node: `mix test` has already started
  `:barkpark`, so `Process.whereis(BarkparkWeb.Endpoint)` is non-nil here no
  matter what `Release.load_app/0` does. The measurement therefore runs on a
  FRESH BEAM — a `:peer` node started with this node's code paths and app
  environment, where nothing is started yet — and asks it what exists after
  the loader ran.

  Vacuity is the obvious hazard: "nothing is started" is trivially true on a
  node where nothing has been asked to start. Two guards:

    * an in-test PROBE CONTROL — a process registered under each probed name
      on the peer, proving `Process.whereis/1` on that node actually reports a
      live registration rather than always answering `nil`;
    * the MUTATION ARM, run by hand and quoted in the PR: restoring
      `load_app/0` to `Application.ensure_all_started(@app)` reds
      `the loader starts no supervision tree on a fresh node`, because the
      peer then really does start the endpoint and Oban.
  """

  use ExUnit.Case, async: false

  @probed [BarkparkWeb.Endpoint, Oban, Barkpark.Supervisor]

  setup do
    {:ok, peer, _node} =
      :peer.start_link(%{
        name: :peer.random_name(),
        connection: :standard_io,
        args: [~c"-pa" | :code.get_path()]
      })

    on_exit(fn -> try_stop(peer) end)
    {:ok, peer: peer}
  end

  defp try_stop(peer) do
    :peer.stop(peer)
  catch
    _, _ -> :ok
  end

  # Hand the peer this node's configuration. Two steps, in this order, because
  # `Application.load/1` applies the `.app` resource file's `env` key and would
  # otherwise overwrite anything already set: every app except `:barkpark` is
  # LOADED on the peer first, then the env is copied over the top. `:barkpark`
  # is deliberately left unloaded — loading it is the job of the function under
  # test, and its `.app` env is the compiled `config.exs`+`test.exs` merge, i.e.
  # already correct.
  defp seed_peer_config(peer) do
    for {app, _, _} <- Application.loaded_applications(), app != :barkpark do
      _ = :peer.call(peer, :application, :load, [app])
    end

    env =
      for {app, _, _} <- Application.loaded_applications(),
          do: {app, Application.get_all_env(app)}

    :ok = :peer.call(peer, Application, :put_all_env, [env])

    # `:mix` must be RUNNING on the peer, not merely loaded: `Barkpark.Application`
    # reaches `Mix.ProjectStack` on the way up in the test env. Without it the
    # mutation arm below would die of a missing Mix rather than of a started
    # endpoint — a control that fires for the wrong reason. Starting Mix changes
    # nothing for the unmutated loader, which starts no application at all.
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:mix])
    :peer.call(peer, Mix, :start, [])
    :peer.call(peer, Mix, :env, [Mix.env()])
    :ok
  end

  test "the probe can see a started process on the peer (control)", %{peer: peer} do
    # Precondition: the peer has NOT started the app.
    assert :peer.call(peer, Application, :started_applications, [])
           |> names()
           |> Enum.member?(:barkpark) == false

    # Control: register each probed name on the peer and prove the probe sees
    # it. Without this, the nils asserted below could mean "the probe is
    # blind", not "nothing was started".
    for name <- @probed do
      # Spawned by MFA, not by a closure: an anonymous function created here
      # cannot be resolved on a node that has never loaded this test module.
      pid = :peer.call(peer, :erlang, :spawn, [:timer, :sleep, [30_000]])
      true = :peer.call(peer, :erlang, :register, [name, pid])

      assert :peer.call(peer, Process, :whereis, [name]) == pid,
             "Process.whereis/1 is blind on the peer — every nil below would be meaningless"

      true = :peer.call(peer, :erlang, :unregister, [name])
      assert :peer.call(peer, Process, :whereis, [name]) == nil
    end
  end

  test "the loader starts no supervision tree on a fresh node", %{peer: peer} do
    # The peer boots without Mix, so it has no configuration. Hand it this
    # node's loaded-app environment, then let the loader run exactly as
    # `bin/barkpark eval "Barkpark.Release.migrate()"` runs it.
    seed_peer_config(peer)

    refute :barkpark in names(:peer.call(peer, Application, :loaded_applications, [])),
           "precondition: :barkpark must be neither loaded nor started before the loader runs"

    assert :ok = :peer.call(peer, Barkpark.Release, :load_app, [])

    assert :barkpark in names(:peer.call(peer, Application, :loaded_applications, [])),
           "the loader did not even LOAD the app — every assertion below would be vacuous"

    started = names(:peer.call(peer, Application, :started_applications, []))

    refute :barkpark in started,
           ":barkpark was STARTED by the loader (expected loaded-only), started: #{inspect(started)}"

    for name <- @probed do
      assert :peer.call(peer, Process, :whereis, [name]) == nil,
             "#{inspect(name)} is running after Release.load_app/0 — the migrate eval booted the tree"
    end

    # The loader must still have made the app's config readable: that is the
    # one thing `migrate/0` needs from it, and a loader that no-ops would pass
    # every assertion above.
    assert [_ | _] = :peer.call(peer, Application, :fetch_env!, [:barkpark, :ecto_repos])
  end

  defp names(apps), do: Enum.map(apps, fn {app, _, _} -> app end)
end
