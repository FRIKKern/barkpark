defmodule BarkparkWeb.ChatStreamHostReseatTest do
  @moduledoc """
  task-aa5e85a40c317b3a: both chat SSE streams decided the registered-host seat
  once, at connect. The 2 s re-auth tick read only the token row, so an owner
  demoted to member, or removed from the workspace, kept getting a host chat's
  frames until the client reconnected: the full transcript on
  `GET /v1/chat/sessions/:id/events`, and that chat's state, heartbeat and
  title on `GET /v1/chat/events`.

  The tick now re-asks the seat. Each test opens a real stream as a token held
  for an owner (`owner_user_id`; the token's own seat is member), lets one frame
  through, changes the owner's membership, waits past one re-auth interval and
  broadcasts again.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Ecto.Query, only: [from: 2]
  import Barkpark.AccountsFixtures, only: [register_user: 1]
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.Realtime.DrainSignal
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.FleetHub
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  @dataset "production"
  @interval 300
  @env_keys [:claude_chat, :public_demo_studio, :chat_sse_reauth_interval_ms]

  setup do
    ensure_default_scope!()
    prev = Map.new(@env_keys, &{&1, Application.get_env(:barkpark, &1)})

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :chat_sse_reauth_interval_ms, @interval)

    on_exit(fn ->
      for {key, val} <- prev do
        if is_nil(val),
          do: Application.delete_env(:barkpark, key),
          else: Application.put_env(:barkpark, key, val)
      end
    end)

    ws = create_workspace!()
    {:ok, issued} = ChatHosts.issue_enrollment(ws.id, %{name: "reseat-host"})

    owner_user = register_user("reseat-#{System.unique_integer([:positive])}@example.test")
    {:ok, _} = TenancyAuth.create_membership(ws.id, owner_user.id, "owner", "user")
    {owner_raw, owner} = mint!(["read", "chat"], ws.id, owner_user_id: owner_user.id)
    assert TenancyAuth.membership_role(owner, ws.id) == "member"

    {admin_raw, _} = mint!(["read", "write", "admin"], ws.id)

    %{
      ws: ws,
      owner_user: owner_user,
      owner_raw: owner_raw,
      admin_raw: admin_raw,
      host_sid: session!(ws, "HOST-RESEAT", issued.host.id),
      managed_sid: session!(ws, "MANAGED-RESEAT", nil)
    }
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp mint!(perms, ws_id, opts \\ []) do
    raw = "reseat-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "reseat", @dataset, perms, ws_id, opts)
    {raw, token}
  end

  defp session!(ws, title, host_id) do
    target = if host_id, do: %{execution_target: "registered_host", execution_host_id: host_id}

    {:ok, s} =
      StudioChat.create_session(
        Map.merge(
          %{id: Ecto.UUID.generate(), title: title, title_source: "human", mode: "plan"},
          target || %{}
        ),
        {:workspace, ws.id}
      )

    s.id
  end

  defp owner_membership(ws, user) do
    from(m in Membership,
      where:
        m.workspace_id == ^ws.id and m.principal_id == ^user.id and m.principal_type == "user"
    )
  end

  defp demote!(%{ws: ws, owner_user: user}),
    do: {1, _} = Repo.update_all(owner_membership(ws, user), set: [role: "member"])

  defp remove!(%{ws: ws, owner_user: user}),
    do: {1, _} = Repo.delete_all(owner_membership(ws, user))

  defp json_conn(raw), do: scoped_conn() |> put_req_header("authorization", "Bearer #{raw}")

  defp subscribers(topic), do: length(Registry.lookup(Barkpark.PubSub, topic))

  defp open!(raw, path, topic) do
    before = subscribers(topic)
    task = Task.async(fn -> json_conn(raw) |> get(path) end)

    assert Enum.any?(1..100, fn _ ->
             subscribers(topic) > before or (Process.sleep(20) && false)
           end),
           "the stream never subscribed"

    task
  end

  # `{:ended, body}` when the stream closed by itself, `{:streaming, body}` when
  # it was still open and a retire broadcast closed it.
  defp finish(task) do
    Process.sleep(200)

    case Task.yield(task, 0) do
      {:ok, conn} ->
        {:ended, conn.resp_body}

      nil ->
        result =
          Enum.reduce_while(1..20, nil, fn _, _ ->
            :ok = DrainSignal.broadcast_retire()

            case Task.yield(task, 50) do
              nil -> {:cont, nil}
              result -> {:halt, result}
            end
          end) || Task.shutdown(task, :brutal_kill)

        assert match?({:ok, _}, result), "the stream never closed on a retire broadcast"
        {:ok, conn} = result
        {:streaming, conn.resp_body}
    end
  end

  defp past_one_tick, do: Process.sleep(@interval + 150)

  # Per-session stream: one title frame, the change, one interval, another.
  defp session_stream(raw, sid, change) do
    topic = Recorder.topic(sid)
    task = open!(raw, "/v1/chat/sessions/#{sid}/events", topic)

    Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, {:chat_title, sid, "BEFORE-CHANGE"})
    Process.sleep(100)
    change.()
    past_one_tick()
    Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, {:chat_title, sid, "AFTER-CHANGE"})
    finish(task)
  end

  defp fleet_frames(sids, ws, tag) do
    for {sid, n} <- Enum.with_index(sids, 1) do
      entry = %{
        seq: 9_000_000 + System.unique_integer([:positive]),
        session_id: sid,
        agent_state: "working",
        ts: DateTime.utc_now(),
        owner_ws: ws.id
      }

      topic = FleetHub.fleet_topic()
      Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, {:fleet_flip, entry})
      Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, {:fleet_heartbeat, sid, entry.ts, ws.id})
      Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, {:fleet_title, sid, "#{tag}-#{n}", ws.id})
    end
  end

  # Fleet stream: frames for the host chat (cached as visible), the change,
  # one interval, frames for the host chat and the managed one.
  defp fleet_stream(ctx, change) do
    task = open!(ctx.owner_raw, "/v1/chat/events", FleetHub.fleet_topic())

    fleet_frames([ctx.host_sid], ctx.ws, "BEFORE")
    Process.sleep(100)
    change.()
    past_one_tick()
    fleet_frames([ctx.host_sid, ctx.managed_sid], ctx.ws, "AFTER")
    finish(task)
  end

  defp after_change(body, marker) do
    parts = String.split(body, marker, parts: 2)
    assert length(parts) == 2, "#{marker} frame never arrived"
    [_, rest] = parts
    # Skip the rest of the marker's own frame.
    [_, rest] = String.split(rest, "\n\n", parts: 2)
    rest
  end

  defp event_count(body, event), do: length(String.split(body, "event: #{event}\n")) - 1

  # ── criterion 1: the per-session stream ────────────────────────────────────

  test "an owner demoted to member gets no host chat frame past one re-auth interval", ctx do
    {kind, body} = session_stream(ctx.owner_raw, ctx.host_sid, fn -> demote!(ctx) end)

    assert body =~ "BEFORE-CHANGE"
    refute body =~ "AFTER-CHANGE"
    assert kind == :ended, "the host chat stream kept running for a demoted owner"
    assert body =~ "event: unauthorized"
  end

  test "an owner removed from the workspace gets no host chat frame past one re-auth interval",
       ctx do
    {kind, body} = session_stream(ctx.owner_raw, ctx.host_sid, fn -> remove!(ctx) end)

    assert body =~ "BEFORE-CHANGE"
    refute body =~ "AFTER-CHANGE"
    assert kind == :ended, "the host chat stream kept running for a removed owner"
    assert body =~ "event: unauthorized"
  end

  test "CONTROL: an owner who stays owner keeps the host chat stream", ctx do
    assert {:streaming, body} = session_stream(ctx.owner_raw, ctx.host_sid, fn -> :ok end)
    assert body =~ "AFTER-CHANGE"
    refute body =~ "event: unauthorized"
  end

  test "CONTROL: an admin seat keeps the host chat stream when another owner is demoted", ctx do
    assert {:streaming, body} =
             session_stream(ctx.admin_raw, ctx.host_sid, fn -> demote!(ctx) end)

    assert body =~ "AFTER-CHANGE"
  end

  test "CONTROL: a managed chat's stream is not ended by the owner's demotion", ctx do
    assert {:streaming, body} =
             session_stream(ctx.owner_raw, ctx.managed_sid, fn -> demote!(ctx) end)

    assert body =~ "AFTER-CHANGE"
  end

  # ── criterion 2: the fleet stream ──────────────────────────────────────────

  test "a demoted owner's fleet stream carries no host chat frame past one re-auth interval",
       ctx do
    {kind, body} = fleet_stream(ctx, fn -> demote!(ctx) end)
    rest = after_change(body, "BEFORE-1")

    refute rest =~ ctx.host_sid
    # The stream stays open for what the caller still sees.
    assert kind == :streaming
    assert rest =~ "AFTER-2"
    assert event_count(rest, "state") == 1
    assert event_count(rest, "heartbeat") == 1
    assert event_count(rest, "title") == 1
  end

  test "a removed owner's fleet stream carries no host chat frame past one re-auth interval",
       ctx do
    {_kind, body} = fleet_stream(ctx, fn -> remove!(ctx) end)
    rest = after_change(body, "BEFORE-1")

    refute rest =~ ctx.host_sid
    refute rest =~ "AFTER-1"
  end

  test "CONTROL: an owner who stays owner keeps every host chat fleet frame", ctx do
    {:streaming, body} = fleet_stream(ctx, fn -> :ok end)
    rest = after_change(body, "BEFORE-1")

    assert rest =~ "AFTER-1"
    assert rest =~ "AFTER-2"
    assert event_count(rest, "state") == 2
    assert event_count(rest, "heartbeat") == 2
    assert event_count(rest, "title") == 2
  end

  # ── criterion 3: one re-check per interval, never one per frame ────────────

  # Session-row reads by the stream (the request task and its forwarder, both
  # carrying this test in `$callers`). `:telemetry.attach/4` is node-global.
  defp count_session_reads(fun) do
    counter = :counters.new(1, [:atomics])
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:barkpark, :repo, :query],
      fn _event, _measure, meta, _ ->
        if meta[:source] == "chat_sessions" and owner in (Process.get(:"$callers") || []),
          do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    :counters.get(counter, 1)
  end

  test "a burst of frames costs one session read per re-auth interval, not one per frame", ctx do
    session_topic = Recorder.topic(ctx.host_sid)
    session_task = open!(ctx.owner_raw, "/v1/chat/sessions/#{ctx.host_sid}/events", session_topic)
    fleet_task = open!(ctx.owner_raw, "/v1/chat/events", FleetHub.fleet_topic())

    burst = fn tag ->
      for n <- 1..10 do
        Phoenix.PubSub.broadcast(
          Barkpark.PubSub,
          session_topic,
          {:chat_title, ctx.host_sid, "#{tag}-#{n}"}
        )

        fleet_frames([ctx.host_sid], ctx.ws, "#{tag}-#{n}")
      end

      Process.sleep(100)
    end

    # The first burst caches the fleet seat and starts the session tick.
    burst.("WARM")

    within = count_session_reads(fn -> burst.("WITHIN") end)
    past_one_tick()
    across = count_session_reads(fn -> burst.("ACROSS") end)

    # One retire broadcast ends both streams.
    finish(session_task)
    finish(fleet_task)

    assert within == 0, "frames inside one interval read the session #{within} times"
    # One re-check for the per-session stream and one for the fleet forwarder.
    assert across == 2, "a burst after one interval read the session #{across} times"
  end
end
