defmodule BarkparkWeb.ChatSseTokenLivenessTest do
  @moduledoc """
  Realtime authz sweep (r4a): the chat SSE stream outlived its token.

  `GET /v1/chat/sessions/:id/events` authorizes once at connect and never
  sheds (D5). A bearer revoked afterwards — by `Auth.revoke_token/1`, whose
  teardown only reaches WebSockets, or by a SCIM bulk revoke — or one that
  expired, kept receiving the session's live frames until the client left.
  The stream now re-checks the token before writing each frame.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Repo, StudioChat}
  alias Barkpark.Auth.ApiToken

  setup do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    prev_interval = Application.get_env(:barkpark, :chat_sse_reauth_interval_ms)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :chat_sse_reauth_interval_ms, 0)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)

      if prev_interval,
        do: Application.put_env(:barkpark, :chat_sse_reauth_interval_ms, prev_interval),
        else: Application.delete_env(:barkpark, :chat_sse_reauth_interval_ms)
    end)

    raw = "chat-sse-live-#{System.unique_integer([:positive])}"

    {:ok, token} =
      Auth.create_token(raw, "chat-sse-live", "production", ["read", "write", "admin"])

    {:ok, session} =
      StudioChat.create_session(%{
        id: Ecto.UUID.generate(),
        cwd: BarkparkWeb.Studio.ClaudeChat.cwd(),
        mode: "plan"
      })

    {:ok, raw: raw, token: token, sid: session.id}
  end

  # Open the stream, change the world, then deliver one live frame. Returns
  # `{:ended, body}` when the stream terminated, `:still_streaming` otherwise.
  defp stream_after(ctx, fun) do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:streaming, self()})

        build_conn()
        |> put_req_header("authorization", "Bearer " <> ctx.raw)
        |> get("/v1/chat/sessions/#{ctx.sid}/events")
      end)

    pid =
      receive do
        {:streaming, pid} -> pid
      end

    Process.sleep(300)
    fun.()
    send(pid, {:chat_title, ctx.sid, "AFTER-REVOKE-TITLE"})

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, conn} -> {:ended, conn.resp_body}
      _ -> :still_streaming
    end
  end

  test "a token revoked mid-stream ends the chat stream before the next frame", ctx do
    result =
      stream_after(ctx, fn ->
        Repo.update_all(from(t in ApiToken, where: t.id == ^ctx.token.id),
          set: [revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )
      end)

    assert match?({:ended, _}, result), "the chat stream kept running for a revoked token"
    {:ended, body} = result
    refute body =~ "AFTER-REVOKE-TITLE"
    assert body =~ "event: unauthorized"
  end

  test "a live token's chat stream keeps streaming (control)", ctx do
    assert stream_after(ctx, fn -> :ok end) == :still_streaming
  end
end
