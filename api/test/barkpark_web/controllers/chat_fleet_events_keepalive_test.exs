defmodule BarkparkWeb.ChatFleetEventsKeepaliveTest do
  @moduledoc """
  task-a0fcffbe8799abe5 — mirrors `PresenceApiTest`'s "keepalive" describe block
  (task-936472b77285df5b) for `ChatController.fleet_stream_loop/4`
  (`GET /v1/chat/events`).

  Same bug class as `stream_loop/1` and `ListenController`'s loop: a plain
  `receive ... after 30_000`, whose clock restarts on every message
  `receive` handles — including the `_other` catch-all. A fleet-wide
  connection whose mailbox kept receiving unrecognised noise faster than the
  keepalive interval could starve it indefinitely. Fixed with
  `Process.send_after/3`.

  Same "the test's own success is the proof" shape as
  `ChatEventsKeepaliveTest`: `fleet_stream_loop/4` has no independent "please
  stop" signal either, so it can only end via the keepalive-triggered
  credential check finding a revoked token.
  """
  use BarkparkWeb.ConnCase, async: false

  # Plugins-off: the studio_chat capability owns the chat supervisors, registries and /v1/chat routes
  @moduletag :requires_plugins

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Repo}
  alias Barkpark.Auth.ApiToken

  setup do
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    prev_reauth = Application.get_env(:barkpark, :chat_sse_reauth_interval_ms)
    prev_keepalive = Application.get_env(:barkpark, :chat_keepalive_ms)

    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :chat_sse_reauth_interval_ms, 0)
    Application.put_env(:barkpark, :chat_keepalive_ms, 150)

    on_exit(fn ->
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)

      if prev_reauth,
        do: Application.put_env(:barkpark, :chat_sse_reauth_interval_ms, prev_reauth),
        else: Application.delete_env(:barkpark, :chat_sse_reauth_interval_ms)

      if prev_keepalive,
        do: Application.put_env(:barkpark, :chat_keepalive_ms, prev_keepalive),
        else: Application.delete_env(:barkpark, :chat_keepalive_ms)
    end)

    raw = "fleet-ka-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "fleet-ka", "production", ["read", "write", "admin"])
    {:ok, raw: raw, token: token}
  end

  test "noise churn faster than the keepalive interval doesn't delay it reaching a revoked token",
       ctx do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:streaming, self()})

        scoped_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.raw)
        |> get("/v1/chat/events")
      end)

    pid =
      receive do
        {:streaming, pid} -> pid
      end

    Process.sleep(200)

    # Each of these matches `fleet_stream_loop/4`'s `_other` catch-all:
    # recurses directly, no write — the exact shape that reset the old
    # `after`-based clock. 12 * 30ms = 360ms of churn, longer than the
    # 150ms interval.
    for _ <- 1..12 do
      send(pid, :keepalive_test_noise)
      Process.sleep(30)
    end

    Repo.update_all(from(t in ApiToken, where: t.id == ^ctx.token.id),
      set: [revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    result = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)

    assert match?({:ok, _conn}, result),
           "the fleet stream never noticed the revoked token — the keepalive was starved by noise"

    {:ok, conn} = result
    assert conn.resp_body =~ "event: unauthorized"
  end
end
