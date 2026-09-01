defmodule BarkparkWeb.Integration.PublicReadEnforcementTest do
  @moduledoc """
  ROUTED enforcement of the `public-read` clamp (site-spawner charter D6).

  Unlike `BarkparkWeb.Plugs.PublicReadTest` — which calls `PublicRead.call/2`
  on a hand-built `%Plug.Conn{}` and therefore only proves the plug does the
  right thing IF it runs — this suite drives REAL requests through the router
  so it proves the plug is actually MOUNTED on the read pipelines and clamps a
  token minted `["public-read"]`.

  Three pipelines, one clamp:

    * SCOPED `/w/:ws/p/:project/v1/data/query|doc/...` (`:shared_docs_api`) —
      the route the site-spawner BUILD token fetches over. Workspace membership
      (ResolveWorkspace) is NECESSARY but not SUFFICIENT: it does not pin
      published-vs-draft, so a member public-read token could read drafts.
      PublicRead is the missing clamp.
    * FLAT `/v1/data/query|doc/...` (`:api_grant_read`).
    * `:require_token` — the bearer-gated surface behind BOTH
      `[:api, :require_token]` and `[:scoped_api, :require_token]`. The clamp
      was absent here, which is where the live leak lived (see the
      `bearer-gated` describe below: export/analytics/history/revision served
      200s and `listen` held an open SSE stream).

  ## Fail-before (the leak this closes)

  `BarkparkWeb.Plugs.PublicRead` was written + unit-tested but mounted NOWHERE
  when the read-route cases below were written (`grep PublicRead router.ex` = 0
  hits then; the `:require_token` mount came later, with the bearer-gated cases).
  Live-proven on guerrilla: a `public-read` token read `?perspective=drafts` and
  private-schema
  content byte-identical to an admin token, because `QueryController.authed?/1`
  is merely "a token is present" and the anonymous perspective guard EXEMPTS any
  token. With the mount removed, the `perspective=drafts` assertions below flip
  from 403 to 200 (drafts leak) and the private-schema assertions flip from
  404/403 to 200 — i.e. this suite fails closed only because the plug is mounted.
  Verified by temporarily deleting both `plug(...PublicRead)` lines: the
  drafts + private-schema cases returned 200 (leak reproduced), restoring them
  returns the suite to green.

  ## Mutation transcript — 2026-08-17 (the `:require_token` mount, re-proven)

  Deleting the single `plug(BarkparkWeb.Plugs.PublicRead)` line from
  `pipeline :require_token` (router.ex:488) and running only this file:

      23 tests, 11 failures

  All eleven are the bearer-gated clamp, ten of them the flat+scoped pairs
  (`export`, `analytics`, `history`, `revision`, `listen`) plus the mixed
  `["public-read","read"]` case; the leaked bodies are in the failure output
  (`history` SCOPED returned 200 with a DRAFT-status revision title). The two
  `listen` arms fail through the yield-or-flunk path — "held the connection open
  for 5s" — flat and, as of this commit, SCOPED
  (`/w/clamp-ws/p/clamp-proj/v1/data/listen/production`). Restoring the line:

      23 tests, 0 failures

  So the whole bearer-gated describe fails closed only because that one line is
  mounted, and the scoped `listen` route is no longer the one leak route
  certified on its flat arm alone.

  ## Live re-proof — guerrilla, 2026-08-17

  A fresh `["public-read"]` token minted through the spawner's own route
  (`POST /w/default/p/default/v1/tokens`, HTTP 201, id 9e1eb0fc) was refused on
  all FIVE routes over BOTH shapes — ten requests, ten
  `403 {"error":{"code":"forbidden","message":"public-read tokens may only read
  published public documents"}}`: export, analytics, history, revision, and
  `listen` — which answered `HTTP/2 403` with
  `content-type: application/json`, i.e. no `text/event-stream` upgrade and no
  held socket, flat AND scoped.

  Teardown, and the two traps in it: self-revoke
  (`DELETE /v1/auth/app-tokens/current`) is itself 403'd by the very clamp under
  certification, so the token was killed with the ADMIN bearer
  (`DELETE /v1/auth/app-tokens` body `{"token": …}` -> 200 `revoked_at`
  2026-08-17T07:31:06Z). Death was then verified on a BEARER-GATED route —
  `GET /v1/data/export/production` -> 401 `unauthorized`. The same dead token
  still returns 200 on `GET /v1/data/query/production/paper`, because that route
  is anonymously readable: a dead-check there reports FALSE-ALIVE.

  read/write/admin tokens are NOT clamped — PublicRead acts ONLY on a token
  whose permissions CARRY `"public-read"` (membership, mirroring
  `AnonPerspective.anon_pinned?/1` — list EQUALITY was the bypass a
  `["public-read", "read"]` token walked through, and there is a test below that
  used to prove that bypass and now proves it closed). Every other principal
  (and anonymous) passes through untouched: the `admin token is unaffected` and
  `a read token still gets 200 on export` cases prove that.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.{AnonPerspective, LegacyController}

  import Barkpark.TenancyFixtures

  @dataset "production"

  # ── SCOPED route (the site-spawner BUILD fetch path) ──────────────────────
  describe "scoped route /w/:ws/p/:project — public-read token is clamped" do
    setup do
      ws = create_workspace!("spawn-ws")
      project = create_project!(ws, "spawn-proj")
      scope = [workspace_id: ws.id, project_id: project.id]

      # A PUBLIC type and a PRIVATE type in THIS workspace.
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          @dataset,
          scope
        )

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "secret", "title" => "Secret", "visibility" => "private", "fields" => []},
          @dataset,
          scope
        )

      # A PUBLISHED post and a DRAFT-ONLY post: `drafts.d1` exists but the
      # published `d1` does not, so a drafts leak is observable.
      {:ok, _} =
        Content.create_document("post", %{"_id" => "p1", "title" => "Live"}, @dataset, scope)

      {:ok, _} = Content.publish_document("p1", "post", @dataset, scope)

      {:ok, _} =
        Content.create_document("post", %{"_id" => "d1", "title" => "Draft"}, @dataset, scope)

      raw = "site-build-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "site-spawner build", @dataset, ["public-read"], ws.id)

      %{ws: ws, project: project, token: raw}
    end

    defp scoped(ws, project, suffix),
      do: "/w/#{ws.slug}/p/#{project.slug}/v1/data/#{suffix}"

    defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

    test "reads published + public content (200) — the happy path stays open", %{
      conn: conn,
      ws: ws,
      project: project,
      token: token
    } do
      body =
        conn
        |> authed(token)
        |> get(scoped(ws, project, "query/#{@dataset}/post"))
        |> json_response(200)

      ids = body["result"]["documents"] |> Enum.map(& &1["_id"])
      assert "p1" in ids
      # published-only: the draft never appears even without asking for it.
      refute "d1" in ids
    end

    test "reads a published doc by id (200)", %{
      conn: conn,
      ws: ws,
      project: project,
      token: token
    } do
      body =
        conn
        |> authed(token)
        |> get(scoped(ws, project, "doc/#{@dataset}/post/p1"))
        |> json_response(200)

      assert body["result"]["_id"] == "p1"
    end

    test "?perspective=drafts is DENIED (403 perspective not allowed)", %{
      conn: conn,
      ws: ws,
      project: project,
      token: token
    } do
      body =
        conn
        |> authed(token)
        |> get(scoped(ws, project, "query/#{@dataset}/post?perspective=drafts"))
        |> json_response(403)

      assert body["error"]["code"] == "forbidden"
      assert body["error"]["message"] == "perspective not allowed"
    end

    test "?perspective=raw is DENIED (403)", %{conn: conn, ws: ws, project: project, token: token} do
      conn
      |> authed(token)
      |> get(scoped(ws, project, "query/#{@dataset}/post?perspective=raw"))
      |> json_response(403)
    end

    test "a private-schema type is DENIED (404 not found)", %{
      conn: conn,
      ws: ws,
      project: project,
      token: token
    } do
      body =
        conn
        |> authed(token)
        |> get(scoped(ws, project, "query/#{@dataset}/secret"))
        |> json_response(404)

      assert body["error"]["code"] == "not_found"
    end

    test "a private-schema doc-by-id is DENIED (404)", %{
      conn: conn,
      ws: ws,
      project: project,
      token: token
    } do
      conn
      |> authed(token)
      |> get(scoped(ws, project, "doc/#{@dataset}/secret/x1"))
      |> json_response(404)
    end

    test "an admin token is NOT clamped — drafts + private read through", %{
      conn: conn,
      ws: ws,
      project: project
    } do
      raw = "admin-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "admin", @dataset, ["read", "write", "admin"], ws.id)

      # drafts perspective is allowed for a non-public-read token (no 403 clamp).
      conn
      |> authed(raw)
      |> get(scoped(ws, project, "query/#{@dataset}/post?perspective=drafts"))
      |> json_response(200)
    end
  end

  # ── FLAT route (:api_grant_read) — proves the second mount point ───────────
  describe "flat route /v1/data — public-read token is clamped" do
    setup do
      {ws, project} = ensure_default_scope!()
      scope = [workspace_id: ws.id, project_id: project.id]

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "fpost", "title" => "FPost", "visibility" => "public", "fields" => []},
          @dataset,
          scope
        )

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "fsecret", "title" => "FSecret", "visibility" => "private", "fields" => []},
          @dataset,
          scope
        )

      {:ok, _} =
        Content.create_document("fpost", %{"_id" => "fp1", "title" => "Live"}, @dataset, scope)

      {:ok, _} = Content.publish_document("fp1", "fpost", @dataset, scope)

      raw = "flat-build-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "flat public-read", @dataset, ["public-read"], ws.id)

      %{token: raw}
    end

    test "reads published + public content (200)", %{conn: conn, token: token} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/v1/data/query/#{@dataset}/fpost")
        |> json_response(200)

      ids = body["result"]["documents"] |> Enum.map(& &1["_id"])
      assert "fp1" in ids
    end

    test "?perspective=drafts is DENIED (403)", %{conn: conn, token: token} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/v1/data/query/#{@dataset}/fpost?perspective=drafts")
        |> json_response(403)

      assert body["error"]["code"] == "forbidden"
      assert body["error"]["message"] == "perspective not allowed"
    end

    test "a private-schema type is DENIED (404)", %{conn: conn, token: token} do
      body =
        conn
        |> put_req_header("authorization", "Bearer " <> token)
        |> get("/v1/data/query/#{@dataset}/fsecret")
        |> json_response(404)

      assert body["error"]["code"] == "not_found"
    end
  end

  # ── The BEARER-GATED surface (`:require_token`) — the leak D83 never named ──
  #
  # Five routes, not four. Each rode `[:api, :require_token]` (flat) and
  # `[:scoped_api, :require_token]` (scoped) where PublicRead was NOT mounted, so
  # a freshly minted public-read token got:
  #
  #   export     200, 52,208,330 bytes / 2,500 documents / 129 drafts
  #   analytics  200
  #   history    200, including draft-status revision titles
  #   revision   reached HistoryController (404 for a missing id — a 404 from the
  #              CONTROLLER is proof the pipeline let the token through)
  #   listen     200 text/event-stream, and HELD THE CONNECTION OPEN — an
  #              unbounded-connection primitive, not only disclosure
  #
  # Every assertion below FAILS on origin/main without the `plug(PublicRead)`
  # line in `pipeline :require_token`; that failure IS the proof of the mount.
  describe "bearer-gated /v1/data routes — a public-read token is denied" do
    setup do
      ws = create_workspace!("clamp-ws")
      project = create_project!(ws, "clamp-proj")
      scope = [workspace_id: ws.id, project_id: project.id]

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          @dataset,
          scope
        )

      {:ok, _} =
        Content.create_document("post", %{"_id" => "p1", "title" => "Live"}, @dataset, scope)

      {:ok, _} = Content.publish_document("p1", "post", @dataset, scope)

      %{
        ws: ws,
        project: project,
        # The site-spawner BUILD credential.
        public_read: mint!(ws, ["public-read"], "clamp public-read"),
        # What TokenController's PUBLIC mint route actually hands out when the
        # caller asks for both allowlisted permissions — the literal-list bypass.
        mixed: mint!(ws, ["public-read", "read"], "clamp public-read+read"),
        read: mint!(ws, ["read"], "clamp read"),
        # The tier ABOVE `read`. Needed since task-a85afbbc0c4b1be3 mounted
        # `Plugs.RequireWriteForMutation` in `:require_token`: a `read` token is
        # now refused on the POST reindex arm by the WRITE gate, so proving the
        # clamp is TIER-scoped (rather than route breakage) needs a principal
        # that meets neither gate.
        write: mint!(ws, ["read", "write"], "clamp write")
      }
    end

    # {label, flat suffix} — the scoped mirror is the same suffix under /w/../p/..
    @leak_routes [
      {"export", "export/production"},
      {"analytics", "analytics/production"},
      {"history", "history/production/post/p1"},
      {"revision", "revision/production/00000000-0000-4000-8000-000000000000"}
    ]

    for {label, suffix} <- @leak_routes do
      test "#{label}: FLAT is 403 forbidden for a public-read token", %{
        conn: conn,
        public_read: token
      } do
        body =
          conn
          |> authed(token)
          |> get("/v1/data/" <> unquote(suffix))
          |> json_response(403)

        assert body["error"]["code"] == "forbidden"
      end

      test "#{label}: SCOPED is 403 forbidden for a public-read token", %{
        conn: conn,
        ws: ws,
        project: project,
        public_read: token
      } do
        body =
          conn
          |> authed(token)
          |> get(scoped(ws, project, unquote(suffix)))
          |> json_response(403)

        assert body["error"]["code"] == "forbidden"
      end
    end

    # MOVED from PublicReadTest, where it called the plug DIRECTLY on a
    # hand-built conn for a route the router never sent through it — a green
    # certifying a live 200. Through the real endpoint it must halt AT THE
    # PIPELINE: unclamped, `listen` upgrades to SSE and holds the socket, so the
    # yield below expires and this test flunks (that is the fail-before).
    test "listen: halts at the pipeline and never opens an SSE stream", %{
      conn: conn,
      public_read: token
    } do
      task = Task.async(fn -> conn |> authed(token) |> get("/v1/data/listen/#{@dataset}") end)

      case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, response} ->
          assert json_response(response, 403)["error"]["code"] == "forbidden"
          refute response.resp_body =~ "event:"

        nil ->
          flunk("""
          /v1/data/listen held the connection open for 5s with a public-read token.
          The clamp is not mounted on :require_token — this is the unbounded-stream leak.
          """)
      end
    end

    # The SCOPED mirror of the case above — `listen` was the ONE leak route with a
    # flat arm only, so the scoped clamp on
    # `/w/:ws/p/:proj/v1/data/listen/:dataset` ([:scoped_api, :require_token],
    # router.ex:2336) was uncertified while export/analytics/history/revision each
    # carried both arms. It is the same unbounded-stream primitive on the route a
    # spawned site's BUILD token actually addresses, so it gets the same
    # yield-or-flunk shape rather than a bare `json_response/2` (an unclamped SSE
    # upgrade never returns and would HANG the suite instead of failing it).
    test "listen: SCOPED halts at the pipeline and never opens an SSE stream", %{
      conn: conn,
      ws: ws,
      project: project,
      public_read: token
    } do
      url = scoped(ws, project, "listen/#{@dataset}")
      task = Task.async(fn -> conn |> authed(token) |> get(url) end)

      case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, response} ->
          assert json_response(response, 403)["error"]["code"] == "forbidden"
          refute response.resp_body =~ "event:"

        nil ->
          flunk("""
          #{url} held the connection open for 5s with a public-read token.
          The clamp is not mounted on :require_token — this is the unbounded-stream
          leak, reached over the SCOPED route a spawned site's BUILD token uses.
          """)
      end
    end

    # The schemas twin of the same vacuous unit assertion, likewise moved to the
    # real endpoint. HONEST NOTE: `/v1/schemas/:dataset` rides `:require_admin`,
    # not `:require_token`, so RequireAdmin already denied it — this case is 403
    # BEFORE and after. It is kept because the plug-level green was proving
    # nothing about the route; this one proves the route.
    test "schemas: 403 forbidden for a public-read token (via RequireAdmin)", %{
      conn: conn,
      public_read: token
    } do
      body =
        conn
        |> authed(token)
        |> get("/v1/schemas/#{@dataset}")
        |> json_response(403)

      assert body["error"]["code"] == "forbidden"
    end

    # THE LITERAL-LIST BYPASS, INVERTED. With the clamp mounted but the gate
    # still `permissions == ["public-read"]`, this returned 200 and the whole
    # dataset with it — the clamp would have shipped as a false claim, because
    # TokenController's public mint route hands out exactly this token. The gate
    # is now MEMBERSHIP (`"public-read" in perms`, copied from
    # AnonPerspective.anon_pinned?/1), so it is 403.
    test "a public-read + read token does NOT bypass the clamp (membership, not equality)", %{
      conn: conn,
      ws: ws,
      project: project,
      mixed: token
    } do
      assert conn |> authed(token) |> get("/v1/data/export/#{@dataset}") |> json_response(403)

      assert conn
             |> authed(token)
             |> get(scoped(ws, project, "export/#{@dataset}"))
             |> json_response(403)
    end

    # NON-REGRESSION: the clamp no-ops for every other principal, so the
    # bearer-gated surface is byte-identical for a plain read token.
    test "a read token still gets 200 on export, flat and scoped", %{
      conn: conn,
      ws: ws,
      project: project,
      read: token
    } do
      # Export streams chunked NDJSON, so assert the STATUS and the content-type
      # the ExportController negotiated: reaching either means the request got
      # past `pipeline :require_token` instead of being halted at 403. (The body
      # is not asserted — ConnTest does not accumulate this controller's chunks.)
      flat = conn |> authed(token) |> get("/v1/data/export/#{@dataset}")
      assert flat.status == 200
      assert get_resp_header(flat, "content-type") == ["application/x-ndjson; charset=utf-8"]

      scoped_resp = conn |> authed(token) |> get(scoped(ws, project, "export/#{@dataset}"))
      assert scoped_resp.status == 200
    end

    # ── POST reindex — the route whose OWN comment named this token ─────────
    #
    # `POST /v1/data/search/:dataset/reindex` rides `[:api, :require_token]`
    # (the `/v1/data` private scope), so mounting PublicRead on that pipeline
    # denies it to the public tier. It is called out separately from
    # `@leak_routes` above for three reasons:
    #
    #   * It is the only POST on this pipeline the clamp governs. Every leak
    #     route above is a GET, so a regression that re-admitted only non-GET
    #     methods would leave all ten of those cases green.
    #   * `allowed_route?/1` matches `%{method: "GET", path_info: path}`, so the
    #     denial here comes from the `defp allowed_route?(_), do: false` FALLBACK
    #     clause. Nothing else in this file exercises that clause, and it is the
    #     clause that makes the clamp deny-by-default across METHODS rather than
    #     only across paths.
    #   * Until this commit the route's router comment named "the public-read
    #     token the web demo holds" as an INTENDED caller — a claim the clamp
    #     falsified on 2026-07-30 and which then stood, uncorrected and
    #     untested, for three weeks. The comment is fixed alongside this test.
    #     The test is what stops the next reader from resolving the
    #     contradiction the other way: by adding a route-level allowance to
    #     make the stale comment true again, which would punch a POST-shaped
    #     hole through a clamp governing 44 routes.
    #
    # There is no scoped mirror to certify: `/v1/data/search/:dataset/reindex`
    # is declared only in the flat scope, so the FLAT arm is the whole surface.
    test "reindex: POST is 403 forbidden for a public-read token (the non-GET arm)", %{
      conn: conn,
      public_read: token
    } do
      body =
        conn
        |> authed(token)
        |> post("/v1/data/search/#{@dataset}/reindex")
        |> json_response(403)

      assert body["error"]["code"] == "forbidden"

      assert body["error"]["message"] ==
               "public-read tokens may only read published public documents"
    end

    # The twin that makes the case above mean something. Without it, deleting
    # the route entirely (404) or breaking it for everyone would still read as
    # "public-read is denied". The clamp must be TIER-scoped.
    #
    # RE-ANCHORED (task-a85afbbc0c4b1be3). This used to use the `read` token and
    # assert `refute resp.status == 403`. That stopped being the right probe
    # when `Plugs.RequireWriteForMutation` mounted in `:require_token`: a `read`
    # token is now refused on this POST by the WRITE gate — correctly, since
    # reindex enqueues a full-corpus rebuild. The tier-scoping claim is
    # unchanged, so the probe moves UP one tier to a principal that meets
    # neither gate.
    #
    # The downstream outcome is deliberately NOT asserted: `reindex` enqueues an
    # Indx rebuild, so a 200-with-jobId and a canonical `internal_error` are both
    # legitimate depending on whether the worker is reachable in this env. What
    # is never legitimate is a write token meeting the clamp.
    test "reindex: a write token is NOT clamped — the 403 is tier-scoped, not route breakage",
         %{conn: conn, write: token} do
      resp = conn |> authed(token) |> post("/v1/data/search/#{@dataset}/reindex")

      refute resp.status == 403
      refute resp.resp_body =~ "public-read tokens may only read"
    end

    # And the `read` tier's refusal is the WRITE gate's, never PublicRead's —
    # the two denials must stay distinguishable or a regression in either one
    # hides behind the other's message.
    test "reindex: a read token is refused by the write gate, NOT by the public-read clamp", %{
      conn: conn,
      read: token
    } do
      body =
        conn
        |> authed(token)
        |> post("/v1/data/search/#{@dataset}/reindex")
        |> json_response(403)

      assert body["error"]["code"] == "forbidden"

      refute body["error"]["message"] ==
               "public-read tokens may only read published public documents",
             "a `read` token met the PUBLIC-READ clamp — the clamp has stopped being tier-scoped"
    end
  end

  # ── Legacy /api/documents — the drafts-by-id clamp ────────────────────────
  #
  # `LegacyController.show/2` passed the RAW `:id` to `Content.get_document`
  # with no drafts clamp, while `QueryController.show/2` has always rejected a
  # `drafts.` id for an `anon_pinned?` caller (query_controller.ex:371). This
  # block certifies the ported clamp — and it takes TWO tests on purpose,
  # because either one alone is a false green:
  #
  #   * The ROUTED test below is a TRIPWIRE, not a proof of the clamp. The only
  #     `anon_pinned?` principal that can reach this route is a public-read
  #     token (a tokenless caller is 401'd by RequireToken), and `pipeline
  #     :require_token` mounts PublicRead, which 403s it two plugs UPSTREAM of
  #     the controller. So the 403 would hold with the clamp deleted. What it
  #     does prove is that the upstream denial is real: it reds if PublicRead's
  #     allowlist ever admits the legacy route, which is exactly the day the
  #     clamp stops being latent.
  #   * The ACTION-LEVEL test is the real proof. It calls the action directly
  #     with a REAL minted `["public-read"]` token in `:api_token` — resolved
  #     through `Auth.verify_token/1`, the same path RequireToken uses, since
  #     `CallerContext.from_conn/1` degrades to `anonymous()` for anything
  #     without both `:id` and list `:permissions`.
  #
  # ## Mutation transcript — 2026-08-17 (this file + legacy_crud_test.exs)
  #
  #   * clamp branch DELETED from `LegacyController.show/2` → 36 tests, 1
  #     failure: the action-level case, `left:` a 200 conn whose `resp_body` is
  #     `{"id":"drafts.lc-clamp-1","status":"draft","title":"Unpublished"}` —
  #     the drafts read, served. The ROUTED tripwire stayed GREEN, which is the
  #     measurement that proves it certifies the upstream 403 and not the clamp.
  #   * clamp WIDENED to a blanket `String.starts_with?(doc_id, "drafts.")`
  #     (the `anon_pinned?` scope dropped) → 36 tests, 2 failures: the
  #     `anon_pinned?-scoped` case here AND legacy_crud_test's "returns the
  #     legacy doc shape + headers for an existing draft" (an admin/read/write
  #     token's 200 on `drafts.lc-show-1`). Over-clamping is caught too.
  #   * clamp as shipped → 0 failures.
  describe "legacy /api/documents/:type/:id — drafts by id is clamped" do
    setup do
      ws = create_workspace!("legacy-clamp-ws")

      # Default (unscoped) production scope — what `LegacyController` reads
      # through, since `scope_opts/1` derives tenancy from the conn's assigns,
      # not from the token's workspace binding.
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          @dataset
        )

      # Draft-only: `drafts.lc-clamp-1` exists, the published `lc-clamp-1` does
      # not, so a leak is observable as a 200 body rather than a coincidental 404.
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => "lc-clamp-1", "title" => "Unpublished"},
          @dataset
        )

      raw = mint!(ws, ["public-read"], "legacy clamp public-read")
      {:ok, token} = Auth.verify_token(raw)

      %{ws: ws, token: raw, token_struct: token}
    end

    test "ACTION-LEVEL: a public-read caller gets :not_found for a drafts. id", %{
      token_struct: token
    } do
      conn =
        build_conn()
        |> Plug.Conn.assign(:api_token, token)
        # BARE CONN — no router, so no `:api` pipeline and no AssignDefaultScope.
        # This test asserts the DRAFTS-PERSPECTIVE clamp (anon_pinned?-scoped),
        # not tenancy; the fixture doc is created unscoped and therefore lands in
        # the seeded Default. Stand in for what the pipeline would have assigned,
        # so the clamp is what the assertion measures. Without it the sentinel
        # (task-3e2a70930c6df723) fires on an unresolvable scope and the doc is
        # hidden by TENANCY — which would fail the read-token arm and, worse,
        # pass the public-read arm for the wrong reason.
        |> Plug.Conn.assign(:current_workspace, Barkpark.Tenancy.get_default_workspace())

      # Sanity: this principal really is the pinned class the clamp keys on —
      # otherwise the assertion below could pass for the wrong reason.
      assert AnonPerspective.anon_pinned?(conn)

      assert LegacyController.show(conn, %{
               "type" => "post",
               "id" => "drafts.lc-clamp-1"
             }) == {:error, :not_found}
    end

    test "ACTION-LEVEL: the clamp is anon_pinned?-scoped — a read token still gets the draft",
         %{ws: ws} do
      raw = mint!(ws, ["read"], "legacy clamp read")
      {:ok, token} = Auth.verify_token(raw)

      conn =
        build_conn()
        |> Plug.Conn.assign(:api_token, token)
        # BARE CONN — no router, so no `:api` pipeline and no AssignDefaultScope.
        # This test asserts the DRAFTS-PERSPECTIVE clamp (anon_pinned?-scoped),
        # not tenancy; the fixture doc is created unscoped and therefore lands in
        # the seeded Default. Stand in for what the pipeline would have assigned,
        # so the clamp is what the assertion measures. Without it the sentinel
        # (task-3e2a70930c6df723) fires on an unresolvable scope and the doc is
        # hidden by TENANCY — which would fail the read-token arm and, worse,
        # pass the public-read arm for the wrong reason.
        |> Plug.Conn.assign(:current_workspace, Barkpark.Tenancy.get_default_workspace())

      refute AnonPerspective.anon_pinned?(conn)

      served = LegacyController.show(conn, %{"type" => "post", "id" => "drafts.lc-clamp-1"})

      assert served.status == 200
      assert Jason.decode!(served.resp_body)["id"] == "drafts.lc-clamp-1"
    end

    test "ROUTED TRIPWIRE: the legacy route is not in PublicRead's allowlist (403)", %{
      conn: conn,
      token: raw
    } do
      body =
        conn
        |> authed(raw)
        |> get("/api/documents/post/drafts.lc-clamp-1")
        |> json_response(403)

      assert body["error"]["code"] == "forbidden"
    end
  end

  defp mint!(ws, permissions, label) do
    raw = "#{label}-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, label, @dataset, permissions, ws.id)
    raw
  end
end
