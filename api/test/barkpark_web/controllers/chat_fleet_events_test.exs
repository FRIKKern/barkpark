defmodule BarkparkWeb.ChatFleetEventsTest do
  @moduledoc """
  The herd fleet stream (`GET /v1/chat/events`, chat-tui charter D44h/D45h) —
  `FleetHub` + the controller's fleet SSE seams. Follows the ChatController SSE
  convention: the long-lived `receive` loop is un-assertable through a blocking
  `get/2`, so it is proven at the public `@doc false` seams (the frame
  serializers, the pure handshake/mapping logic, the scope predicate) and at the
  `FleetHub` GenServer directly, while `get/2` proves ONLY the pipeline gate
  (auth halts before the action). Obligations map to the describe blocks below.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.FleetHub
  alias BarkparkWeb.ChatController
  alias BarkparkWeb.Studio.ClaudeChat

  @dataset "production"

  setup do
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :public_demo_studio, false)
    on_exit(fn -> Application.put_env(:barkpark, :public_demo_studio, prev_demo) end)

    admin = "fleet-admin-#{System.unique_integer([:positive])}"
    reader = "fleet-reader-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "fleet-admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(reader, "fleet-reader", @dataset, ["read"])

    %{admin: admin, reader: reader}
  end

  defp session_in!(scope, agent_state) do
    {:ok, s} =
      StudioChat.create_session(
        %{id: Ecto.UUID.generate(), cwd: ClaudeChat.cwd(), mode: "plan"},
        scope
      )

    # D80h: a blocked flip needs its :ask corroboration (a real pending ask
    # row); every other state is a :derived write through the same funnel.
    if agent_state == "blocked" do
      {:ok, _} =
        StudioChat.append_message(s.id, %{
          role: "approval",
          metadata: %{
            "request_id" => "fe-#{System.unique_integer([:positive])}",
            "approval_status" => "pending"
          }
        })

      {1, _} = StudioChat.set_agent_state(s.id, "blocked", :ask)
    else
      {1, _} = StudioChat.set_agent_state(s.id, agent_state, :derived)
    end

    s.id
  end

  # ── A. the fleet wire contract — frames are {session_id, agent_state, ts,
  #      title} ONLY; never content, never owner_workspace_id (criterion 1/4) ──

  describe "fleet frame serializers strip the stamp and carry only state" do
    test "snapshot frame: id:<epoch>:<seq>, event: snapshot, sessions carry EXACTLY the 4 wire keys" do
      ts = ~U[2026-07-18 00:00:00Z]

      frame =
        ChatController.fleet_snapshot_frame(
          [%{session_id: "s1", agent_state: "working", ts: ts, title: "one"}],
          1_700,
          3
        )

      assert String.starts_with?(frame, "id: 1700:3\nevent: snapshot\ndata: ")
      assert String.ends_with?(frame, "\n\n")

      [session] =
        frame
        |> data_payload()
        |> Map.fetch!("sessions")

      assert Map.keys(session) |> Enum.sort() == ["agent_state", "session_id", "title", "ts"]
      assert session["agent_state"] == "working"
      refute Map.has_key?(session, "owner_workspace_id")
    end

    test "state (flip) frame: id:<epoch>:<seq>, title null, owner_workspace_id STRIPPED" do
      entry = %{
        seq: 7,
        session_id: "s2",
        agent_state: "idle",
        ts: ~U[2026-07-18 00:01:00Z],
        owner_ws: "ws-SECRET-owner"
      }

      frame = ChatController.fleet_state_frame(entry, 1_700)

      assert String.starts_with?(frame, "id: 1700:7\nevent: state\ndata: ")
      # The owner_workspace_id must be structurally unable to reach the wire.
      refute frame =~ "ws-SECRET-owner"
      refute frame =~ "owner_workspace_id"

      payload = data_payload(frame)

      assert payload == %{
               "session_id" => "s2",
               "agent_state" => "idle",
               "ts" => "2026-07-18T00:01:00Z",
               "title" => nil
             }
    end

    test "heartbeat frame is id-less + seq-less (UNREPLAYABLE) — only {session_id, ts}" do
      frame = ChatController.fleet_heartbeat_frame("s3", ~U[2026-07-18 00:02:00Z])

      refute frame =~ "id:"
      assert String.starts_with?(frame, "event: heartbeat\ndata: ")
      assert data_payload(frame) == %{"session_id" => "s3", "ts" => "2026-07-18T00:02:00Z"}
    end
  end

  # ── B. fail-closed scope SEAM 1 — the snapshot Ecto query (criterion 2) ─────

  describe "fleet snapshot scope (seam 1): NULL-owner invisible to a workspace scope" do
    setup do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      %{
        ws_a: ws_a,
        ws_b: ws_b,
        a_id: session_in!({:workspace, ws_a.id}, "working"),
        b_id: session_in!({:workspace, ws_b.id}, "blocked"),
        null_id: session_in!(:global, "idle")
      }
    end

    test ":global sees every session; a workspace scope sees ONLY its own owned rows",
         %{ws_a: ws_a, a_id: a_id, b_id: b_id, null_id: null_id} do
      global_ids = StudioChat.fleet_snapshot(:global) |> Enum.map(& &1.session_id)
      assert a_id in global_ids and b_id in global_ids and null_id in global_ids

      a_snap = StudioChat.fleet_snapshot(ws_a.id)
      a_ids = Enum.map(a_snap, & &1.session_id)

      assert a_id in a_ids, "ws-A must see its own session"
      refute b_id in a_ids, "ws-A must NOT see ws-B's session"
      refute null_id in a_ids, "a NULL-owner session must be invisible to a workspace scope"

      # The snapshot rows carry ONLY the wire tuple — no content, no owner stamp.
      entry = Enum.find(a_snap, &(&1.session_id == a_id))
      assert Map.keys(entry) |> Enum.sort() == [:agent_state, :session_id, :title, :ts]
    end
  end

  # ── B2. the snapshot is the ACTIVE fleet — the shelf is not in the handshake ──

  describe "fleet snapshot excludes the archived shelf" do
    test "an archived session leaves the snapshot, and unarchiving puts it back" do
      ws = create_workspace!()
      kept = session_in!({:workspace, ws.id}, "working")
      shelved = session_in!({:workspace, ws.id}, "working")

      ids = fn scope -> StudioChat.fleet_snapshot(scope) |> Enum.map(& &1.session_id) end

      assert shelved in ids.(:global), "both sessions start on the active fleet"

      {:ok, _} = StudioChat.archive_session(shelved, ws.id)

      # The handshake snapshot is what a fresh client's WHOLE herd is seeded
      # from, and archiving is DISMISSAL: a shelved session keeps running and
      # keeps its agent_state, so nothing but this filter keeps it out of the
      # roster. Without it a dismissed session reappears on every reconnect —
      # wearing a live "working" pill, since the state is genuinely current.
      refute shelved in ids.(:global), "an archived session must not ride the fleet snapshot"
      refute shelved in ids.(ws.id), "…in a workspace scope either (same seam)"
      assert kept in ids.(ws.id), "the active sibling must still be in the snapshot"

      # And the exclusion is a FILTER, not a one-way deletion: the row returns
      # the moment it is put back, with no state to rebuild.
      {:ok, _} = StudioChat.unarchive_session(shelved, ws.id)
      assert shelved in ids.(:global)
      assert shelved in ids.(ws.id)
    end
  end

  # ── C. fail-closed scope SEAMS 2+3 — the shared term twin (criterion 2) ─────

  describe "scope_match?/2 — byte-faithful term twin of scope_sessions/2" do
    test ":global matches everything (including a NULL owner)" do
      assert StudioChat.scope_match?("ws-a", :global)
      assert StudioChat.scope_match?(nil, :global)
    end

    test "a workspace binary matches ONLY its own owner; NULL owner never matches" do
      assert StudioChat.scope_match?("ws-a", "ws-a")
      refute StudioChat.scope_match?("ws-b", "ws-a")
      refute StudioChat.scope_match?(nil, "ws-a"), "NULL owner invisible to a workspace scope"
    end

    test "any other scope fails closed" do
      refute StudioChat.scope_match?("ws-a", nil)
      refute StudioChat.scope_match?("ws-a", {:unexpected, :shape})
    end
  end

  # ── D. boot-epoch fence + mapping + handshake (SEAM 3) (criterion 3) ─────────

  describe "FleetHub boot epoch is µs wall-clock, never :erlang.unique_integer" do
    test "the live hub mints a microsecond epoch at init" do
      pid =
        start_supervised!({FleetHub, name: :"fleet_epoch_#{System.unique_integer([:positive])}"})

      {:snapshot, epoch, 0, []} = FleetHub.handshake(pid, nil, :global)

      # A µs wall-clock stamp is ~1.7e15; :erlang.unique_integer is a small
      # counter, structurally excluded by this floor + the closeness check.
      assert epoch > 1_700_000_000_000_000
      assert abs(System.system_time(:microsecond) - epoch) < 60_000_000
    end
  end

  describe "map_state/2 — byte-faithful to Recorder.map_agent_state/2" do
    test "the four-state projection incl. the :offline prior rule" do
      assert FleetHub.map_state(:working, nil) == "working"
      assert FleetHub.map_state(:needs_you, nil) == "blocked"
      assert FleetHub.map_state(:idle, "working") == "idle"
      # mid-turn death (prior working/blocked) → unknown; else idle
      assert FleetHub.map_state(:offline, "working") == "unknown"
      assert FleetHub.map_state(:offline, "blocked") == "unknown"
      assert FleetHub.map_state(:offline, "idle") == "idle"
      assert FleetHub.map_state(:offline, nil) == "idle"
    end
  end

  describe "resolve_handshake/3 — replay vs degrade (criterion 3)" do
    setup do
      ts = ~U[2026-07-18 00:00:00Z]

      state = %{
        epoch: 1_700,
        seq: 5,
        ring: [
          %{seq: 5, session_id: "s5", agent_state: "idle", ts: ts, owner_ws: nil},
          %{seq: 4, session_id: "s4", agent_state: "working", ts: ts, owner_ws: "ws-a"},
          %{seq: 3, session_id: "s3", agent_state: "blocked", ts: ts, owner_ws: "ws-b"}
        ],
        states: %{},
        owners: %{}
      }

      %{state: state}
    end

    test "fresh connect (nil cursor) → snapshot", %{state: state} do
      assert {:snapshot, 1_700, 5, []} = FleetHub.resolve_handshake(nil, :global, state)
    end

    test "wrong epoch → fresh scoped snapshot (a restart invalidated the cursor)", %{state: state} do
      assert {:snapshot, 1_700, 5, []} = FleetHub.resolve_handshake({9_999, 3}, :global, state)
    end

    test "in-ring cursor → replays EXACTLY the missed flips, seq-ascending", %{state: state} do
      assert {:replay, 1_700, 5, entries} = FleetHub.resolve_handshake({1_700, 3}, :global, state)
      assert Enum.map(entries, & &1.seq) == [4, 5]
    end

    test "ring replay filters per-entry by scope (SEAM 3)", %{state: state} do
      assert {:replay, 1_700, 5, entries} = FleetHub.resolve_handshake({1_700, 3}, "ws-a", state)
      assert Enum.map(entries, & &1.session_id) == ["s4"], "ws-a sees only its own missed flip"
    end

    test "out-of-ring cursor → degrades to a fresh scoped snapshot", %{state: state} do
      # oldest retained seq is 3; a cursor at 1 means the flip at 2/3 fell out.
      assert {:snapshot, 1_700, 5, []} = FleetHub.resolve_handshake({1_700, 1}, :global, state)
    end

    test "caught-up cursor (== current seq) → replay with nothing", %{state: state} do
      assert {:replay, 1_700, 5, []} = FleetHub.resolve_handshake({1_700, 5}, :global, state)
    end

    test "replayable?/3 rejects an ahead cursor and an empty-ring gap" do
      refute FleetHub.replayable?([], 5, 6)
      assert FleetHub.replayable?([], 0, 0)
      refute FleetHub.replayable?([], 5, 3)
    end
  end

  # ── E. live projection — dedup, ignore workflow, heartbeats (criterion 1/4) ─

  describe "FleetHub live projection over the activity topic" do
    setup do
      pid =
        start_supervised!({FleetHub, name: :"fleet_live_#{System.unique_integer([:positive])}"})

      Phoenix.PubSub.subscribe(Barkpark.PubSub, FleetHub.fleet_topic())
      %{pid: pid, sid: "sid-#{System.unique_integer([:positive])}"}
    end

    test "a four-state flip broadcasts a ring entry carrying the owner; a line-only change does NOT",
         %{pid: pid, sid: sid} do
      send(
        pid,
        {:chat_activity, sid, %{state: :working, line: "thinking…", owner_workspace_id: "ws-a"}}
      )

      assert_receive {:fleet_flip,
                      %{session_id: ^sid, agent_state: "working", owner_ws: "ws-a", seq: 1}}

      # Same mapped four-state, different line → NOT a flip (state-change only).
      send(
        pid,
        {:chat_activity, sid, %{state: :working, line: "writing…", owner_workspace_id: "ws-a"}}
      )

      refute_receive {:fleet_flip, %{session_id: ^sid}}, 100

      send(
        pid,
        {:chat_activity, sid, %{state: :needs_you, line: "approve?", owner_workspace_id: "ws-a"}}
      )

      assert_receive {:fleet_flip, %{session_id: ^sid, agent_state: "blocked", seq: 2}}
    end

    test "a {:chat_reported_state} frame rides the ring with the LITERAL four-state (herd-s6, D79h)",
         %{pid: pid, sid: sid} do
      # "unknown" is the distortion-proof probe: the wave-5 activity vocabulary
      # can only reach it through the :offline prior rule, so a reverse-mapped
      # reported frame would emit the WRONG state here.
      send(
        pid,
        {:chat_reported_state, sid,
         %{agent_state: "unknown", ts: DateTime.utc_now(), owner_workspace_id: "ws-a"}}
      )

      assert_receive {:fleet_flip,
                      %{session_id: ^sid, agent_state: "unknown", owner_ws: "ws-a", seq: 1}}

      # flips-only holds across truth sources: the same reported state again is
      # NOT a flip…
      send(
        pid,
        {:chat_reported_state, sid,
         %{agent_state: "unknown", ts: DateTime.utc_now(), owner_workspace_id: "ws-a"}}
      )

      refute_receive {:fleet_flip, %{session_id: ^sid}}, 100

      # …and a later derived transition dedups against the SAME lineage
      # (hand-back convergence on one wire).
      send(pid, {:chat_activity, sid, %{state: :working, line: "x", owner_workspace_id: "ws-a"}})
      assert_receive {:fleet_flip, %{session_id: ^sid, agent_state: "working", seq: 2}}
    end

    test "{:chat_workflow} is IGNORED — never a fleet frame (D44h)", %{pid: pid, sid: sid} do
      send(pid, {:chat_workflow, sid, %{"status" => "running"}})
      refute_receive {:fleet_flip, %{session_id: ^sid}}, 100
      refute_receive {:fleet_heartbeat, ^sid, _, _}, 100
    end

    test "a heartbeat rides as an id-less tick scoped by the session's last-seen owner",
         %{pid: pid, sid: sid} do
      ts = ~U[2026-07-18 00:03:00Z]

      # Owner learned from a prior flip.
      send(pid, {:chat_activity, sid, %{state: :working, line: "x", owner_workspace_id: "ws-a"}})
      assert_receive {:fleet_flip, %{session_id: ^sid}}

      send(pid, {:chat_heartbeat, sid, ts})
      assert_receive {:fleet_heartbeat, ^sid, ^ts, "ws-a"}

      # A heartbeat for a session FleetHub never saw fails closed (owner nil).
      unseen = "unseen-#{System.unique_integer([:positive])}"
      send(pid, {:chat_heartbeat, unseen, ts})
      assert_receive {:fleet_heartbeat, ^unseen, ^ts, nil}
    end
  end

  # ── F. the route is wired under [:api, :require_chat_access] (criterion 6) ───

  describe "GET /v1/chat/events pipeline gate" do
    test "missing bearer → 401", %{} do
      conn =
        scoped_conn()
        |> put_req_header("content-type", "application/json")
        |> get("/v1/chat/events")

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "a valid NON-admin (non-chat) bearer → 403", %{reader: reader} do
      conn = scoped_conn() |> as(reader) |> get("/v1/chat/events")
      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "a text/event-stream Accept negotiates (D6) — reaches the gate, not a 406", %{
      reader: reader
    } do
      conn =
        scoped_conn()
        |> as(reader)
        |> put_req_header("accept", "text/event-stream")
        |> get("/v1/chat/events")

      # 403 (auth halts before the blocking action), never 406 in :accepts ["json"].
      assert conn.status == 403
    end
  end

  # Attach a data-plane bearer + JSON content-type (the ChatController convention).
  defp as(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  # Decode the JSON of a single-frame SSE string's `data:` line.
  defp data_payload(frame) do
    frame
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn
      "data: " <> json -> Jason.decode!(json)
      _ -> nil
    end)
  end
end
