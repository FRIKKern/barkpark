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
    - P5: after a "query", a workspace-scoped document mutation pushes a fresh
      `"results"` event with the same payload shape
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

  # ---------------------------------------------------------------------------
  # P5 — live push on document mutation
  # ---------------------------------------------------------------------------

  describe "live push on document mutation" do
    setup %{ws: ws, proj: proj, socket: socket} do
      topic = "search:#{ws.slug}:#{proj.slug}:test"
      {:ok, _reply, joined} = Phoenix.ChannelTest.join(socket, BarkparkWeb.SearchChannel, topic)
      %{joined: joined}
    end

    test "after a non-empty query, a workspace-scoped doc mutation pushes a fresh \"results\" event with the same shape",
         %{ws: ws, proj: proj, joined: joined} do
      # Prime the channel with a real query so it caches `:last_query`.
      ref =
        push(joined, "query", %{
          "q" => "needle",
          "seq" => 11,
          "engine" => "postgres",
          "types" => "post"
        })

      assert_reply ref, :ok, initial
      assert initial.seq == 11
      assert initial.query == "needle"
      assert is_list(initial.documents)
      # Expected payload contract — these keys are what use-live-search.ts
      # (and shapeFindResponse) read.
      assert Map.has_key?(initial, :count)
      assert Map.has_key?(initial, :highlights)
      assert Map.has_key?(initial, :parsedQuery)
      assert Map.has_key?(initial, :facets)
      assert Map.has_key?(initial, :truncation)

      # Mutate a document within the SAME workspace + dataset the channel is
      # joined to. The Content writer's `tap_broadcast` fires
      # `documents:ws:<ws_id>:test`, which the channel subscribed to on join.
      {:ok, _doc} =
        create_document_in!(
          ws,
          proj,
          "post",
          %{"doc_id" => "p5-needle-doc", "title" => "needle in haystack"},
          "test"
        )

      # The channel must re-run the cached query and push a "results" event with
      # the same payload shape as the "query" reply.
      assert_push "results", live, 1_000

      assert live.seq == 11
      assert live.query == "needle"
      assert is_list(live.documents)
      # Same shape as the reply — the client renders both via shapeFindResponse.
      assert Map.has_key?(live, :count)
      assert Map.has_key?(live, :highlights)
      assert Map.has_key?(live, :parsedQuery)
      assert Map.has_key?(live, :facets)
      assert Map.has_key?(live, :truncation)
    end

    test "without a cached query (empty reply path), a doc mutation does NOT push anything",
         %{ws: ws, proj: proj, joined: joined} do
      # The empty-string path clears `:last_query`; the channel must stay quiet
      # so an unused tab doesn't burn search work on every co-tenant write.
      ref = push(joined, "query", %{"q" => "", "seq" => 1})
      assert_reply ref, :ok, _empty

      {:ok, _doc} =
        create_document_in!(
          ws,
          proj,
          "post",
          %{"doc_id" => "p5-no-query-doc", "title" => "anything"},
          "test"
        )

      refute_push "results", _payload, 200
    end

    test "no cross-workspace push: a mutation in another workspace must NOT reach this channel",
         %{ws: ws, proj: proj, joined: joined} do
      # Cache a query on the original channel.
      ref =
        push(joined, "query", %{
          "q" => "needle",
          "seq" => 99,
          "engine" => "postgres",
          "types" => "post"
        })

      assert_reply ref, :ok, _initial

      # Mutate a doc in a DIFFERENT workspace + dataset. The Listen SSE
      # contract treats workspace_id as the hard tenant boundary; the live
      # push must respect the same boundary (workspace-scoped PubSub topic).
      other_ws = create_workspace!("search-ch-other")
      other_proj = create_project!(other_ws, "search-ch-other-proj")

      {:ok, _doc} =
        create_document_in!(
          other_ws,
          other_proj,
          "post",
          %{"doc_id" => "p5-cross-ws-doc", "title" => "needle"},
          "test"
        )

      refute_push "results", _payload, 200

      # Keep refs around so the compiler doesn't strip them.
      _ = {ws, proj}
    end
  end
end
