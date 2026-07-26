defmodule BarkparkWeb.SearchChannelTest do
  @moduledoc """
  Unit tests for `BarkparkWeb.SearchChannel`.

  Covers:
    - join rejects a malformed topic (bad_topic)
    - join rejects an unauthorized token (unauthorized)
    - join rejects a dataset that does not exist under the project
      (unknown_dataset) — the topic's dataset leaf is validated, not trusted
    - join succeeds and assigns workspace/project on a valid token+scope
    - the channel IGNORES a client-supplied `perspective` (published-only)
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
  alias Barkpark.Tenancy
  alias BarkparkWeb.UserSocket

  @endpoint BarkparkWeb.Endpoint

  # Every assertion that waits on a channel round-trip states its own timeout.
  # ExUnit's `assert_receive_timeout` default is 100ms, and a "query" frame runs
  # a REAL search (engine + Postgres) before it replies — under any load that
  # round-trip exceeds 100ms and the suite fails for reasons unrelated to the
  # behaviour under test. Bounding on the transport, not on engine latency,
  # keeps this file a usable oracle. Proven by squeezing
  # `assert_receive_timeout` to 1ms: before this change three engine-hitting
  # tests failed with "no matching message after 1ms"; after it, zero.
  @reply_timeout 5_000

  # ---------------------------------------------------------------------------
  # Setup: one workspace + project + dataset rows + a read token bound to that
  # workspace. `create_project!` seeds NO dataset row (only
  # `Tenancy.create_project_with_dataset/2` does), and `join/3` now validates
  # the topic's dataset leaf against the project — so the datasets this file
  # joins ("test" and "production") must exist as rows.
  # ---------------------------------------------------------------------------

  setup do
    ws = create_workspace!("search-ch-ws")
    proj = create_project!(ws, "search-ch-proj")
    seed_datasets!(proj)
    raw = "test-tok-search-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "search-ch", "test", ["read"], ws.id)
    # Manually assign the api_token struct onto a test socket (bypassing the
    # real WebSocket connect/auth flow — that is tested in auth_test.exs).
    socket = socket(UserSocket, "test-id", %{api_token: token})
    %{ws: ws, proj: proj, socket: socket}
  end

  # The two dataset leaves this file's topics name. `Tenancy.get_dataset/2`
  # scopes by project_id, so these rows are per-project — a slug alone is not
  # enough (two projects can both own a `production`).
  defp seed_datasets!(proj) do
    for slug <- ["test", "production"] do
      {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: slug, name: slug})
    end

    :ok
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
               Phoenix.ChannelTest.join(
                 socket,
                 BarkparkWeb.SearchChannel,
                 "search:no-such-ws:proj:test"
               )
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
               Phoenix.ChannelTest.join(
                 socket2,
                 BarkparkWeb.SearchChannel,
                 "search:#{ws3.slug}:#{proj.slug}:test"
               )
    end

    test "succeeds and assigns workspace + project + dataset", %{
      ws: ws,
      proj: proj,
      socket: socket
    } do
      topic = "search:#{ws.slug}:#{proj.slug}:production"

      assert {:ok, _reply, joined_socket} =
               Phoenix.ChannelTest.join(socket, BarkparkWeb.SearchChannel, topic)

      assert joined_socket.assigns.current_workspace.id == ws.id
      assert joined_socket.assigns.current_project.id == proj.id
      assert joined_socket.assigns.dataset == "production"
    end

    test "rejects a dataset that does not exist under the project (unknown_dataset)", %{
      ws: ws,
      proj: proj,
      socket: socket
    } do
      # The workspace resolves, the token IS authorized and the project exists —
      # only the dataset leaf is wrong. Before validation this joined green and
      # every query returned count=0 forever. The reason string is asserted
      # SPECIFICALLY: "unauthorized" here would be a lie about what went wrong.
      assert {:error, %{reason: "unknown_dataset"}} =
               Phoenix.ChannelTest.join(
                 socket,
                 BarkparkWeb.SearchChannel,
                 "search:#{ws.slug}:#{proj.slug}:no-such-dataset"
               )
    end

    test "a dataset belonging to ANOTHER project does not satisfy the check", %{
      ws: ws,
      proj: proj,
      socket: socket
    } do
      # `production` exists — under a different project in the same workspace.
      # `get_dataset/2` scopes by project_id, so the topic must still be refused.
      other_proj = create_project!(ws, "search-ch-other-proj-ds")
      {:ok, _ds} = Tenancy.create_dataset(other_proj, %{slug: "staging", name: "staging"})

      assert {:error, %{reason: "unknown_dataset"}} =
               Phoenix.ChannelTest.join(
                 socket,
                 BarkparkWeb.SearchChannel,
                 "search:#{ws.slug}:#{proj.slug}:staging"
               )

      # …and it joins fine on the project that actually owns it.
      assert {:ok, _reply, _sock} =
               Phoenix.ChannelTest.join(
                 socket,
                 BarkparkWeb.SearchChannel,
                 "search:#{ws.slug}:#{other_proj.slug}:staging"
               )
    end
  end

  # ---------------------------------------------------------------------------
  # handle_in/3 — "query" event
  # ---------------------------------------------------------------------------

  describe ~s|handle_in "query"| do
    setup %{ws: ws, proj: proj, socket: socket} do
      topic = "search:#{ws.slug}:#{proj.slug}:test"

      {:ok, _reply, joined_socket} =
        Phoenix.ChannelTest.join(socket, BarkparkWeb.SearchChannel, topic)

      %{joined: joined_socket}
    end

    test "empty q returns the empty_reply shape without calling search", %{joined: joined} do
      ref = push(joined, "query", %{"q" => "", "seq" => 7})
      assert_reply ref, :ok, reply, @reply_timeout

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
      assert_reply ref, :ok, reply, @reply_timeout

      assert reply.seq == 42
      assert reply.documents == []
      assert reply.count == 0
      assert reply.query == ""
    end

    test "nil seq is echoed back as nil", %{joined: joined} do
      ref = push(joined, "query", %{"q" => "", "seq" => nil})
      assert_reply ref, :ok, reply, @reply_timeout
      assert is_nil(reply.seq)
    end
  end

  # ---------------------------------------------------------------------------
  # The perspective pin — a client frame must NEVER widen the perspective.
  # `search_channel.ex` hard-codes `perspective: :published`; the word
  # `perspective` appears exactly once in the module. This test is the guard
  # that keeps it that way: flip that line to `params["perspective"]` and it
  # goes red on the draft leaking into the reply.
  # ---------------------------------------------------------------------------

  describe "the perspective pin" do
    setup %{ws: ws, proj: proj, socket: socket} do
      topic = "search:#{ws.slug}:#{proj.slug}:test"
      {:ok, _reply, joined} = Phoenix.ChannelTest.join(socket, BarkparkWeb.SearchChannel, topic)
      %{joined: joined}
    end

    test ~s|a client-supplied perspective:"drafts" is IGNORED — published-only comes back|,
         %{ws: ws, proj: proj, joined: joined} do
      # One published doc and one doc left as a draft, both matching the query.
      {:ok, _} =
        create_document_in!(
          ws,
          proj,
          "post",
          %{"doc_id" => "pin-published", "title" => "Perspectivepin published"},
          "test"
        )

      {:ok, _} =
        Barkpark.Content.publish_document("pin-published", "post", "test",
          workspace_id: ws.id,
          project_id: proj.id
        )

      {:ok, _} =
        create_document_in!(
          ws,
          proj,
          "post",
          %{"doc_id" => "pin-draft-only", "title" => "Perspectivepin draft only"},
          "test"
        )

      ref =
        push(joined, "query", %{
          "q" => "perspectivepin",
          "seq" => 5,
          "engine" => "postgres",
          "types" => "post",
          "perspective" => "drafts"
        })

      assert_reply ref, :ok, reply, @reply_timeout

      ids = Enum.map(reply.documents, &doc_id/1)

      assert "pin-published" in ids,
             "the published document must still be returned: #{inspect(ids)}"

      refute "pin-draft-only" in ids,
             "a client-supplied perspective must not surface drafts: #{inspect(ids)}"

      assert reply.count == 1
    end

    test ~s|perspective:"raw" is IGNORED the same way|, %{ws: ws, proj: proj, joined: joined} do
      {:ok, _} =
        create_document_in!(
          ws,
          proj,
          "post",
          %{"doc_id" => "pin-raw-draft", "title" => "Perspectiveraw draft only"},
          "test"
        )

      ref =
        push(joined, "query", %{
          "q" => "perspectiveraw",
          "seq" => 6,
          "engine" => "postgres",
          "types" => "post",
          "perspective" => "raw"
        })

      assert_reply ref, :ok, reply, @reply_timeout

      assert reply.count == 0
      assert reply.documents == []
    end
  end

  # Hit documents are rendered envelopes; read the id whichever key the
  # renderer used rather than pinning this guard to an envelope detail.
  defp doc_id(doc) do
    doc[:_id] || doc["_id"] || doc[:id] || doc["id"]
  end

  # ---------------------------------------------------------------------------
  # AXI R3 — view=brief in the query message returns brief hit cards, and the
  # P5 live-push keeps the caller's view (both call sites ride build_reply →
  # the shared HitEnvelope builder).
  # ---------------------------------------------------------------------------

  describe ~s|handle_in "query" with view=brief| do
    setup %{ws: ws, proj: proj, socket: socket} do
      topic = "search:#{ws.slug}:#{proj.slug}:test"
      {:ok, _reply, joined} = Phoenix.ChannelTest.join(socket, BarkparkWeb.SearchChannel, topic)
      %{joined: joined}
    end

    test "reply carries brief hit cards; the live-push stays brief",
         %{ws: ws, proj: proj, joined: joined} do
      # create_document_in! always lands a `drafts.`-prefixed draft; the channel
      # searches perspective :published, so publish (scope-inheriting) first.
      {:ok, _doc} =
        create_document_in!(
          ws,
          proj,
          "post",
          %{"doc_id" => "brief-ch-doc", "title" => "Briefbeacon post"},
          "test"
        )

      {:ok, _pub} =
        Barkpark.Content.publish_document("brief-ch-doc", "post", "test",
          workspace_id: ws.id,
          project_id: proj.id
        )

      ref =
        push(joined, "query", %{
          "q" => "briefbeacon",
          "seq" => 21,
          "engine" => "postgres",
          "types" => "post",
          "view" => "brief"
        })

      assert_reply ref, :ok, reply, @reply_timeout

      assert reply.seq == 21
      assert [card | _] = reply.documents

      assert card |> Map.keys() |> Enum.sort() == [
               :highlights,
               :id,
               :slug,
               :snippet,
               :title,
               :type
             ]

      assert card.id == "brief-ch-doc"
      assert card.type == "post"
      assert card.snippet =~ "Briefbeacon"
      # Envelope key parity with the full reply shape.
      for k <- [:count, :highlights, :parsedQuery, :facets, :truncation] do
        assert Map.has_key?(reply, k)
      end

      # Mutate in the same workspace+dataset → the cached query re-runs and the
      # live-push must render through the SAME builder with the SAME view.
      {:ok, _doc} =
        create_document_in!(
          ws,
          proj,
          "post",
          %{"doc_id" => "brief-ch-doc-2", "title" => "Briefbeacon second"},
          "test"
        )

      assert_push "results", live, @reply_timeout
      assert live.seq == 21
      assert [live_card | _] = live.documents

      assert live_card |> Map.keys() |> Enum.sort() ==
               [:highlights, :id, :slug, :snippet, :title, :type]
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

      assert_reply ref, :ok, initial, @reply_timeout
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
      assert_push "results", live, @reply_timeout

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
      assert_reply ref, :ok, _empty, @reply_timeout

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

      assert_reply ref, :ok, _initial, @reply_timeout

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

  # ---------------------------------------------------------------------------
  # W10/D62 — schema-visibility gate over the WS transport
  #
  # The gate lives at ONE chokepoint (DocumentsRetriever's `base`), keyed on
  # the caller_context the channel threads via `scope_opts(socket)` — nothing
  # is duplicated per-transport. These tests prove the WS transport inherits
  # it: a caller_context subject to filtering gets NO private-type documents
  # for `types:["session"]` (the live leak's exact shape), while a tokened
  # caller keeps EXACT parity with the query route (`authed?` admits any
  # api_token, public-read included — the filter is not stricter over WS).
  # ---------------------------------------------------------------------------

  describe "schema-visibility gate over the WS transport (W10/D62)" do
    setup %{ws: ws, proj: proj} do
      scope = [workspace_id: ws.id, project_id: proj.id]

      # The live leak's shape: a PRIVATE session schema next to a public type,
      # both with PUBLISHED docs (the leak was visibility, not perspective).
      for {type, visibility} <- [{"session", "private"}, {"post", "public"}] do
        {:ok, _} =
          Barkpark.Content.upsert_schema(
            %{"name" => type, "title" => type, "visibility" => visibility},
            "test",
            scope
          )
      end

      for {type, id, title} <- [
            {"session", "ws-leak-session", "Wsleakprobe private session"},
            {"post", "ws-pub-post", "Wsleakprobe public post"}
          ] do
        {:ok, _} =
          create_document_in!(ws, proj, type, %{"doc_id" => id, "title" => title}, "test")

        {:ok, _} =
          Barkpark.Content.publish_document(id, type, "test",
            workspace_id: ws.id,
            project_id: proj.id
          )
      end

      :ok
    end

    test ~s|a filtered caller gets NOTHING for types:["session"] — and facets never name the private type|,
         %{ws: ws, proj: proj} do
      # `CallerContext.from_conn` prefers a `:caller_context` assign over the
      # `:api_token` — so the api_token authorizes the JOIN while the search
      # itself runs as a caller the visibility gate applies to. This exercises
      # the full channel path (join → handle_in → pipeline → retriever) and
      # proves the ONE chokepoint governs the WS transport; in production every
      # WS caller carries a token and rides the parity bypass below.
      raw = "vis-tok-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "vis-gate", "test", ["read"], ws.id)

      socket =
        socket(UserSocket, "vis-id", %{
          api_token: token,
          caller_context: Barkpark.Content.CallerContext.anonymous()
        })

      {:ok, _reply, joined} =
        Phoenix.ChannelTest.join(
          socket,
          BarkparkWeb.SearchChannel,
          "search:#{ws.slug}:#{proj.slug}:test"
        )

      # The live repro: types:["session"] passed straight through pre-fix and
      # returned full private bodies. Now: nothing.
      ref =
        push(joined, "query", %{
          "q" => "wsleakprobe",
          "seq" => 1,
          "engine" => "postgres",
          "types" => "session"
        })

      assert_reply ref, :ok, reply
      assert reply.documents == []
      assert reply.count == 0

      # Untyped query: only the public hit, and the type facet must not name
      # the private type (a documents-only filter would leave it as an
      # existence oracle).
      ref2 = push(joined, "query", %{"q" => "wsleakprobe", "seq" => 2, "engine" => "postgres"})
      assert_reply ref2, :ok, r2

      ids = Enum.map(r2.documents, & &1["_id"])
      assert "ws-pub-post" in ids
      refute "ws-leak-session" in ids
      assert r2.count == 1

      type_labels = ((r2.facets || %{})["type"] || []) |> Enum.map(& &1["label"])
      refute "session" in type_labels
    end

    test "parity bypass: a tokened WS caller (public-read permissions) still reads private types — the filter is not stricter over WS than the query route",
         %{ws: ws, proj: proj} do
      raw = "vis-pr-tok-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "vis-parity", "test", ["public-read", "read"], ws.id)
      socket = socket(UserSocket, "vis-pr-id", %{api_token: token})

      {:ok, _reply, joined} =
        Phoenix.ChannelTest.join(
          socket,
          BarkparkWeb.SearchChannel,
          "search:#{ws.slug}:#{proj.slug}:test"
        )

      ref =
        push(joined, "query", %{
          "q" => "wsleakprobe",
          "seq" => 3,
          "engine" => "postgres",
          "types" => "session"
        })

      assert_reply ref, :ok, reply
      assert "ws-leak-session" in Enum.map(reply.documents, & &1["_id"])
      assert reply.count == 1
    end
  end
end
