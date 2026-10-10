defmodule BarkparkWeb.SseRetireOnDeployFlipTest do
  @moduledoc """
  task-2bcada0faa01ebb2 — on a blue/green deploy's Caddy flip, an SSE stream
  opened before the flip stays on the RETIRING slot: writes now land on the
  new slot's PubSub, which the old slot never sees, so the stream sits
  alive-but-deaf (still sending keepalives) for the ~20-30s the old slot
  takes to drain and stop. `Barkpark.Realtime.DrainSignal.broadcast_retire/0`
  ends every subscribed stream AT ONCE with a distinguishable final frame,
  so the client reconnects through Caddy to the slot that's actually live
  (replaying via Last-Event-ID — nothing lost, just no blackout).

  Covers 3 of the 4 loops `DrainSignal.subscribe/0` was added to
  (`ListenController.listen_recv/6`, `ChatController.stream_loop/1`,
  `ChatController.fleet_stream_loop/4` — `PresenceController.loop/2` has its
  own test, `presence_retire_on_deploy_flip_test.exs`, alongside its own
  keepalive test file), plus the real `POST /v1/internal/retire-sse`
  endpoint end-to-end (route -> controller -> broadcast -> subscriber),
  proven once via the listen stream rather than four times — the endpoint
  itself is loop-agnostic.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Realtime.DrainSignal
  alias Barkpark.{Auth, StudioChat}

  @ds "production"

  defp open(conn, path), do: Task.async(fn -> get(conn, path) end)

  # `DrainSignal.subscribe/0` runs inside the stream's own request process,
  # after some per-route setup (a DB-backed snapshot for the fleet route) —
  # there is no external signal for "it has subscribed now", and a single
  # broadcast fired before that call lands is simply never delivered (unlike
  # a direct `send/2`, a PubSub broadcast reaches only CURRENTLY-subscribed
  # processes; it does not sit in a not-yet-subscribed process's mailbox).
  # `broadcast_retire/0` is idempotent and cheap, so retry it against the
  # task's own completion instead of guessing a `Process.sleep` long enough
  # — a fixed sleep was measured flaky here (one task process order out of
  # several reproduced the race within 200ms).
  defp retire_until_closed(task, attempts \\ 20, interval_ms \\ 50) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      :ok = DrainSignal.broadcast_retire()

      case Task.yield(task, interval_ms) do
        nil -> {:cont, nil}
        result -> {:halt, result}
      end
    end) || Task.shutdown(task, :brutal_kill)
  end

  describe "ListenController.listen_recv/6" do
    setup %{conn: conn} do
      ws = create_workspace!("listen-retire-#{System.unique_integer([:positive])}")
      proj = create_project!(ws, "listen-retire-proj")
      raw = "listen-retire-" <> Ecto.UUID.generate()
      {:ok, _} = Auth.create_token(raw, "listen-retire", @ds, ["read"], ws.id)

      {:ok,
       conn: put_req_header(conn, "authorization", "Bearer " <> raw),
       path: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/listen/#{@ds}"}
    end

    test "a retire broadcast ends the stream with a final event, not a silent hang", ctx do
      task = open(ctx.conn, ctx.path)

      result = retire_until_closed(task)
      assert match?({:ok, _conn}, result), "the listen stream never closed on a retire broadcast"
      {:ok, conn} = result
      assert conn.resp_body =~ "event: retire"
      assert conn.resp_body =~ "slot_retiring"
    end

    test "the REAL POST /v1/internal/retire-sse endpoint ends it too (route -> controller -> broadcast)",
         ctx do
      task = open(ctx.conn, ctx.path)

      result =
        Enum.reduce_while(1..20, nil, fn _, _ ->
          retire_conn = post(scoped_conn(), "/v1/internal/retire-sse")
          assert retire_conn.status == 204

          case Task.yield(task, 50) do
            nil -> {:cont, nil}
            result -> {:halt, result}
          end
        end) || Task.shutdown(task, :brutal_kill)

      assert match?({:ok, _conn}, result), "the listen stream never closed via the real endpoint"
      {:ok, conn} = result
      assert conn.resp_body =~ "event: retire"
    end
  end

  describe "ChatController.stream_loop/1" do
    setup do
      prev_chat = Application.get_env(:barkpark, :claude_chat)
      prev_demo = Application.get_env(:barkpark, :public_demo_studio)

      Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
      Application.put_env(:barkpark, :public_demo_studio, false)

      on_exit(fn ->
        if prev_chat,
          do: Application.put_env(:barkpark, :claude_chat, prev_chat),
          else: Application.delete_env(:barkpark, :claude_chat)

        Application.put_env(:barkpark, :public_demo_studio, prev_demo)
      end)

      raw = "chat-retire-#{System.unique_integer([:positive])}"
      {:ok, _token} = Auth.create_token(raw, "chat-retire", @ds, ["read", "write", "admin"])

      {:ok, session} =
        StudioChat.create_session(%{
          id: Ecto.UUID.generate(),
          cwd: BarkparkWeb.Studio.ClaudeChat.cwd(),
          mode: "plan"
        })

      {:ok, raw: raw, sid: session.id}
    end

    test "a retire broadcast ends the session stream with a final event", ctx do
      task =
        Task.async(fn ->
          scoped_conn()
          |> put_req_header("authorization", "Bearer " <> ctx.raw)
          |> get("/v1/chat/sessions/#{ctx.sid}/events")
        end)

      result = retire_until_closed(task)

      assert match?({:ok, _conn}, result),
             "the chat session stream never closed on a retire broadcast"

      {:ok, conn} = result
      assert conn.resp_body =~ "event: retire"
    end
  end

  describe "ChatController.fleet_stream_loop/4" do
    @moduletag :requires_plugins

    setup do
      prev_demo = Application.get_env(:barkpark, :public_demo_studio)
      Application.put_env(:barkpark, :public_demo_studio, false)
      on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev_demo) end)

      raw = "fleet-retire-#{System.unique_integer([:positive])}"
      {:ok, _token} = Auth.create_token(raw, "fleet-retire", @ds, ["read", "write", "admin"])
      {:ok, raw: raw}
    end

    test "a retire broadcast ends the fleet stream with a final event", ctx do
      task =
        Task.async(fn ->
          scoped_conn()
          |> put_req_header("authorization", "Bearer " <> ctx.raw)
          |> get("/v1/chat/events")
        end)

      result = retire_until_closed(task)
      assert match?({:ok, _conn}, result), "the fleet stream never closed on a retire broadcast"
      {:ok, conn} = result
      assert conn.resp_body =~ "event: retire"
    end
  end
end
