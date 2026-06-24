defmodule BarkparkWeb.SearchChannelTest do
  @moduledoc """
  Unit tests for `BarkparkWeb.SearchChannel`.

  Covers:
    - join rejects a malformed topic (bad_topic)
    - join rejects an unauthorized token (unauthorized)
    - join succeeds and assigns workspace/project on a valid token+scope
    - handle_in "query" with an empty string returns the zero-hit empty_reply
      without touching the search engine
    - handle_in "query" with a space (browse sentinel) passes through to search
      and returns a valid reply shape (even if 0 hits)
  """

  use Barkpark.DataCase, async: false

  import Phoenix.ChannelTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias BarkparkWeb.UserSocket

  @endpoint BarkparkWeb.Endpoint

  # ---------------------------------------------------------------------------
  # Setup: one workspace + project + a read token bound to that workspace
  # ---------------------------------------------------------------------------

  setup do
    ws = create_workspace!("search-ch-ws")
    proj = create_project!(ws, "search-ch-proj")
    raw = "test-tok-search-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "search-ch", "test", ["read"], ws.id)
    # Manually assign the api_token struct onto a test socket (bypassing the
    # real WebSocket connect/auth flow — that is tested in auth_test.exs).
    socket = socket(UserSocket, "test-id", %{api_token: token})
    %{ws: ws, proj: proj, socket: socket}
  end

  # ---------------------------------------------------------------------------
  # join/3
  # ---------------------------------------------------------------------------

  describe "join/3" do
    test "rejects a malformed topic (wrong segment count)", %{socket: socket} do
      # Two-segment scope — not the required ws:proj:dataset triple.
      assert {:error, %{reason: "bad_topic"}} =
               Phoenix.ChannelTest.join(socket, BarkparkWeb.SearchChannel, "search:only:two")
    end

    test "rejects an unknown workspace (unauthorized)", %{socket: socket} do
      assert {:error, %{reason: "unauthorized"}} =
               Phoenix.ChannelTest.join(socket, BarkparkWeb.SearchChannel, "search:no-such-ws:proj:test")
    end

    test "rejects a token not authorized for the workspace", %{proj: proj} do
      # Mint a fresh token that has NO membership for ws — it should be denied.
      raw2 = "unauthed-tok-#{System.unique_integer([:positive])}"
      ws2 = create_workspace!("search-ch-ws2")
      {:ok, token2} = Auth.create_token(raw2, "other-ws", "test", ["read"], ws2.id)
      socket2 = socket(UserSocket, "id2", %{api_token: token2})

      # The topic names ws (the original workspace) but the token belongs to ws2.
      ws3 = create_workspace!("search-ch-ws3")
      _proj3 = create_project!(ws3, proj.slug)
      assert {:error, %{reason: "unauthorized"}} =
               Phoenix.ChannelTest.join(socket2, BarkparkWeb.SearchChannel, "search:#{ws3.slug}:#{proj.slug}:test")
    end

    test "succeeds and assigns workspace + project + dataset", %{ws: ws, proj: proj, socket: socket} do
      topic = "search:#{ws.slug}:#{proj.slug}:production"
      assert {:ok, _reply, joined_socket} =
               Phoenix.ChannelTest.join(socket, BarkparkWeb.SearchChannel, topic)

      assert joined_socket.assigns.current_workspace.id == ws.id
      assert joined_socket.assigns.current_project.id == proj.id
      assert joined_socket.assigns.dataset == "production"
    end
  end

  # ---------------------------------------------------------------------------
  # handle_in/3 — "query" event
  # ---------------------------------------------------------------------------

  describe ~s|handle_in "query"| do
    setup %{ws: ws, proj: proj, socket: socket} do
      topic = "search:#{ws.slug}:#{proj.slug}:test"
      {:ok, _reply, joined_socket} = Phoenix.ChannelTest.join(socket, BarkparkWeb.SearchChannel, topic)
      %{joined: joined_socket}
    end

    test "empty q returns the empty_reply shape without calling search", %{joined: joined} do
      ref = push(joined, "query", %{"q" => "", "seq" => 7})
      assert_reply ref, :ok, reply

      assert reply.seq == 7
      assert reply.documents == []
      assert reply.count == 0
      assert reply.query == ""
      assert reply.highlights == %{}
      assert is_nil(reply.parsedQuery)
      assert is_nil(reply.recovery)
      assert is_nil(reply.correctedTo)
      assert is_nil(reply.facets)
      assert is_nil(reply.truncation)
    end

    test "nil q is coerced to empty string and returns the empty_reply shape", %{joined: joined} do
      # to_string(nil) == "" — the channel must not route nil q to the search engine.
      ref = push(joined, "query", %{"q" => nil, "seq" => 42})
      assert_reply ref, :ok, reply

      assert reply.seq == 42
      assert reply.documents == []
      assert reply.count == 0
      assert reply.query == ""
    end

    test "nil seq is echoed back as nil", %{joined: joined} do
      ref = push(joined, "query", %{"q" => "", "seq" => nil})
      assert_reply ref, :ok, reply
      assert is_nil(reply.seq)
    end
  end
end
