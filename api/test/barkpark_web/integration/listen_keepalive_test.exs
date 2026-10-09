defmodule BarkparkWeb.Integration.ListenKeepaliveTest do
  @moduledoc """
  task-a0fcffbe8799abe5 — mirrors `PresenceApiTest`'s "keepalive" describe block
  (task-936472b77285df5b) for `ListenController`'s loop.

  The keepalive used to be a plain `receive ... after`, whose clock restarts
  on every message `receive` handles — including the legacy
  `{:document_changed, <not a map>}` shape `listen_recv/6` ignores by
  recursing straight back into `listen_loop/6` with no write, no
  reauth-check, nothing. A stream whose mailbox kept receiving THAT shape
  faster than the keepalive interval could starve it indefinitely. Fixed
  with `Process.send_after/3`, which keeps its own schedule regardless.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth

  @ds "production"

  setup %{conn: conn} do
    previous = Application.get_env(:barkpark, :listen_keepalive_ms)
    Application.put_env(:barkpark, :listen_keepalive_ms, 150)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :listen_keepalive_ms, previous),
        else: Application.delete_env(:barkpark, :listen_keepalive_ms)
    end)

    ws = create_workspace!("listen-ka-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "listen-ka-proj")
    raw = "listen-ka-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "listen-ka", @ds, ["read"], ws.id)

    {:ok,
     conn: put_req_header(conn, "authorization", "Bearer " <> raw),
     path: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/listen/#{@ds}"}
  end

  defp open(conn, path), do: Task.async(fn -> get(conn, path) end)

  defp close(task) do
    send(task.pid, :sse_overloaded)
    Task.await(task, 10_000)
  end

  test "legacy no-event-id churn arriving faster than the interval doesn't delay the keepalive",
       ctx do
    task = open(ctx.conn, ctx.path)

    # Each of these matches `listen_recv/6`'s "ignore legacy messages without
    # event_id" clause: recurses into `listen_loop/6` directly, no write, no
    # reauth-check — the exact shape that reset the old `after`-based clock.
    # 12 * 30ms = 360ms of churn, comfortably longer than the 150ms interval
    # (matches `PresenceApiTest`'s own keepalive test margin).
    for _ <- 1..12 do
      send(task.pid, {:document_changed, :not_a_map})
      Process.sleep(30)
    end

    assert close(task).resp_body =~ ": keepalive\n\n"
  end
end
