defmodule BarkparkWeb.Integration.ListenGrantNarrowingTest do
  @moduledoc """
  task-c9c962c3451fd831 — the SSE stream must honour the caller's grant ladder.

  `GET /w/:ws/p/:proj/v1/data/listen/:dataset` resolves every event through the
  grant-narrowed `Content.get_document/4`, but `redacted_result/4` returned
  `:drop` for exactly ONE denial shape: an `owner_scoped` row still present.
  A GRANT-narrowed miss (`{:error, :not_found}` while `opts[:grant_scoped]` is
  true — the row exists but sits outside the caller's grant ladder) fell through
  to `Envelope.redact(event.document, …)` and forwarded the FROZEN SNAPSHOT the
  event log holds: `documentId`, `_publishedId`, `_rev`, `_type`, `syncTags` AND
  the document's own fields. Both legs shipped it — replay (Last-Event-ID) and
  the live broadcast — because `forward_event?/2` filters on workspace only.

  ## The drive, and why it reaches the real HTTP boundary

  `listen/2` is a long-lived chunked stream, so a bare `get/2` never returns.
  Both drives below run the REAL route inside a `Task` and then post one
  `:sse_overloaded` to the connection process — the controller's own
  slow-consumer signal, which `listen_recv/5` answers with `shed/1` and a normal
  return, handing the test the accumulated chunk body. Nothing about the
  authorization path is stubbed: `:scoped_api` + `:require_token` run in full, so
  `ResolveWorkspace`'s grant arm is what sets `:grant_scoped_read` and
  `ScopeHelpers.scope_opts/1` is what folds it into `:grant_scoped`.

    * REPLAY leg — `?lastEventId=0`, so the whole workspace event log is replayed
      through `redacted_result/4` before the loop is ever entered.
    * LIVE leg — the connection process is handed the very `{:document_changed,
      msg}` the production write path broadcast (captured off
      `documents:ws:<ws>:<dataset>` in `setup`, not hand-rolled), then the
      overload signal. Same-sender message ordering makes the sequence
      deterministic; only PubSub *delivery* is bypassed, and delivery is not what
      is under test — the emit decision is.

  ## The drive's credential

  The one `analytics_grant_narrowing_test.exs` established and
  `export_revision_grant_narrowing_test.exs` (#15133) re-proved on THIS SAME
  router scope block: a non-member grantee presents her own api token (minted
  into her OWN workspace — satisfies `RequireToken`, confers nothing in the
  victim workspace) plus her login session cookie, so `ResolveWorkspace`'s grant
  arm's `not member? and not is_nil(user)` holds.

  REACHABILITY IS NOT ASSUMED: the first grantee test asserts the stream opens at
  all (200 + a `welcome` frame), so no `refute` below can pass vacuously on a
  401/403/404 or an empty body. The IN-GRANT arms are the over-reach guard, and
  the MEMBER arms are the colliding-fixture proof — the out-of-grant row really
  is streamable on this route, so the grantee refutes something that exists.

  MEMBER BYTE-IDENTITY: a member carries no `:grant_scoped` key, so the new arm
  is opts-gated out of her request entirely; her events resolve through
  `get_document/4`'s `{:ok, doc}` branch, which this change does not touch at
  all. The member arms assert that at the wire: her out-of-grant frames still
  carry `documentId`, `_type`, `_rev`, `syncTags` and the document's own fields.
  """

  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccessFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.Content.CallerContext
  alias Barkpark.{Accounts, Auth, Tenancy}
  alias BarkparkWeb.ListenController

  @ds "production"
  @password "correct-horse-battery"

  # The type the grant COVERS, and the type it does NOT. Same workspace, same
  # project, same dataset — the ONLY thing separating the second from the caller
  # is the grant's `type` rung, so nothing but grant narrowing can hide it.
  @in_grant_type "grantedMemo"
  @out_of_grant_type "ledgerSecret"

  setup %{conn: conn} do
    ensure_default_scope!()

    ws_b = create_workspace!("listen-victim-#{System.unique_integer([:positive])}")
    proj_b = create_project!(ws_b, "listen-vp-#{System.unique_integer([:positive])}")

    # Subscribe BEFORE the writes so the live-leg fixture is the genuine
    # production broadcast (`Content.Broadcast.tap_broadcast/7`), not a
    # hand-rolled map that could drift from the real msg shape.
    Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:ws:#{ws_b.id}:#{@ds}")

    {:ok, doc_in} =
      create_document_in!(ws_b, proj_b, @in_grant_type, %{"title" => "in-grant"}, @ds)

    {:ok, doc_out} =
      create_document_in!(ws_b, proj_b, @out_of_grant_type, %{"title" => "out-of-grant"}, @ds)

    msg_in = await_broadcast!(doc_in.doc_id)
    msg_out = await_broadcast!(doc_out.doc_id)

    # Alice: an ordinary signed-in user who is NOT a member of workspace B, with
    # her own workspace and a read token minted into it. Neither credential says
    # anything about B.
    email = "listen-grantee-#{System.unique_integer([:positive])}@example.com"
    {:ok, alice} = Accounts.register_user(%{email: email, password: @password})
    {:ok, alice_session} = Accounts.create_user_session_token(alice)

    ws_a = create_workspace!("listen-alice-#{System.unique_integer([:positive])}")
    {:ok, _} = Tenancy.Auth.create_membership(ws_a.id, alice.id, "admin", "user")
    alice_raw = "alice-listen-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(alice_raw, "alice-app", @ds, ["read"], ws_a.id)

    {:ok,
     conn: conn,
     ws_b: ws_b,
     proj_b: proj_b,
     doc_in: doc_in,
     doc_out: doc_out,
     msg_in: msg_in,
     msg_out: msg_out,
     alice: alice,
     alice_session: alice_session,
     alice_raw: alice_raw}
  end

  defp await_broadcast!(doc_id) do
    receive do
      {:document_changed, %{doc_id: ^doc_id} = msg} -> msg
    after
      2_000 -> flunk("no {:document_changed, …} broadcast for #{doc_id}")
    end
  end

  # ── Credentials ───────────────────────────────────────────────────────────

  defp listen_path(ws, proj),
    do: "/w/#{ws.slug}/p/#{proj.slug}/v1/data/listen/#{@ds}"

  defp alice_conn(conn, %{alice_session: session, alice_raw: raw}) do
    conn
    |> Plug.Test.init_test_session(%{"user_session" => session})
    |> put_req_header("authorization", "Bearer " <> raw)
  end

  defp member_conn(conn, ws) do
    raw = "listen-member-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "listen-member", @ds, ["read"], ws.id)
    put_req_header(conn, "authorization", "Bearer " <> raw)
  end

  # ── The two drives ────────────────────────────────────────────────────────

  # REPLAY leg: `?lastEventId=0` replays the workspace event log through
  # `redacted_result/4` before `listen_loop/5` is entered; the queued
  # `:sse_overloaded` then sheds the (idle) loop so the conn returns.
  defp replay_body(req_conn, path) do
    task = Task.async(fn -> get(req_conn, path, %{"lastEventId" => "0"}) end)
    send(task.pid, :sse_overloaded)
    conn = Task.await(task, 20_000)
    assert conn.status == 200
    conn.resp_body
  end

  # LIVE leg: no `lastEventId`, so nothing replays; the connection process is
  # handed the real broadcast msg and then the overload signal, in that order.
  defp live_body(req_conn, path, msg) do
    task = Task.async(fn -> get(req_conn, path) end)
    send(task.pid, {:document_changed, msg})
    send(task.pid, :sse_overloaded)
    conn = Task.await(task, 20_000)
    assert conn.status == 200
    conn.resp_body
  end

  # Every `data:` payload in the SSE body, decoded. The `welcome` and
  # `overloaded` frames decode too; mutation frames are the ones carrying
  # `documentId`.
  defp frames(body) do
    body
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn frame ->
      frame
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&(&1 |> String.replace_prefix("data: ", "") |> Jason.decode!()))
    end)
  end

  defp mutation_frames(body), do: Enum.filter(frames(body), &Map.has_key?(&1, "documentId"))

  defp frames_for(body, doc_id),
    do: Enum.filter(mutation_frames(body), &(&1["documentId"] == doc_id))

  defp types_seen(body),
    do: body |> mutation_frames() |> Enum.map(& &1["type"]) |> Enum.uniq() |> Enum.sort()

  describe "GRANTEE — a non-member holding a type-scoped read grant on B" do
    setup ctx do
      grant =
        bind_grant!(ctx.ws_b, ctx.alice, %{
          project_id: ctx.proj_b.id,
          dataset: @ds,
          type: @in_grant_type,
          capabilities: ["read"]
        })

      {:ok, grant: grant}
    end

    test "reaches the listen door at all — the reachability precondition", ctx do
      body = replay_body(alice_conn(ctx.conn, ctx), listen_path(ctx.ws_b, ctx.proj_b))

      assert body =~ "event: welcome",
             "PRECONDITION FAILED: the grant-derived caller did not reach " <>
               "ListenController over HTTP (body: #{inspect(body)}). Every " <>
               "assertion below would then be vacuous."
    end

    test "REPLAY leg: no frame for a document outside the grant ladder", ctx do
      body = replay_body(alice_conn(ctx.conn, ctx), listen_path(ctx.ws_b, ctx.proj_b))
      leaked = frames_for(body, ctx.doc_out.doc_id)

      assert leaked == [],
             "LEAK (replay): the SSE stream forwarded the frozen event-log " <>
               "envelope of a document outside the caller's grant ladder — " <>
               "#{inspect(leaked)} (types seen: #{inspect(types_seen(body))})"
    end

    test "REPLAY leg: the grant's OWN document still streams", ctx do
      body = replay_body(alice_conn(ctx.conn, ctx), listen_path(ctx.ws_b, ctx.proj_b))

      assert frames_for(body, ctx.doc_in.doc_id) != [],
             "OVER-REACH: the clamp blanked the grantee's OWN in-grant replay " <>
               "(types seen: #{inspect(types_seen(body))})"
    end

    test "LIVE leg: no frame for a document outside the grant ladder", ctx do
      body =
        live_body(alice_conn(ctx.conn, ctx), listen_path(ctx.ws_b, ctx.proj_b), ctx.msg_out)

      leaked = frames_for(body, ctx.doc_out.doc_id)

      assert leaked == [],
             "LEAK (live): the SSE stream forwarded the broadcast envelope of a " <>
               "document outside the caller's grant ladder — #{inspect(leaked)}"
    end

    test "LIVE leg: the grant's OWN document still streams", ctx do
      body =
        live_body(alice_conn(ctx.conn, ctx), listen_path(ctx.ws_b, ctx.proj_b), ctx.msg_in)

      assert frames_for(body, ctx.doc_in.doc_id) != [],
             "OVER-REACH: the clamp blanked the grantee's OWN in-grant live frame " <>
               "(frames seen: #{inspect(mutation_frames(body))})"
    end
  end

  describe "MEMBER — unchanged (grants only ADD access, so the arm is opts-gated out)" do
    test "REPLAY leg: every type in the workspace still streams, envelope intact", ctx do
      body = member_conn(ctx.conn, ctx.ws_b) |> replay_body(listen_path(ctx.ws_b, ctx.proj_b))

      assert @in_grant_type in types_seen(body)

      [frame | _] = frames_for(body, ctx.doc_out.doc_id)

      assert frame["type"] == @out_of_grant_type,
             "OVER-REACH: the clamp hid a member's own document from the replay"

      assert frame["documentId"] == ctx.doc_out.doc_id
      assert is_binary(frame["rev"])
      assert is_list(frame["syncTags"]) and length(frame["syncTags"]) == 2
      assert frame["result"]["title"] == "out-of-grant"
      assert frame["result"]["_type"] == @out_of_grant_type
      assert is_binary(frame["result"]["_rev"])
    end

    test "LIVE leg: the broadcast frame is emitted with the full envelope", ctx do
      body =
        member_conn(ctx.conn, ctx.ws_b)
        |> live_body(listen_path(ctx.ws_b, ctx.proj_b), ctx.msg_out)

      [frame | _] = frames_for(body, ctx.doc_out.doc_id)

      assert frame["type"] == @out_of_grant_type,
             "OVER-REACH: the clamp hid a member's own live frame"

      assert frame["result"]["title"] == "out-of-grant"
      assert frame["result"]["_type"] == @out_of_grant_type
    end
  end

  describe "the arm is opts-gated (the seam)" do
    test "a scope WITHOUT :grant_scoped keeps the redact-the-snapshot fallback", ctx do
      ev =
        ListenController.replay_since(@ds, 0, ctx.ws_b.id)
        |> Enum.find(&(&1.doc_id == ctx.doc_out.doc_id))

      assert ev, "expected a replayable mutation event for the out-of-grant doc"

      ctx_reader = %CallerContext{principal_type: :api_token, token_id: "tok-member"}

      # A doc_id that no longer resolves (a delete) with NO :grant_scoped key —
      # the member/back-compat shape. The delete leg must still redact+forward.
      gone = Map.put(ev, :doc_id, "drafts.listen-gone-#{System.unique_integer([:positive])}")

      result =
        ListenController.redacted_result(gone, @ds, ctx_reader, workspace_id: ctx.ws_b.id)

      refute result == :drop,
             "OVER-REACH: the grant arm fired for a caller carrying no " <>
               ":grant_scoped key — the delete leg must still forward a redacted " <>
               "snapshot for members and back-compat listeners"
    end

    test "the SAME miss with :grant_scoped true is dropped", ctx do
      ev =
        ListenController.replay_since(@ds, 0, ctx.ws_b.id)
        |> Enum.find(&(&1.doc_id == ctx.doc_out.doc_id))

      assert ev

      grantee_ctx = %CallerContext{principal_type: :user, user_id: ctx.alice.id}

      assert ListenController.redacted_result(ev, @ds, grantee_ctx,
               workspace_id: ctx.ws_b.id,
               caller_context: grantee_ctx,
               grant_scoped: true
             ) == :drop,
             "LEAK: a grant-narrowed miss still produced an emittable result"
    end
  end
end
