defmodule BarkparkWeb.ChatFleetHostSeatTest do
  @moduledoc """
  task-1910050f9b350976: the fleet stream (`GET /v1/chat/events`) and the rollup
  sent a member the id, title and state of a chat on the workspace's registered
  host, which every id door already hides (task-f44bbb6363d28e37). A subscriber
  now gets no frame for a host chat it may not see (snapshot, live state,
  heartbeat, title), and the rollup does not count it. The seat that sees it is
  the seat that drives it: an owner or admin seat in the session's workspace
  (BarkBot's admin token), or a token held for an owner.

  The stream runs for real: the GET runs in a task, frames are broadcast on the
  fleet topic once its forwarder has subscribed, and a retire broadcast ends it
  so the body can be read.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.Realtime.DrainSignal
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.FleetHub
  alias Barkpark.StudioChat.Session

  @dataset "production"

  setup do
    ensure_default_scope!()
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)
    on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev_demo) end)

    ws = create_workspace!()
    {:ok, issued} = ChatHosts.issue_enrollment(ws.id, %{name: "fleet-host"})

    {member_raw, _} = mint!(["read", "chat"], ws.id)
    {admin_raw, _} = mint!(["read", "write", "admin"], ws.id)

    host_sid = session!(ws, "HOST-FLEET-TITLE", "blocked", issued.host.id)
    managed_sid = session!(ws, "MANAGED-FLEET-TITLE", "idle", nil)

    %{
      ws: ws,
      member_raw: member_raw,
      admin_raw: admin_raw,
      host_sid: host_sid,
      managed_sid: managed_sid
    }
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp mint!(perms, ws_id) do
    raw = "fleet-seat-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "fleet seat", @dataset, perms, ws_id)
    {raw, token}
  end

  defp session!(ws, title, agent_state, host_id) do
    target = if host_id, do: %{execution_target: "registered_host", execution_host_id: host_id}

    {:ok, s} =
      StudioChat.create_session(
        Map.merge(
          %{id: Ecto.UUID.generate(), title: title, title_source: "human", mode: "plan"},
          target || %{}
        ),
        {:workspace, ws.id}
      )

    Repo.update!(Ecto.Changeset.change(Repo.get!(Session, s.id), agent_state: agent_state))
    s.id
  end

  defp json_conn(raw), do: scoped_conn() |> put_req_header("authorization", "Bearer #{raw}")

  defp subscribers, do: length(Registry.lookup(Barkpark.PubSub, FleetHub.fleet_topic()))

  # Open the stream as `raw`, broadcast one state, heartbeat and title frame
  # for each session id once its forwarder has subscribed, then end it and
  # answer the body.
  defp stream_body(raw, sids, ws) do
    before = subscribers()
    task = Task.async(fn -> json_conn(raw) |> get("/v1/chat/events") end)

    assert Enum.any?(1..100, fn _ ->
             subscribers() > before or (Process.sleep(20) && false)
           end),
           "the fleet stream never subscribed"

    for {sid, n} <- Enum.with_index(sids, 1) do
      entry = %{
        seq: 9_000_000 + n,
        session_id: sid,
        agent_state: "working",
        ts: DateTime.utc_now(),
        owner_ws: ws.id
      }

      Phoenix.PubSub.broadcast(Barkpark.PubSub, FleetHub.fleet_topic(), {:fleet_flip, entry})
      ts = DateTime.utc_now()

      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        FleetHub.fleet_topic(),
        {:fleet_heartbeat, sid, ts, ws.id}
      )

      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        FleetHub.fleet_topic(),
        {:fleet_title, sid, "LIVE-TITLE-#{n}", ws.id}
      )
    end

    # The frames reach the connection through the forwarder; give them a beat.
    Process.sleep(200)

    result =
      Enum.reduce_while(1..20, nil, fn _, _ ->
        :ok = DrainSignal.broadcast_retire()

        case Task.yield(task, 50) do
          nil -> {:cont, nil}
          result -> {:halt, result}
        end
      end) || Task.shutdown(task, :brutal_kill)

    assert match?({:ok, _}, result), "the fleet stream never closed on a retire broadcast"
    {:ok, conn} = result
    assert conn.status == 200, conn.resp_body
    conn.resp_body
  end

  defp event_count(body, event), do: length(String.split(body, "event: #{event}\n")) - 1

  # ── a member sees no frame for the host chat ───────────────────────────────

  test "a member subscribed to the fleet stream gets no frame for the host session",
       %{ws: ws, member_raw: member_raw, host_sid: host_sid, managed_sid: managed_sid} do
    body = stream_body(member_raw, [host_sid, managed_sid], ws)

    refute body =~ host_sid
    refute body =~ "HOST-FLEET-TITLE"
    refute body =~ "LIVE-TITLE-1"

    # CONTROL, same stream: the managed session rides every frame kind.
    assert body =~ "MANAGED-FLEET-TITLE"
    assert body =~ "LIVE-TITLE-2"
    assert event_count(body, "state") == 1
    assert event_count(body, "heartbeat") == 1
    assert event_count(body, "title") == 1
  end

  test "a member's rollup does not count the host session",
       %{member_raw: member_raw} do
    body = json_conn(member_raw) |> get("/v1/chat/rollup") |> json_response(200)

    assert body["counts"]["blocked"] == 0
    assert body["counts"]["idle"] == 1
    assert body["precedence"] == "idle"
  end

  # ── the seats that see it ──────────────────────────────────────────────────

  test "CONTROL: an admin-seat token (BarkBot's) still gets every frame for the host session",
       %{ws: ws, admin_raw: admin_raw, host_sid: host_sid, managed_sid: managed_sid} do
    body = stream_body(admin_raw, [host_sid, managed_sid], ws)

    assert body =~ "HOST-FLEET-TITLE"
    assert body =~ "LIVE-TITLE-1"
    assert event_count(body, "state") == 2
    assert event_count(body, "heartbeat") == 2
    assert event_count(body, "title") == 2
  end

  test "CONTROL: an admin-seat token's rollup is exactly the store's",
       %{ws: ws, admin_raw: admin_raw} do
    body = json_conn(admin_raw) |> get("/v1/chat/rollup") |> json_response(200)
    store = StudioChat.rollup({:workspace, ws.id})

    assert body["counts"]["blocked"] == 1
    assert body["precedence"] == "blocked"
    assert body == Jason.decode!(Jason.encode!(store))
  end

  test "a session id with no row is left out of the live stream (fail closed)",
       %{ws: ws, admin_raw: admin_raw} do
    ghost = Ecto.UUID.generate()
    body = stream_body(admin_raw, [ghost], ws)

    refute body =~ ghost
  end
end
