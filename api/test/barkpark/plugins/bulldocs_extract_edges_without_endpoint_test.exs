defmodule Barkpark.Plugins.BulldocsExtractEdgesWithoutEndpointTest do
  @moduledoc """
  `Barkpark.Plugins.Bulldocs.extract_edges/2` must answer on a node where
  `BarkparkWeb.Endpoint` is NOT running (task-557cf9a71e949768).

  THE DEFECT, found by the one-shot narrowing and measured on the local dev
  corpus on 2026-09-16. Deciding whether an absolute `href` points at THIS
  instance went through `BarkparkWeb.Endpoint.url/0`, which is an
  `:ets.lookup(BarkparkWeb.Endpoint, :url)` — a table that exists only once the
  endpoint has STARTED. `mix barkpark.edges.backfill` now boots in `:one_shot`
  mode, which drops the endpoint on purpose so an operator one-shot cannot bind
  the live slot's port. So the ETS read raised inside the resolver chain, the
  chain's per-plugin rescue SWALLOWED it, and the sweep reported success:

      with an endpoint:     294 doc(s), 962 projected edge(s)
      without an endpoint:  294 doc(s),  94 projected edge(s)     exit 0 both times

  A backfill that silently writes a tenth of the content graph is worse than
  one that dies, and no exit code, log line or report says which run you got.

  WHY A PEER NODE. The measurement is impossible on the test node: `mix test`
  starts `:barkpark` in `:full` mode, so the endpoint's ETS table is always
  there and the BROKEN code passes. Same harness as
  `Barkpark.SeedsCleanConnectUrlWithoutEndpointTest` (PR #18569), which fixed
  the same defect family in `Barkpark.Seeds.Clean.connect_url/0`.

  ANTI-VACUITY, four ways:

    * a PRECONDITION assert that the peer really has no endpoint ETS table;
    * a MUTATION CONTROL that calls the OLD expression on that same peer and
      requires it to RAISE — the revert, executed;
    * a NEGATIVE arm: an href on a FOREIGN host must still project NO edge, so
      the fix cannot pass by making `own_public_host?/1` answer true for
      everything;
    * a QUIET arm on the local node, where the endpoint IS running, asserting
      the answer is byte-identical to the endpoint-backed one.
  """

  use ExUnit.Case, async: false

  alias Barkpark.Plugins.Bulldocs

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

    {:ok, peer: peer, host: own_host()}
  end

  defp own_host do
    :barkpark
    |> Application.get_env(BarkparkWeb.Endpoint, [])
    |> Keyword.get(:url, [])
    |> Keyword.get(:host) || "localhost"
  end

  defp doc_with_href(href) do
    %{
      doc_id: "from-paper",
      content: %{
        "body" => [
          %{"type" => "paragraph", "content" => [%{"type" => "link", "href" => href}]}
        ]
      }
    }
  end

  test "precondition: :barkpark is loaded on the peer and the endpoint is NOT started", %{
    peer: peer
  } do
    assert :barkpark in names(:peer.call(peer, Application, :loaded_applications, [])),
           "the peer never loaded :barkpark — the config read could not work for the right reason"

    refute :barkpark in names(:peer.call(peer, Application, :started_applications, []))

    assert :peer.call(peer, :ets, :whereis, [BarkparkWeb.Endpoint]) == :undefined,
           "the peer HAS an endpoint ETS table — this is not the one_shot-mode state"
  end

  test "mutation control: the pre-fix expression still raises on that peer", %{peer: peer} do
    # `BarkparkWeb.Endpoint.url()` is verbatim what `own_public_host?/1` used to
    # call. Running the revert, rather than describing it, is the arm that reds
    # if the fix is undone.
    result =
      try do
        {:returned, :peer.call(peer, BarkparkWeb.Endpoint, :url, [])}
      rescue
        e -> {:raised, e.__struct__}
      catch
        kind, reason -> {:caught, kind, reason}
      end

    refute match?({:returned, _}, result),
           "BarkparkWeb.Endpoint.url/0 no longer fails without a started endpoint " <>
             "(got #{inspect(result)}) — the tests below can no longer tell fixed from broken"
  end

  test "an own-host absolute href still projects its edge with no endpoint running", %{
    peer: peer,
    host: host
  } do
    doc = doc_with_href("https://#{host}/papers/target-paper")

    edges = :peer.call(peer, Bulldocs, :extract_edges, [doc, %{}])

    assert [%{to_id: "target-paper", kind: "references"}] = edges
  end

  test "negative arm: a FOREIGN host href still projects nothing with no endpoint running", %{
    peer: peer
  } do
    doc = doc_with_href("https://someone-elses-instance.example/papers/target-paper")

    assert :peer.call(peer, Bulldocs, :extract_edges, [doc, %{}]) == [],
           "a foreign-host href projected an edge — own_public_host?/1 now answers true for everything"
  end

  test "quiet arm: with the endpoint RUNNING the answers are unchanged", %{host: host} do
    assert :ets.whereis(BarkparkWeb.Endpoint) != :undefined,
           "the endpoint is not running on the test node — this arm would measure the fallback twice"

    assert [%{to_id: "target-paper", kind: "references"}] =
             Bulldocs.extract_edges(doc_with_href("https://#{host}/papers/target-paper"), %{})

    assert Bulldocs.extract_edges(
             doc_with_href("https://someone-elses-instance.example/papers/target-paper"),
             %{}
           ) == []
  end

  defp names(apps), do: Enum.map(apps, fn {app, _, _} -> app end)
end
