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
  import Barkpark.RateLimiterSandbox

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

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state the SQL sandbox
  # does not roll back. This file exercises it for real: the connect budget below
  # runs `RateLimiter.check/2` inside `UserSocket.connect/3`, so without the reset
  # this file both inherits buckets earlier files spent and leaves its own spent
  # for later ones, and every result here depends on the run order.
  # `rate_limiter_async_isolation_test.exs` is the ratchet that requires it; this
  # file is `async: false`, which is what makes clearing shared state safe.
  setup :reset_rate_limiter!

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
  # The pagination offset clamp — the channel twin of the media offset clamp
  # (#15560) and the same ceiling the HTTP document routes already enforce
  # (`QueryController.index/2` :46, `SearchController` :46/:110,
  # `Content.Query`'s `@max_offset`): `|> max(0) |> min(100_000)`.
  #
  # ASSERTED ON `:last_query.opts_base`, not on the reply, deliberately: that
  # cached keyword list IS the value handed to `Content.search_documents/3` (and
  # re-handed on every live re-run), so it reads the clamp at the door rather
  # than a downstream retriever's own re-clamp. MUTATION-PROOF: drop
  # `clamp_offset(...)` from `run_query/4` and both assertions go red with the
  # raw 5_000_000 / -5.
  # ---------------------------------------------------------------------------

  describe "the pagination offset clamp" do
    setup %{ws: ws, proj: proj, socket: socket} do
      topic = "search:#{ws.slug}:#{proj.slug}:test"
      {:ok, _reply, joined} = Phoenix.ChannelTest.join(socket, BarkparkWeb.SearchChannel, topic)
      %{joined: joined}
    end

    defp cached_offset(joined) do
      :sys.get_state(joined.channel_pid).assigns.last_query.opts_base[:offset]
    end

    test "an absurd offset is clamped to the 100_000 ceiling", %{joined: joined} do
      ref = push(joined, "query", %{"q" => "needle", "seq" => 1, "offset" => 5_000_000})
      assert_reply ref, :ok, _reply, @reply_timeout

      assert cached_offset(joined) == 100_000,
             "an unclamped offset reached Content.search_documents/3"
    end

    test "a negative offset is floored at 0", %{joined: joined} do
      ref = push(joined, "query", %{"q" => "needle", "seq" => 2, "offset" => -5})
      assert_reply ref, :ok, _reply, @reply_timeout

      assert cached_offset(joined) == 0,
             "a negative offset reached Content.search_documents/3 (OFFSET -5 is a Postgres error)"
    end

    test "an in-range offset is passed through untouched", %{joined: joined} do
      ref = push(joined, "query", %{"q" => "needle", "seq" => 3, "offset" => 25})
      assert_reply ref, :ok, _reply, @reply_timeout

      assert cached_offset(joined) == 25, "the clamp must not disturb a legitimate page"
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

    # INVERTED by dr-w2-s7. This case used to assert that a public-read WS
    # caller read private types "for parity with the query route" — but the
    # query route's `authed?/1` moved in the same commit, so parity now means
    # CLAMPED on both. The retriever is the one enforcement seat, which is why
    # one clause seals REST, federated and this WS transport together.
    test "a public-read WS caller is clamped: asking for the private type by name yields an " <>
           "empty reply, not its rows",
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
      refute "ws-leak-session" in Enum.map(reply.documents, & &1["_id"])
      assert reply.count == 0
    end

    test "NON-REGRESSION: a {read} WS caller still reads the private type over the same channel",
         %{ws: ws, proj: proj} do
      raw = "vis-read-tok-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "vis-read", "test", ["read"], ws.id)
      socket = socket(UserSocket, "vis-read-id", %{api_token: token})

      {:ok, _reply, joined} =
        Phoenix.ChannelTest.join(
          socket,
          BarkparkWeb.SearchChannel,
          "search:#{ws.slug}:#{proj.slug}:test"
        )

      ref =
        push(joined, "query", %{
          "q" => "wsleakprobe",
          "seq" => 4,
          "engine" => "postgres",
          "types" => "session"
        })

      assert_reply ref, :ok, reply
      assert "ws-leak-session" in Enum.map(reply.documents, & &1["_id"])
      assert reply.count == 1
    end
  end

  # ---------------------------------------------------------------------------
  # The per-socket "query" throttle (row task-2d29572b9b46ec01)
  #
  # A "query" frame runs a full Content.search_documents against Postgres. The
  # HTTP twin is capped at 300 reads/min by Plugs.RateLimit; a channel frame
  # enters below the router and reaches NO plug. These tests pin the cap that
  # replaces it, in the channel, per socket.
  #
  # The limits are read from config so the budget under test is a handful of
  # frames rather than 30 — with a real Postgres search between frames, a
  # 30-token bucket refilling at 300/min would need dozens of round-trips to
  # deplete and the count at which it tips would be a function of machine load.
  # `query_per_minute: 1` makes the refill (~0.017/s) negligible across the
  # whole test, so "burst frames pass, the next is refused" is arithmetic, not
  # a race.
  # ---------------------------------------------------------------------------

  describe ~s|the per-socket "query" throttle| do
    setup %{ws: ws, proj: proj, socket: socket} do
      prev = Application.get_env(:barkpark, :search_channel)
      Application.put_env(:barkpark, :search_channel, query_per_minute: 1, query_burst: 3)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:barkpark, :search_channel)
          cfg -> Application.put_env(:barkpark, :search_channel, cfg)
        end
      end)

      {:ok, _reply, joined} =
        Phoenix.ChannelTest.join(
          socket,
          BarkparkWeb.SearchChannel,
          "search:#{ws.slug}:#{proj.slug}:test"
        )

      %{joined: joined}
    end

    test "the frame past the budget is refused with a named reason; the ones inside it are answered",
         %{joined: joined} do
      # Burst = 3: three back-to-back frames are answered normally.
      for seq <- 1..3 do
        ref =
          push(joined, "query", %{"q" => "throttleprobe", "seq" => seq, "engine" => "postgres"})

        assert_reply ref, :ok, reply, @reply_timeout
        assert reply.seq == seq
      end

      # The fourth has no credit left. On unmodified main it is answered like
      # the three before it and this assertion is what goes red.
      ref = push(joined, "query", %{"q" => "throttleprobe", "seq" => 4, "engine" => "postgres"})

      assert_reply ref, :error, err, @reply_timeout
      assert err.reason == "rate_limited"
      assert err.seq == 4
      # The client is told how long to wait, not just "no".
      assert is_integer(err.retry_after_ms) and err.retry_after_ms > 0
    end

    test "the empty-query frame is NOT billed — it never touches Postgres", %{joined: joined} do
      # Spend the whole burst on empty frames; a real query must still be
      # answered afterwards. Rationing a frame that answers from a literal
      # would spend a search's budget on nothing.
      for seq <- 1..6 do
        ref = push(joined, "query", %{"q" => "", "seq" => seq})
        assert_reply ref, :ok, reply, @reply_timeout
        assert reply.count == 0
      end

      ref = push(joined, "query", %{"q" => "throttleprobe", "seq" => 7, "engine" => "postgres"})
      assert_reply ref, :ok, reply, @reply_timeout
      assert reply.seq == 7
    end

    test "a refused frame does not poison the socket — credit keeps accruing", %{joined: joined} do
      for seq <- 1..3 do
        ref =
          push(joined, "query", %{"q" => "throttleprobe", "seq" => seq, "engine" => "postgres"})

        assert_reply ref, :ok, _reply, @reply_timeout
      end

      ref = push(joined, "query", %{"q" => "throttleprobe", "seq" => 4, "engine" => "postgres"})
      assert_reply ref, :error, %{reason: "rate_limited"}, @reply_timeout

      # Widen the budget and push again: the socket must serve the very next
      # frame. If a refusal froze the socket's clock (the shape RateLimiter's
      # own debit/4 warns about) or zeroed its allowance, this stays refused.
      Application.put_env(:barkpark, :search_channel, query_per_minute: 6_000, query_burst: 3)

      # 6_000/min is 0.1 credit per ms, so 50ms of real elapsed time buys 5 —
      # bounded below, not a race: a slow box only sleeps longer. Reading the
      # widened config without waiting for the clock to move is what fails,
      # since the allowance is earned from the monotonic interval, not from
      # the config change itself.
      Process.sleep(50)

      ref = push(joined, "query", %{"q" => "throttleprobe", "seq" => 5, "engine" => "postgres"})
      assert_reply ref, :ok, reply, @reply_timeout
      assert reply.seq == 5
    end
  end

  # ---------------------------------------------------------------------------
  # The flagship half of crit 6, as far as a ChannelCase can reach it: at the
  # SHIPPED defaults (no config override), a normal search-as-you-type cadence
  # is answered and still returns count>0. The other half — the same keystroke
  # over a real WebSocket from a deployed search-starter site — is not provable
  # from this suite and is reported as owed.
  # ---------------------------------------------------------------------------

  describe "the throttle does not dark normal typing (shipped defaults)" do
    setup %{ws: ws, proj: proj, socket: socket} do
      # No Application.put_env here ON PURPOSE: this test is only worth
      # anything against the constants that actually ship.
      refute Application.get_env(:barkpark, :search_channel),
             "this test must run at the shipped defaults, with no config override in scope"

      {:ok, _} =
        create_document_in!(
          ws,
          proj,
          "post",
          %{"doc_id" => "cadence-doc", "title" => "Cadenceprobe live search hit"},
          "test"
        )

      {:ok, _} =
        Barkpark.Content.publish_document("cadence-doc", "post", "test",
          workspace_id: ws.id,
          project_id: proj.id
        )

      {:ok, _reply, joined} =
        Phoenix.ChannelTest.join(
          socket,
          BarkparkWeb.SearchChannel,
          "search:#{ws.slug}:#{proj.slug}:test"
        )

      %{joined: joined}
    end

    test "a keystroke-cadence run of frames all answer, and the hit still comes back",
         %{joined: joined} do
      # Ten frames — a word typed into the box. Every one must be answered and
      # every one must still find the document.
      for seq <- 1..10 do
        ref =
          push(joined, "query", %{
            "q" => "cadenceprobe",
            "seq" => seq,
            "engine" => "postgres",
            "types" => "post"
          })

        assert_reply ref, :ok, reply, @reply_timeout
        assert reply.seq == seq

        assert reply.count > 0,
               "the throttle must not dark a normal keystroke: frame #{seq} returned count=0"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The connect budget — SOCKETS, not frames (row crit 3)
  #
  # The per-socket throttle bounds one socket. Nothing bounded how many sockets
  # one credential could open, so a caller opening a fresh socket per query
  # walked around it. This exercises UserSocket.connect/3 for real (the rest of
  # this file hand-assigns the token onto a test socket and never runs it).
  # ---------------------------------------------------------------------------

  describe "the per-token connect budget" do
    setup %{ws: ws} do
      prev = Application.get_env(:barkpark, :user_socket)
      Application.put_env(:barkpark, :user_socket, connects_per_minute: 2)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:barkpark, :user_socket)
          cfg -> Application.put_env(:barkpark, :user_socket, cfg)
        end
      end)

      raw = "test-tok-connect-#{System.unique_integer([:positive])}"
      {:ok, _token} = Auth.create_token(raw, "connect-budget", "test", ["read"], ws.id)
      %{raw: raw}
    end

    test "a token past its socket budget cannot open another socket", %{raw: raw} do
      assert {:ok, _s1} = connect(UserSocket, %{"token" => raw})
      assert {:ok, _s2} = connect(UserSocket, %{"token" => raw})

      # Third connect with the same (valid, unrevoked) token is refused. On
      # unmodified main every one of these succeeds, without limit.
      assert :error = connect(UserSocket, %{"token" => raw})
    end

    test "the budget is per token, not global — a second token still connects", %{
      ws: ws,
      raw: raw
    } do
      assert {:ok, _} = connect(UserSocket, %{"token" => raw})
      assert {:ok, _} = connect(UserSocket, %{"token" => raw})
      assert :error = connect(UserSocket, %{"token" => raw})

      other_raw = "test-tok-connect-other-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(other_raw, "connect-budget-2", "test", ["read"], ws.id)

      assert {:ok, _} = connect(UserSocket, %{"token" => other_raw})
    end
  end

  # ---------------------------------------------------------------------------
  # Revocation + seat removal teardown (row task-d67f007715c96828)
  #
  # `UserSocket.connect/3` runs `Auth.verify_token/1` ONCE and `join/3` runs
  # `TenancyAuth.authorize/3` ONCE. Both decisions used to outlive their inputs
  # forever: a revoked token kept answering "query" frames and kept streaming a
  # "results" push on every co-tenant write, and nothing could force the socket
  # down because `id/1` returned nil.
  #
  # The expected topic is spelled out LITERALLY here rather than borrowed from
  # `UserSocket.disconnect_topic/1`. Two reasons: asserting a function equals
  # itself proves nothing, and this file must still COMPILE against unmodified
  # main so the red-first run reports failures rather than a compile error.
  # ---------------------------------------------------------------------------
  # The connect budget's IP key rides the canonical client-ip resolver
  #
  # A bucket is only a limit if the client cannot choose its own key.
  # `x-forwarded-for` is client-supplied text, and a caller reaching the box
  # directly could otherwise mint a fresh key per connection and have no
  # effective per-IP limit at all. `Barkpark.RateLimiter.client_ip/1`
  # (@canonical capability:rate-limit-client-ip) owns that decision; these
  # tests prove `UserSocket` actually rides it, in BOTH directions — a forged
  # header from an untrusted peer must not move the key, AND a chain from a
  # TRUSTED peer must still be honoured, because ignoring the header outright
  # would also pass the first test while collapsing every visitor behind our
  # own Caddy into one bucket in production.
  #
  # NON-VACUITY: every connect below uses a FRESH token. The token key would
  # otherwise be the thing refusing, and these tests would pass no matter what
  # the IP key did.
  # ---------------------------------------------------------------------------

  describe "the connect budget's IP key" do
    setup %{ws: ws} do
      prev = Application.get_env(:barkpark, :user_socket)
      Application.put_env(:barkpark, :user_socket, connects_per_minute: 2)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:barkpark, :user_socket)
          cfg -> Application.put_env(:barkpark, :user_socket, cfg)
        end
      end)

      # A fresh token per connect, so only the IP key can refuse.
      mint = fn ->
        raw = "test-tok-ip-#{System.unique_integer([:positive])}"
        {:ok, _} = Auth.create_token(raw, "ip-budget", "test", ["read"], ws.id)
        raw
      end

      %{mint: mint}
    end

    test "a forged x-forwarded-for from an UNTRUSTED peer does not move the bucket key", %{
      mint: mint
    } do
      # 203.0.113.7 is not a trusted proxy, so the resolver must ignore the
      # header entirely and key on the verified peer.
      peer = fn xff ->
        %{peer_data: %{address: {203, 0, 113, 7}}, x_headers: [{"x-forwarded-for", xff}]}
      end

      assert {:ok, _} = connect(UserSocket, %{"token" => mint.()}, connect_info: peer.("9.9.9.9"))
      assert {:ok, _} = connect(UserSocket, %{"token" => mint.()}, connect_info: peer.("9.9.9.9"))

      # Third connect ROTATES the forged header. If the header were believed,
      # this would be a brand-new bucket with a full allowance — i.e. no per-IP
      # limit at all. It must still be refused.
      assert :error =
               connect(UserSocket, %{"token" => mint.()}, connect_info: peer.("8.8.8.8"))

      # ...and a genuinely different PEER still connects, which proves the
      # refusal above came from the IP bucket and not from something global.
      other =
        %{peer_data: %{address: {198, 51, 100, 4}}, x_headers: [{"x-forwarded-for", "9.9.9.9"}]}

      assert {:ok, _} = connect(UserSocket, %{"token" => mint.()}, connect_info: other)
    end

    test "a chain from a TRUSTED peer IS honoured — the header is not merely ignored", %{
      mint: mint
    } do
      # Loopback is trusted (Caddy runs on the box and dials localhost), so the
      # forwarded hop is the real client and two different hops are two
      # different buckets. Without this direction, "ignore x-forwarded-for
      # always" would pass the test above and collapse the whole anonymous
      # internet into one bucket behind our own front.
      front = fn xff ->
        %{peer_data: %{address: {127, 0, 0, 1}}, x_headers: [{"x-forwarded-for", xff}]}
      end

      assert {:ok, _} =
               connect(UserSocket, %{"token" => mint.()}, connect_info: front.("9.9.9.9"))

      assert {:ok, _} =
               connect(UserSocket, %{"token" => mint.()}, connect_info: front.("9.9.9.9"))

      assert :error = connect(UserSocket, %{"token" => mint.()}, connect_info: front.("9.9.9.9"))

      # A different client behind the same front is a different bucket.
      assert {:ok, _} =
               connect(UserSocket, %{"token" => mint.()}, connect_info: front.("7.7.7.7"))
    end
  end

  # ---------------------------------------------------------------------------

  describe "revocation and seat-removal teardown" do
    setup %{ws: ws, proj: proj} do
      raw = "test-tok-revoke-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "revoke-ch", "test", ["read"], ws.id)
      plain_socket = socket(UserSocket, "revoke-id", %{api_token: token})

      {:ok, _reply, joined} =
        Phoenix.ChannelTest.join(
          plain_socket,
          BarkparkWeb.SearchChannel,
          "search:#{ws.slug}:#{proj.slug}:test"
        )

      # `Phoenix.ChannelTest.join/3` LINKS the channel to the test process. Every
      # test in this block deliberately kills that channel with a non-normal
      # reason ({:shutdown, :credential_revoked} / {:shutdown, :unauthorized}),
      # and a linked exit would take the test down with it — the teardown
      # working is what would fail the test. Unlink so the exit is observed
      # through the monitor instead of suffered through the link.
      Process.unlink(joined.channel_pid)

      %{token: token, raw: raw, plain_socket: plain_socket, joined: joined}
    end

    test "UserSocket.id/1 is a real token-derived handle, not nil", %{
      token: token,
      plain_socket: plain_socket
    } do
      # A nil id is the ABSENCE of a disconnect handle: Phoenix subscribes the
      # transport to the string this returns, so with nil there is no topic to
      # broadcast to and revocation has nothing to grab.
      assert UserSocket.id(plain_socket) == "user_socket:api_token:" <> token.id

      # The row id, never the raw bearer or its hash — a topic is not a place
      # to put a credential.
      refute UserSocket.id(plain_socket) =~ token.token_hash

      # No verified token on the socket: nothing to target, and nothing that
      # could be serving reads either.
      assert UserSocket.id(socket(UserSocket, "no-token", %{})) == nil
    end

    test "revoking the token broadcasts a disconnect on exactly that topic", %{token: token} do
      topic = "user_socket:api_token:" <> token.id
      Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)

      {:ok, _revoked} = Auth.revoke_token(token)

      # The two halves only meet if the broadcast lands on the SAME string
      # `id/1` returns — which is what this pins.
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"},
                     @reply_timeout
    end

    test "after revocation the channel is torn down and a query frame is not answered", %{
      token: token,
      joined: joined
    } do
      mon = Process.monitor(joined.channel_pid)

      {:ok, _revoked} = Auth.revoke_token(token)

      # Teardown is CAUSED by the revoke — the client is asked for nothing.
      assert_receive {:DOWN, ^mon, :process, _pid, {:shutdown, :credential_revoked}},
                     @reply_timeout

      refute Process.alive?(joined.channel_pid)

      # And the frame that used to be answered normally now gets nothing.
      ref = push(joined, "query", %{"q" => "revokeprobe", "seq" => 1, "engine" => "postgres"})
      refute_receive %Phoenix.Socket.Reply{ref: ^ref}, 300
    end

    test "after revocation a document mutation delivers NO live results push", %{
      ws: ws,
      proj: proj,
      token: token,
      joined: joined
    } do
      # Prime the cached query so the channel is armed for live pushes. This is
      # the leg the query-frame test cannot see: it needs no client frame at
      # all, so a holder who simply stops typing still gets a live feed of
      # every mutation in the workspace.
      ref =
        push(joined, "query", %{
          "q" => "revokeprobe",
          "seq" => 9,
          "engine" => "postgres",
          "types" => "post"
        })

      assert_reply ref, :ok, _initial, @reply_timeout

      mon = Process.monitor(joined.channel_pid)
      {:ok, _revoked} = Auth.revoke_token(token)
      assert_receive {:DOWN, ^mon, :process, _pid, _reason}, @reply_timeout

      {:ok, _doc} =
        create_document_in!(
          ws,
          proj,
          "post",
          %{"doc_id" => "revoked-push-doc", "title" => "revokeprobe after the revoke"},
          "test"
        )

      refute_push "results", _payload, 500
    end

    test "removing the workspace seat refuses the next query frame and stops the channel", %{
      ws: ws,
      token: token,
      joined: joined
    } do
      # Authorized before the seat is removed — this frame proves the test is
      # measuring the removal and not a channel that was already broken.
      ref = push(joined, "query", %{"q" => "seatprobe", "seq" => 1, "engine" => "postgres"})
      assert_reply ref, :ok, _before, @reply_timeout

      # A roster operation, NOT a revoke: the token keeps existing and simply
      # loses its membership. `authorize/3` read that row at join and never
      # again.
      {:ok, _removed} =
        Barkpark.Tenancy.Members.remove_member(ws.id, %{type: :api_token, id: token.id})

      mon = Process.monitor(joined.channel_pid)

      ref2 = push(joined, "query", %{"q" => "seatprobe", "seq" => 2, "engine" => "postgres"})
      assert_reply ref2, :error, err, @reply_timeout
      assert err.reason == "unauthorized"
      assert err.seq == 2

      # Refused AND ended — a caller who lost access cannot just push again.
      assert_receive {:DOWN, ^mon, :process, _pid, {:shutdown, :unauthorized}}, @reply_timeout
    end

    test "removing the workspace seat also closes the live push leg", %{
      ws: ws,
      proj: proj,
      token: token,
      joined: joined
    } do
      ref =
        push(joined, "query", %{
          "q" => "seatprobe",
          "seq" => 3,
          "engine" => "postgres",
          "types" => "post"
        })

      assert_reply ref, :ok, _initial, @reply_timeout

      {:ok, _removed} =
        Barkpark.Tenancy.Members.remove_member(ws.id, %{type: :api_token, id: token.id})

      {:ok, _doc} =
        create_document_in!(
          ws,
          proj,
          "post",
          %{"doc_id" => "seat-removed-push-doc", "title" => "seatprobe after removal"},
          "test"
        )

      refute_push "results", _payload, 500
    end
  end
end
