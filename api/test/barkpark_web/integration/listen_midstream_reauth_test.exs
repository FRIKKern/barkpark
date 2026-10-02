defmodule BarkparkWeb.Integration.ListenMidstreamReauthTest do
  @moduledoc """
  Realtime authz sweep (r4a): an open listen stream outlived its credential.

  `ListenController` authorized once, at connect. A token revoked or expired
  afterwards, or a member removed from the workspace, kept receiving fully
  re-rendered documents for as long as the client stayed connected; the
  revocation teardown broadcast reaches only WebSocket transports. The stream
  now re-checks the bearer (and, for a member, the membership) each loop turn
  and ends with an `unauthorized` frame.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Repo}
  alias Barkpark.Auth.ApiToken

  @ds "production"

  setup %{conn: conn} do
    previous = Application.get_env(:barkpark, :listen_reauth_interval_ms)
    Application.put_env(:barkpark, :listen_reauth_interval_ms, 0)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :listen_reauth_interval_ms, previous),
        else: Application.delete_env(:barkpark, :listen_reauth_interval_ms)
    end)

    ws = create_workspace!("listen-reauth-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "listen-reauth-proj")

    raw = "listen-reauth-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "listen-reauth", @ds, ["read"], ws.id)

    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:ws:#{ws.id}:#{@ds}")
    {:ok, doc} = create_document_in!(ws, proj, "memo", %{"title" => "AFTER-REVOKE-DOC"}, @ds)

    msg =
      receive do
        {:document_changed, %{doc_id: id} = m} when id == doc.doc_id -> m
      after
        2_000 -> flunk("no broadcast for the fixture document")
      end

    {:ok,
     conn: put_req_header(conn, "authorization", "Bearer " <> raw),
     path: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/listen/#{@ds}",
     ws: ws,
     token: token,
     msg: msg}
  end

  # Open the stream, let `fun` change the world, then deliver the live event.
  defp stream_after(conn, path, msg, fun) do
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:streaming, self()})
        get(conn, path)
      end)

    pid =
      receive do
        {:streaming, pid} -> pid
      end

    # Give the stream time to connect and arm before the world changes.
    Process.sleep(200)
    fun.()
    send(pid, {:document_changed, msg})
    send(pid, :sse_overloaded)
    Task.await(task, 20_000).resp_body
  end

  test "a token revoked mid-stream (bulk update, no teardown) gets no further documents", ctx do
    body =
      stream_after(ctx.conn, ctx.path, ctx.msg, fn ->
        Repo.update_all(from(t in ApiToken, where: t.id == ^ctx.token.id),
          set: [revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )
      end)

    refute body =~ "AFTER-REVOKE-DOC", "a revoked token kept receiving documents on the stream"
    assert body =~ "event: unauthorized"
  end

  test "a member removed mid-stream gets no further documents", ctx do
    body =
      stream_after(ctx.conn, ctx.path, ctx.msg, fn ->
        {:ok, _} =
          Barkpark.Tenancy.Members.remove_member(ctx.ws.id, %{type: :api_token, id: ctx.token.id})
      end)

    refute body =~ "AFTER-REVOKE-DOC", "a removed member kept receiving documents on the stream"
  end

  test "a live member keeps receiving documents (control)", ctx do
    body = stream_after(ctx.conn, ctx.path, ctx.msg, fn -> :ok end)
    assert body =~ "AFTER-REVOKE-DOC"
  end
end
