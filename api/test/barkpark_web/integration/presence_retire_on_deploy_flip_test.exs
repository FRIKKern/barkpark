defmodule BarkparkWeb.Integration.PresenceRetireOnDeployFlipTest do
  @moduledoc """
  task-2bcada0faa01ebb2 — `PresenceController.loop/2` is the 4th long-lived
  SSE loop (`DrainSignal.subscribe/0` was added to it alongside Listen and
  the two Chat loops): a retire broadcast must end it too with a final
  `event: retire` frame, not leave it alive-but-deaf on the retiring slot.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Realtime.DrainSignal

  @ds "production"

  setup %{conn: conn} do
    ensure_default_scope!()
    ws = create_workspace!("presence-retire-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "presence-retire-p-#{System.unique_integer([:positive])}")

    raw = "presence-retire-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "presence-retire", @ds, ["read", "write"], ws.id)

    {:ok,
     conn: put_req_header(conn, "authorization", "Bearer " <> raw),
     base: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/presence/#{@ds}"}
  end

  defp open(conn, base), do: Task.async(fn -> get(conn, base, %{}) end)

  test "a retire broadcast ends the presence stream with a final event", ctx do
    task = open(ctx.conn, ctx.base)

    # Same race as the other 3 loops' retire tests: DrainSignal.subscribe/0
    # runs inside stream/2, after track/4 and the snapshot write, so a
    # broadcast fired before that lands is simply never delivered — retry
    # the (idempotent) broadcast against the task's own completion.
    result =
      Enum.reduce_while(1..20, nil, fn _, _ ->
        :ok = DrainSignal.broadcast_retire()

        case Task.yield(task, 50) do
          nil -> {:cont, nil}
          result -> {:halt, result}
        end
      end) || Task.shutdown(task, :brutal_kill)

    assert match?({:ok, _conn}, result), "the presence stream never closed on a retire broadcast"
    {:ok, conn} = result
    assert conn.resp_body =~ "event: retire"
  end
end
