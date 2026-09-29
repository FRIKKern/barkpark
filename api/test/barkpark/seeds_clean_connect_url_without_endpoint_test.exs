defmodule Barkpark.SeedsCleanConnectUrlWithoutEndpointTest do
  @moduledoc """
  `Barkpark.Seeds.Clean.connect_url/0` must answer on a node where
  `BarkparkWeb.Endpoint` is NOT running (task shb-bl-release-load-app).

  THE DEFECT, measured against a real assembled release on 2026-09-16.
  `Barkpark.Release.seed/0` boots in `:seed` mode, which drops the endpoint
  from the child list on purpose (`Barkpark.Application.child_specs/5`).
  `connect_url/0` read `BarkparkWeb.Endpoint.config(:url)`, which is an
  `:ets.lookup/2` against a table that exists only once the endpoint has
  STARTED, so the last step of a first-ever boot died:

      ** (ArgumentError) errors were found at the given arguments:
        * 1st argument: the table identifier does not refer to an existing ETS table
          (stdlib 7.3) :ets.lookup(BarkparkWeb.Endpoint, :url)
          (barkpark 0.1.0) lib/barkpark/seeds/clean.ex:232: Barkpark.Seeds.Clean.connect_url/0
          (barkpark 0.1.0) lib/barkpark/seeds/clean.ex:208: Barkpark.Seeds.Clean.print_token_banner/1

  `api/entrypoint.sh` runs under `set -e`, so that killed the container before
  `bin/barkpark start` — and it swallowed the shown-once admin token the banner
  exists to print.

  WHY A PEER NODE. The measurement is impossible on the test node: `mix test`
  starts `:barkpark` in `:full` mode, so the endpoint's ETS table is always
  there and the BROKEN code passes. Same reason
  `Barkpark.Release.LoadAppBootScopeTest` uses a peer. The peer LOADS
  `:barkpark` without starting it — exactly the state `config/2` cannot
  survive.

  ANTI-VACUITY, three ways:

    * a PRECONDITION assert that the peer really has no endpoint ETS table;
    * a MUTATION CONTROL that calls the OLD expression on that same peer and
      requires it to RAISE. That is the revert, executed: if it ever stops
      raising, this file's green means nothing and says so;
    * a QUIET arm on the local node, where the endpoint IS running, asserting
      the answer is byte-identical to the direct endpoint read — the fallback
      must not become a second source of truth.
  """

  use ExUnit.Case, async: false

  alias Barkpark.Seeds.Clean

  setup do
    {:ok, peer, _node} =
      :peer.start_link(%{
        name: :peer.random_name(),
        connection: :standard_io,
        args: [~c"-pa" | :code.get_path()]
      })

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end
    end)

    for {app, _, _} <- Application.loaded_applications(), app != :barkpark do
      _ = :peer.call(peer, :application, :load, [app])
    end

    env =
      for {app, _, _} <- Application.loaded_applications(),
          do: {app, Application.get_all_env(app)}

    :ok = :peer.call(peer, Application, :put_all_env, [env])
    :ok = :peer.call(peer, Barkpark.Release, :load_app, [])

    {:ok, peer: peer}
  end

  test "precondition: :barkpark is loaded on the peer and the endpoint is NOT started", %{
    peer: peer
  } do
    assert :barkpark in names(:peer.call(peer, Application, :loaded_applications, [])),
           "the peer never loaded :barkpark — the config read could not work for the right reason"

    refute :barkpark in names(:peer.call(peer, Application, :started_applications, []))

    assert :peer.call(peer, :ets, :whereis, [BarkparkWeb.Endpoint]) == :undefined,
           "the peer HAS an endpoint ETS table — this is not the seed-mode state"
  end

  test "mutation control: the pre-fix expression still raises on that peer", %{peer: peer} do
    # `BarkparkWeb.Endpoint.config(:url)` is verbatim what `connect_url/0` used
    # to call. Running the revert, rather than describing it, is the arm that
    # reds if the fix is undone — and the arm that says so out loud if Phoenix
    # ever stops needing the table.
    result =
      try do
        {:returned, :peer.call(peer, BarkparkWeb.Endpoint, :config, [:url])}
      rescue
        e -> {:raised, e.__struct__}
      catch
        kind, reason -> {:caught, kind, reason}
      end

    refute match?({:returned, _}, result),
           "BarkparkWeb.Endpoint.config(:url) no longer fails without a started endpoint " <>
             "(got #{inspect(result)}) — the test below can no longer tell fixed from broken"
  end

  test "connect_url/0 answers without a started endpoint", %{peer: peer} do
    url = :peer.call(peer, Clean, :connect_url, [])

    assert is_binary(url), "connect_url/0 returned #{inspect(url)} on an endpoint-less node"

    assert url =~ ~r{^https?://[^/]+:\d+$},
           "connect_url/0 returned #{inspect(url)} — not a dialable scheme://host:port"
  end

  test "quiet arm: with the endpoint RUNNING the answer is unchanged" do
    assert :ets.whereis(BarkparkWeb.Endpoint) != :undefined,
           "the endpoint is not running on the test node — this arm would measure the fallback twice"

    url = BarkparkWeb.Endpoint.config(:url) || []
    http = BarkparkWeb.Endpoint.config(:http) || []
    expected = "#{url[:scheme] || "http"}://#{url[:host] || "localhost"}:#{http[:port] || 4000}"

    assert Clean.connect_url() == expected,
           "the fallback changed the answer on a node where the endpoint is up"
  end

  defp names(apps), do: Enum.map(apps, fn {app, _, _} -> app end)
end
