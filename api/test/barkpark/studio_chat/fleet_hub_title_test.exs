defmodule Barkpark.StudioChat.FleetHubTitleTest do
  @moduledoc """
  S3 / charter D69h — the async AI title rides the fleet wire. `Titles.kick_title`
  broadcasts `{:chat_title, sid, title}` on `Recorder.activity_topic/0`;
  `FleetHub` re-projects it onto the fleet topic as an id-less, seq-less,
  never-ringed `{:fleet_title, sid, title, owner_ws}` scoped by the session's
  LAST-SEEN owner (the fail-closed heartbeat fallback). Follows the
  `ChatFleetEventsTest` convention: the blocking SSE loop is proven at its
  public seams — the `FleetHub` GenServer, the frame serializer, and the
  `scope_match?/2` predicate the loop's drop decision inlines.
  """
  # async: false — the title seams are wired through Application env (global),
  # and the tests broadcast on the shared activity topic.
  use ExUnit.Case, async: false

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.FleetHub
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Titles
  alias BarkparkWeb.ChatController

  defmodule FailingAdapter do
    # The API layer always falls through, keying the pipeline to the fake CLI.
    def post(_url, _body, _headers), do: {:error, :offline}
  end

  defmodule FakeCli do
    def run(_binary, _args), do: {:ok, ~s({"title":"Fleet title"})}
  end

  defmodule AcceptingStore do
    def maybe_set_ai_title(_session_id, title), do: {:ok, title}
  end

  defmodule RefusingStore do
    def maybe_set_ai_title(_session_id, _title), do: {:error, :human_renamed}
  end

  setup do
    Application.put_env(:barkpark, :studio_chat_title_http_adapter, FailingAdapter)
    Application.put_env(:barkpark, :studio_chat_title_cli, FakeCli)
    Application.put_env(:barkpark, :studio_chat_store, AcceptingStore)

    on_exit(fn ->
      for k <- [:studio_chat_title_http_adapter, :studio_chat_title_cli, :studio_chat_store] do
        Application.delete_env(:barkpark, k)
      end
    end)

    pid =
      start_supervised!({FleetHub, name: :"fleet_title_#{System.unique_integer([:positive])}"})

    Phoenix.PubSub.subscribe(Barkpark.PubSub, FleetHub.fleet_topic())

    %{hub: pid, sid: "sid-#{System.unique_integer([:positive])}"}
  end

  # ── A. the pipeline: a title write reaches a held fleet stream, scoped ─────

  describe "kick_title → activity topic → FleetHub → fleet wire (D69h)" do
    test "an accepted title write reaches an already-connected fleet subscriber WITHOUT reconnect, carrying the last-seen owner",
         %{hub: hub, sid: sid} do
      # The hub learned this session's owner from a prior activity flip
      # (delivered directly, so ONLY this test hub knows the owner).
      send(hub, {:chat_activity, sid, %{state: :working, line: "x", owner_workspace_id: "ws-a"}})
      assert_receive {:fleet_flip, %{session_id: ^sid, seq: 1}}

      # The full title pipeline — no handshake, no reconnect, one broadcast.
      {:ok, _task} = Titles.kick_title(sid, "make a fleet title")

      assert_receive {:fleet_title, ^sid, "Fleet title", "ws-a"}, 2_000

      # The connection loop's scope decision over EXACTLY that emitted owner:
      # a matching workspace forwards, a foreign one drops, :global sees all.
      assert StudioChat.scope_match?("ws-a", "ws-a")
      refute StudioChat.scope_match?("ws-a", "ws-b")
      assert StudioChat.scope_match?("ws-a", :global)
    end

    test "ONE broadcast serves both surfaces — the LiveView tuple and the fleet frame come from the same write, no parallel fork",
         %{sid: sid} do
      # Subscribe like chat_live does at mount: the SAME {:chat_title, ...}
      # tuple its existing handle_info clause matches must arrive, exactly once.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())

      {:ok, _task} = Titles.kick_title(sid, "make a fleet title")

      assert_receive {:chat_title, ^sid, "Fleet title"}, 2_000
      refute_receive {:chat_title, ^sid, _}, 300
    end

    test "a refused store write (clobber guard) broadcasts NOTHING onto either wire", %{sid: sid} do
      Application.put_env(:barkpark, :studio_chat_store, RefusingStore)
      Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())

      {:ok, _task} = Titles.kick_title(sid, "make a fleet title")

      refute_receive {:chat_title, ^sid, _}, 500
      refute_receive {:fleet_title, ^sid, _, _}, 100
    end
  end

  # ── B. fail-closed scope — the heartbeat owner fallback (D43h) ─────────────

  describe "title scope fails closed for an unseen session" do
    test "a title for a session FleetHub never saw carries a nil owner — invisible to every workspace scope",
         %{hub: hub, sid: sid} do
      send(hub, {:chat_title, sid, "Orphan title"})

      assert_receive {:fleet_title, ^sid, "Orphan title", nil}

      # The loop's drop decision: nil owner never matches a workspace scope
      # (fail-closed), while :global still observes it.
      refute StudioChat.scope_match?(nil, "ws-a")
      assert StudioChat.scope_match?(nil, :global)
    end
  end

  # ── C. heartbeat-shaped: never seq'd, never ringed, never replayable ───────

  describe "title frames are id-less (D69h)" do
    test "a title event consumes NO seq and claims NO ring slot", %{hub: hub, sid: sid} do
      send(hub, {:chat_activity, sid, %{state: :working, line: "x", owner_workspace_id: "ws-a"}})
      assert_receive {:fleet_flip, %{session_id: ^sid, seq: 1}}

      send(hub, {:chat_title, sid, "Ringless title"})
      assert_receive {:fleet_title, ^sid, "Ringless title", "ws-a"}

      # seq still 1 (nothing minted) …
      assert {:snapshot, epoch, 1, []} = FleetHub.handshake(hub, nil, :global)

      # … and a full-ring replay holds ONLY the state flip — no title entry.
      assert {:replay, ^epoch, 1, [%{seq: 1, agent_state: "working"}]} =
               FleetHub.handshake(hub, {epoch, 0}, :global)
    end

    test "the wire frame is id-less, event: title, and carries ONLY {session_id, title}" do
      frame = ChatController.fleet_title_frame("s1", "My title")

      refute frame =~ "id:"
      assert String.starts_with?(frame, "event: title\ndata: ")
      assert String.ends_with?(frame, "\n\n")
      assert data_payload(frame) == %{"session_id" => "s1", "title" => "My title"}
      refute frame =~ "owner_workspace_id"
    end
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
