defmodule BarkparkWeb.SseRetireOnSigtermTest do
  @moduledoc """
  task-72314c2025505d02: with BARKPARK_RETIRE_SSE_ON_SIGTERM=1 the release traps
  SIGTERM and calls `Barkpark.Realtime.DrainSignal.retire_and_await/1` before
  the default graceful stop. These tests cover that callback, and that the
  retire broadcast stays on the node that sends it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Realtime.DrainSignal

  @ds "production"

  defp subscribers, do: Registry.lookup(Barkpark.PubSub, DrainSignal.topic())

  defp await_subscribed(attempts \\ 100) do
    cond do
      subscribers() != [] -> :ok
      attempts == 0 -> flunk("the listen stream never subscribed to the retire topic")
      true -> Process.sleep(20) && await_subscribed(attempts - 1)
    end
  end

  test "retire_and_await/1 ends an open listen stream with the retire frame and returns after it closed",
       %{conn: conn} do
    ws = create_workspace!("sigterm-retire-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "sigterm-retire-proj")
    raw = "sigterm-retire-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "sigterm-retire", @ds, ["read"], ws.id)

    task =
      Task.async(fn ->
        conn
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get("/w/#{ws.slug}/p/#{proj.slug}/v1/data/listen/#{@ds}")
      end)

    await_subscribed()

    assert DrainSignal.retire_and_await(2_000) == :ok
    assert subscribers() == []

    conn = Task.await(task, 1_000)
    assert conn.resp_body =~ DrainSignal.retire_frame()
  end

  describe "on a two-node cluster" do
    setup do
      started_dist? =
        if Node.alive?() do
          false
        else
          {_, 0} = System.cmd(System.find_executable("epmd") || "epmd", ["-daemon"])
          {:ok, _} = Node.start(:"bp_retire_#{System.unique_integer([:positive])}@127.0.0.1")
          true
        end

      {:ok, peer, node} =
        :peer.start_link(%{
          name: :peer.random_name(),
          host: ~c"127.0.0.1",
          longnames: true,
          args: [~c"-setcookie", Atom.to_charlist(Node.get_cookie()), ~c"-pa" | :code.get_path()]
        })

      on_exit(fn ->
        # The peer is linked to the test process and may already be gone.
        catch_exit(:peer.stop(peer))
        if started_dist?, do: Node.stop()
      end)

      {:ok, _} = :erpc.call(node, Application, :ensure_all_started, [:phoenix_pubsub])

      # The peer runs this node's PubSub name, and a subscriber that forwards
      # whatever it receives back here. Code.eval_string because the test
      # module itself is not on the peer's code path.
      {pid, _} =
        :erpc.call(node, Code, :eval_string, [
          """
          spawn(fn ->
            {:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: Barkpark.PubSub}], strategy: :one_for_one)
            Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
            Stream.repeatedly(fn -> receive do msg -> send(test, {:peer_got, msg}) end end) |> Stream.run()
          end)
          """,
          [topic: DrainSignal.topic(), test: self()]
        ])

      {:ok, peer_node: node, peer_subscriber: pid}
    end

    test "a retire sent on one node leaves the other node's streams open" do
      # Control: a cluster-wide broadcast reaches the peer, so the cluster is
      # wired and the refute below is meaningful.
      assert Enum.any?(1..50, fn _ ->
               Phoenix.PubSub.broadcast(Barkpark.PubSub, DrainSignal.topic(), :probe)
               match?({:peer_got, :probe}, receive(do: (m -> m), after: (100 -> nil)))
             end),
             "the peer never joined this node's PubSub"

      :ok = DrainSignal.broadcast_retire()
      refute_receive {:peer_got, :retire}, 500
    end
  end
end
