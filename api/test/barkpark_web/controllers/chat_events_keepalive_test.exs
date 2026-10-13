defmodule BarkparkWeb.ChatEventsKeepaliveTest do
  @moduledoc """
  task-a0fcffbe8799abe5 — mirrors `PresenceApiTest`'s "keepalive" describe block
  (task-936472b77285df5b) for `ChatController.stream_loop/1`.

  The keepalive used to be a plain `receive ... after 30_000`, whose clock
  restarts on every message `receive` handles — including the `_other`
  catch-all, which matches ANY unrecognised message and recurses straight
  back into `stream_loop/1` with no write. A session whose mailbox kept
  receiving unrecognised noise faster than the keepalive interval could
  starve it indefinitely. Fixed with `Process.send_after/3`, which keeps its
  own schedule regardless.

  `stream_loop/1` has no independent "please stop" signal the way
  `PresenceController`'s loop does (`:sse_overloaded`) or `ListenController`'s
  does (same) — the only way it naturally returns is the per-write credential
  check (`sse_credential_live?/1`) finding a revoked token, which only runs
  when something calls `chunk_or_stop/2`. So THIS test's own success is
  itself the proof: the stream can only end (and `Task.yield` succeed) if the
  keepalive actually fired and caught the revocation, despite the churn.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Repo, StudioChat}
  alias Barkpark.Auth.ApiToken

  setup do
    prev_chat = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    prev_reauth = Application.get_env(:barkpark, :chat_sse_reauth_interval_ms)
    prev_keepalive = Application.get_env(:barkpark, :chat_keepalive_ms)

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :chat_sse_reauth_interval_ms, 0)
    Application.put_env(:barkpark, :chat_keepalive_ms, 150)

    on_exit(fn ->
      if prev_chat,
        do: Application.put_env(:barkpark, :claude_chat, prev_chat),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)

      if prev_reauth,
        do: Application.put_env(:barkpark, :chat_sse_reauth_interval_ms, prev_reauth),
        else: Application.delete_env(:barkpark, :chat_sse_reauth_interval_ms)

      if prev_keepalive,
        do: Application.put_env(:barkpark, :chat_keepalive_ms, prev_keepalive),
        else: Application.delete_env(:barkpark, :chat_keepalive_ms)
    end)

    raw = "chat-ka-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "chat-ka", "production", ["read", "write", "admin"])

    {:ok, session} =
      StudioChat.create_session(%{
        id: Ecto.UUID.generate(),
        cwd: BarkparkWeb.Studio.ClaudeChat.cwd(),
        mode: "plan"
      })

    {:ok, raw: raw, token: token, sid: session.id}
  end

  test "noise churn faster than the keepalive interval doesn't delay it reaching a revoked token",
       ctx do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:streaming, self()})

        scoped_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.raw)
        |> get("/v1/chat/sessions/#{ctx.sid}/events")
      end)

    pid =
      receive do
        {:streaming, pid} -> pid
      end

    Process.sleep(200)

    # Each of these matches `stream_loop/1`'s `_other` catch-all: recurses
    # directly, no write — the exact shape that reset the old `after`-based
    # clock. 12 * 30ms = 360ms of churn, longer than the 150ms interval.
    for _ <- 1..12 do
      send(pid, :keepalive_test_noise)
      Process.sleep(30)
    end

    Repo.update_all(from(t in ApiToken, where: t.id == ^ctx.token.id),
      set: [revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    result = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)

    assert match?({:ok, _conn}, result),
           "the chat stream never noticed the revoked token — the keepalive was starved by noise"

    {:ok, conn} = result
    assert conn.resp_body =~ "event: unauthorized"
  end
end
