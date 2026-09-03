defmodule BarkparkWeb.BulldocsSessionsControllerTest do
  use BarkparkWeb.ConnCase, async: true
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @token "barkpark-test-ingest-token"
  @path "/v1/plugins/bulldocs/sessions"

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp body(slug, extra \\ %{}) do
    Map.merge(%{"slug" => slug, "title" => "S", "status" => "open"}, extra)
    |> Jason.encode!()
  end

  test "rejects with no token", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(@path, body("s-no-token"))

    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
  end

  test "upserts a metadata-only session", %{conn: conn} do
    resp = conn |> authed() |> post(@path, body("session-2026-07-25-a"))
    assert json_response(resp, 200)["ok"] == true
    assert Content.get_blocks_doc("session-2026-07-25-a", "session", "production")
  end

  test "upserts with blocks and reads back via GET", %{conn: conn} do
    blocks = [%{"id" => "b1", "type" => "paragraph", "content" => ["synth"]}]
    resp = conn |> authed() |> post(@path, body("session-2026-07-25-b", %{"blocks" => blocks}))
    assert json_response(resp, 200)["ok"] == true

    show = conn |> authed() |> get(@path <> "/session-2026-07-25-b")
    payload = json_response(show, 200)
    assert payload["slug"] == "session-2026-07-25-b"
    assert payload["status"] == "open"
    assert [%{"type" => "paragraph"} | _] = payload["blocks"]
  end

  test "GET unknown slug is 404", %{conn: conn} do
    resp = conn |> authed() |> get(@path <> "/session-nope")
    assert json_response(resp, 404)
  end

  test "applies a block op to a session", %{conn: conn} do
    conn
    |> authed()
    |> post(
      @path,
      body(
        "session-2026-07-25-c",
        %{
          "blocks" => [
            %{
              "id" => "b1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "v1"}]
            }
          ]
        }
      )
    )

    op = %{
      "op" => "replace-block",
      "id" => "b1",
      "block" => %{
        "id" => "b1",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "v2"}]
      }
    }

    resp = conn |> authed() |> post(@path <> "/session-2026-07-25-c/ops", Jason.encode!(op))
    assert json_response(resp, 200)["ok"] == true
  end

  # Final-review F5: the ops route writes the `drafts.<slug>` TWIN, not the
  # published row `GET /sessions/:slug` reads. The receipt used to echo only
  # the requested slug, which read as "the session was edited" — it was not.
  # Pin the honest signal: the id actually written, plus the note that says a
  # publish is still required.
  test "the ops receipt names the draft twin it actually wrote", %{conn: conn} do
    slug = "session-2026-07-25-receipt"

    conn
    |> authed()
    |> post(
      @path,
      body(slug, %{
        "blocks" => [
          %{
            "id" => "b1",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "v1"}]
          }
        ]
      })
    )

    op = %{
      "op" => "replace-block",
      "id" => "b1",
      "block" => %{
        "id" => "b1",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "v2"}]
      }
    }

    payload =
      conn
      |> authed()
      |> post(@path <> "/" <> slug <> "/ops", Jason.encode!(op))
      |> json_response(200)

    assert payload["ok"] == true
    assert payload["slug"] == slug
    assert payload["written_doc_id"] == "drafts." <> slug
    assert payload["note"] =~ "draft twin"

    # And the honesty is real, not cosmetic: the PUBLISHED row a reader
    # resolves still carries the pre-op block.
    show = conn |> authed() |> get(@path <> "/" <> slug) |> json_response(200)
    assert [%{"content" => [%{"value" => "v1"}]}] = show["blocks"]
  end

  # Final-review F1: `session.json` is `visibility: "private"` (a session
  # carries cwd/hostname/git state). The query API must therefore refuse
  # `type=session` to an ANONYMOUS caller, exactly like `form_response` — the
  # ingest-gated GET is the only reader. A token read still sees it.
  describe "visibility" do
    test "an anonymous query API read does NOT serve session docs", %{conn: conn} do
      slug = "session-private-check"
      assert conn |> authed() |> post(@path, body(slug)) |> json_response(200)

      anon =
        build_conn()
        |> get("/v1/data/query/production/session")

      # `PublicRead`/QueryController fail CLOSED on a private type: 404, and in
      # no case a body carrying the session.
      assert anon.status in [401, 403, 404]
      refute anon.resp_body =~ slug

      # Control: the SAME anonymous request against the PUBLIC sibling type
      # succeeds — so the refusal above is the private visibility, not a
      # broken route or a blanket anonymous block on this endpoint.
      assert build_conn() |> get("/v1/data/query/production/paper") |> json_response(200)
    end

    test "a token read of the same type still works", %{conn: conn} do
      slug = "session-private-token-read"
      assert conn |> authed() |> post(@path, body(slug)) |> json_response(200)
      assert conn |> authed() |> get(@path <> "/" <> slug) |> json_response(200)
    end

    test "the registered session schema is private" do
      session =
        Barkpark.Plugins.Bulldocs.register_schemas([])
        |> Enum.find(&(&1.name == "session"))

      assert session.visibility == "private"
    end
  end

  # Final-review F3: an upsert's pre-write read of the existing row and its
  # write now happen under `pg_advisory_xact_lock("session:" <> slug)` — the
  # SAME key `Content.Sessions.append_event/5` takes — so a checkpoint publish
  # can never clobber a concurrently-appended event. The Ecto sandbox gives one
  # connection per test, so a true race is untestable here (see the
  # Content.Sessions moduledoc); what IS testable, and what the bug actually
  # destroyed, is the carry-over: a blocks+fields publish must leave the trail
  # intact.
  test "a checkpoint-style publish preserves the event trail appended before it", %{conn: conn} do
    slug = "session-trail-preserved"
    assert conn |> authed() |> post(@path, body(slug)) |> json_response(200)

    for note <- ~w(one two) do
      resp =
        conn
        |> authed()
        |> post(
          @path <> "/" <> slug <> "/events",
          Jason.encode!(%{"kind" => "note", "note" => note})
        )

      assert json_response(resp, 200)["ok"] == true
    end

    # A full checkpoint publish: blocks + changed fields, NO "events" key
    # (the client never sends one — "events" is server-owned).
    checkpoint =
      body(slug, %{
        "status" => "closed",
        "ended_at" => "2026-07-25T12:00:00Z",
        "blocks" => [
          %{
            "id" => "current-task",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "wrapped up"}]
          }
        ]
      })

    assert (conn |> authed() |> post(@path, checkpoint) |> json_response(200))["ok"] == true

    payload = conn |> authed() |> get(@path <> "/" <> slug) |> json_response(200)
    assert payload["status"] == "closed"

    assert [%{"kind" => "note", "note" => "one"}, %{"kind" => "note", "note" => "two"}] =
             payload["events"]

    assert [%{"id" => "current-task"}] = payload["blocks"]

    # And a further append still lands on top of the republished row.
    resp =
      conn
      |> authed()
      |> post(
        @path <> "/" <> slug <> "/events",
        Jason.encode!(%{"kind" => "note", "note" => "three"})
      )

    assert json_response(resp, 200)["count"] == 3
  end

  # Review fix #4 (minor): the no-slug fallback must carry the same
  # `%{error: %{code:, message:}}` envelope every other branch uses, not the
  # ad hoc `%{ok: false, error: "..."}` shape.
  test "missing slug is a structured error envelope, not the ad hoc ok:false shape", %{
    conn: conn
  } do
    resp = conn |> authed() |> post(@path, Jason.encode!(%{"title" => "no slug here"}))
    payload = json_response(resp, 422)
    assert payload["error"]["code"] == "missing_slug"
    assert payload["error"]["message"]
    refute Map.has_key?(payload, "ok")
  end

  # Review fix #2: pins the CENTRAL deviation from the brief's controller
  # sketch — ingest_session/2 must NOT pre-seed attrs["blocks"] = [] before
  # calling Content.upsert_blocks_doc/3, or a metadata-only update (no
  # "blocks" key in the request body at all) would wipe the session's
  # previously-stored blocks to []. Re-adding Map.put_new("blocks", []) in
  # the controller passes every OTHER test in this file but fails this one.
  test "a metadata-only POST (no blocks key) preserves a prior session's blocks via the HTTP path",
       %{conn: conn} do
    slug = "session-2026-07-25-preserve"

    create =
      conn
      |> authed()
      |> post(
        @path,
        body(slug, %{
          "blocks" => [%{"id" => "b1", "type" => "paragraph", "content" => ["kept"]}]
        })
      )

    assert json_response(create, 200)["ok"] == true

    # A bare status-change POST — the request body carries no "blocks" key
    # whatsoever, not even an empty list.
    update =
      conn
      |> authed()
      |> post(@path, Jason.encode!(%{"slug" => slug, "status" => "closed"}))

    assert json_response(update, 200)["ok"] == true

    show = conn |> authed() |> get(@path <> "/" <> slug)
    payload = json_response(show, 200)

    assert payload["status"] == "closed"
    assert [%{"type" => "paragraph", "content" => ["kept"]} | _] = payload["blocks"]
  end

  # Review fix #1: show_session/2 and apply_session_op/2 previously called
  # Content.get_blocks_doc/apply_document_block_op with NO scope opts, so the
  # read ran unscoped (Content.Scope.scope_to_workspace_or_global/3 with a nil
  # workspace_id falls back to a GLOBAL read) even though ingest_session/2
  # threads workspace/project scope on WRITE and upsert_blocks_doc/3 keeps
  # same-slug rows distinct per workspace. Two workspaces writing the SAME
  # slug would then make an unscoped GET either return the wrong tenant's row
  # or raise Ecto.MultipleResultsError. Both GETs below pass their own
  # workspace_id and must resolve deterministically to their own session.
  describe "workspace-scoped reads (review fix #1)" do
    setup do
      {:ok, ws_a} = Tenancy.create_workspace(%{slug: "sess-scope-a", name: "sess-scope-a"})
      {:ok, ws_b} = Tenancy.create_workspace(%{slug: "sess-scope-b", name: "sess-scope-b"})
      %{ws_a: ws_a, ws_b: ws_b}
    end

    test "same slug in two workspaces stays isolated; GET is deterministic per workspace", %{
      conn: conn,
      ws_a: ws_a,
      ws_b: ws_b
    } do
      slug = "shared-slug-scoped"

      create_a =
        conn
        |> authed()
        |> post(@path, body(slug, %{"title" => "A's session", "workspace_id" => ws_a.id}))

      assert json_response(create_a, 200)["ok"] == true

      create_b =
        conn
        |> authed()
        |> post(@path, body(slug, %{"title" => "B's session", "workspace_id" => ws_b.id}))

      assert json_response(create_b, 200)["ok"] == true

      show_a =
        conn |> authed() |> get(@path <> "/" <> slug, %{"workspace_id" => ws_a.id})

      show_b =
        conn |> authed() |> get(@path <> "/" <> slug, %{"workspace_id" => ws_b.id})

      assert json_response(show_a, 200)["title"] == "A's session"
      assert json_response(show_b, 200)["title"] == "B's session"

      # Deterministic across repeats — no flaky Repo.one() collision.
      show_a_again =
        conn |> authed() |> get(@path <> "/" <> slug, %{"workspace_id" => ws_a.id})

      assert json_response(show_a_again, 200)["title"] == "A's session"
    end

    # Content.apply_document_block_op/5 (the generic non-paper write path,
    # block_ops.ex:907 moduledoc) always writes its patched content to the
    # `drafts.<slug>` twin, never the published row directly — so this reads
    # the draft back via Content.get_document/4 (scoped, mirroring the
    # controller's own opts) rather than through show_session (which reads
    # the plain published slug and would never see an applied op either way
    # — that draft/published split is pre-existing, out of this fix's scope).
    # The point under test is narrower: applying an op against slug S under
    # workspace A's scope must resolve + patch A's OWN row, not collide with
    # or leak into workspace B's same-slug row.
    test "apply_session_op resolves + patches the correct workspace's row, not the other one", %{
      conn: conn,
      ws_a: ws_a,
      ws_b: ws_b
    } do
      slug = "shared-slug-scoped-ops"

      block = fn text ->
        %{
          "id" => "b1",
          "type" => "paragraph",
          "content" => [%{"type" => "text", "value" => text}]
        }
      end

      for {ws, text} <- [{ws_a, "a-body"}, {ws_b, "b-body"}] do
        resp =
          conn
          |> authed()
          |> post(@path, body(slug, %{"blocks" => [block.(text)], "workspace_id" => ws.id}))

        assert json_response(resp, 200)["ok"] == true
      end

      op = %{
        "op" => "replace-block",
        "id" => "b1",
        "block" => block.("a-body-v2"),
        "workspace_id" => ws_a.id
      }

      op_resp = conn |> authed() |> post(@path <> "/" <> slug <> "/ops", Jason.encode!(op))
      assert json_response(op_resp, 200)["ok"] == true

      draft_a =
        Content.get_document("drafts." <> slug, "session", "production", workspace_id: ws_a.id)

      draft_b =
        Content.get_document("drafts." <> slug, "session", "production", workspace_id: ws_b.id)

      assert {:ok, %{content: %{"blocks" => [%{"content" => [%{"value" => "a-body-v2"}]}]}}} =
               draft_a

      # Workspace B's row was never touched by an op scoped to A: either no
      # draft exists for B at all, or (if one somehow did) it must not carry
      # A's patched value.
      case draft_b do
        {:ok, %{content: %{"blocks" => [%{"content" => [%{"value" => value}]}]}}} ->
          refute value == "a-body-v2"

        {:error, :not_found} ->
          :ok
      end
    end
  end

  # Session-handoff Task 4: the append-only, server-stamped event trail.
  describe "session events append (task-4)" do
    test "appends an event and returns the trail count", %{conn: conn} do
      slug = "session-events-happy-path"
      create = conn |> authed() |> post(@path, body(slug))
      assert json_response(create, 200)["ok"] == true

      resp =
        conn
        |> authed()
        |> post(
          @path <> "/" <> slug <> "/events",
          Jason.encode!(%{"kind" => "note", "note" => "hi"})
        )

      payload = json_response(resp, 200)
      assert payload["ok"] == true
      assert payload["slug"] == slug
      assert payload["count"] == 1

      resp2 =
        conn
        |> authed()
        |> post(
          @path <> "/" <> slug <> "/events",
          Jason.encode!(%{"kind" => "task-closed", "ref" => "task-abc"})
        )

      assert json_response(resp2, 200)["count"] == 2

      doc = Content.get_blocks_doc(slug, "session", "production")

      assert [
               %{"kind" => "note", "note" => "hi"},
               %{"kind" => "task-closed", "ref" => "task-abc"}
             ] =
               doc.content["events"]
    end

    # Review fix #2: the regression net against the drafts-path pitfall. The
    # happy-path test above reads back via Content.get_blocks_doc directly,
    # which bypasses the controller's own GET action entirely — it would
    # still pass even if the append landed on the wrong row (e.g. a
    # drafts.<slug> twin) as long as get_blocks_doc/4 in the TEST happened to
    # resolve the same row. This test instead round-trips through the real
    # HTTP GET action (`show_session/2`), proving an appended event is
    # actually visible to a client reading the session the normal way.
    test "an appended event is visible through GET /sessions/:slug", %{conn: conn} do
      slug = "session-events-http-roundtrip"
      create = conn |> authed() |> post(@path, body(slug))
      assert json_response(create, 200)["ok"] == true

      post_resp =
        conn
        |> authed()
        |> post(
          @path <> "/" <> slug <> "/events",
          Jason.encode!(%{"kind" => "task-closed", "ref" => "task-xyz"})
        )

      assert json_response(post_resp, 200)["count"] == 1

      show = conn |> authed() |> get(@path <> "/" <> slug)
      payload = json_response(show, 200)

      assert [%{"kind" => "task-closed", "ref" => "task-xyz"}] = payload["events"]
    end

    test "422 with the allowed kinds list for an unknown kind", %{conn: conn} do
      slug = "session-events-bad-kind"
      create = conn |> authed() |> post(@path, body(slug))
      assert json_response(create, 200)["ok"] == true

      resp =
        conn
        |> authed()
        |> post(@path <> "/" <> slug <> "/events", Jason.encode!(%{"kind" => "deployed"}))

      payload = json_response(resp, 422)
      assert payload["error"]["code"] == "invalid_kind"
      assert is_list(payload["error"]["allowed"])
      assert "note" in payload["error"]["allowed"]
      refute "deployed" in payload["error"]["allowed"]
    end

    test "404 for an unknown slug", %{conn: conn} do
      resp =
        conn
        |> authed()
        |> post(@path <> "/session-events-nope/events", Jason.encode!(%{"kind" => "note"}))

      assert json_response(resp, 404)
    end

    # Mirrors the workspace-scoped-reads describe block above: two workspaces
    # holding their own row at the same slug must each append to their OWN
    # trail, not collide.
    test "two workspaces at the same slug append to their own trail", %{conn: conn} do
      {:ok, ws_a} = Tenancy.create_workspace(%{slug: "sess-ev-scope-a", name: "sess-ev-scope-a"})
      {:ok, ws_b} = Tenancy.create_workspace(%{slug: "sess-ev-scope-b", name: "sess-ev-scope-b"})
      slug = "session-events-scoped"

      for ws <- [ws_a, ws_b] do
        resp = conn |> authed() |> post(@path, body(slug, %{"workspace_id" => ws.id}))
        assert json_response(resp, 200)["ok"] == true
      end

      resp_a =
        conn
        |> authed()
        |> post(
          @path <> "/" <> slug <> "/events",
          Jason.encode!(%{"kind" => "note", "note" => "a", "workspace_id" => ws_a.id})
        )

      assert json_response(resp_a, 200)["count"] == 1

      show_b = conn |> authed() |> get(@path <> "/" <> slug, %{"workspace_id" => ws_b.id})
      assert json_response(show_b, 200)["events"] in [nil, []]
    end
  end

  # session-conversations slice: registry of harness conversations that
  # touched this session, upserted by id.
  describe "session conversations touch" do
    test "touches a conversation and returns the registry count", %{conn: conn} do
      slug = "session-conv-http-happy-path"
      create = conn |> authed() |> post(@path, body(slug))
      assert json_response(create, 200)["ok"] == true

      resp =
        conn
        |> authed()
        |> post(
          @path <> "/" <> slug <> "/conversations",
          Jason.encode!(%{
            "conversation" => "conv-1",
            "harness" => "claude-code",
            "account" => "scaffy@jarl.no",
            "machine" => "mbp",
            "cwd" => "/tmp"
          })
        )

      payload = json_response(resp, 200)
      assert payload["ok"] == true
      assert payload["slug"] == slug
      assert payload["count"] == 1

      resp2 =
        conn
        |> authed()
        |> post(
          @path <> "/" <> slug <> "/conversations",
          Jason.encode!(%{"conversation" => "conv-2"})
        )

      assert json_response(resp2, 200)["count"] == 2
    end

    test "GET round-trip shows the conversations registry", %{conn: conn} do
      slug = "session-conv-http-roundtrip"
      create = conn |> authed() |> post(@path, body(slug))
      assert json_response(create, 200)["ok"] == true

      touch =
        conn
        |> authed()
        |> post(
          @path <> "/" <> slug <> "/conversations",
          Jason.encode!(%{"conversation" => "conv-1", "harness" => "claude-code"})
        )

      assert json_response(touch, 200)["count"] == 1

      show = conn |> authed() |> get(@path <> "/" <> slug)
      payload = json_response(show, 200)

      assert [%{"id" => "conv-1", "harness" => "claude-code"}] = payload["conversations"]
    end

    test "422 with a structured error envelope for a missing conversation id", %{conn: conn} do
      slug = "session-conv-missing-id"
      create = conn |> authed() |> post(@path, body(slug))
      assert json_response(create, 200)["ok"] == true

      resp =
        conn
        |> authed()
        |> post(@path <> "/" <> slug <> "/conversations", Jason.encode!(%{"harness" => "codex"}))

      payload = json_response(resp, 422)
      assert payload["error"]["code"] == "invalid_conversation"
      assert payload["error"]["message"]
    end

    test "404 for an unknown slug", %{conn: conn} do
      resp =
        conn
        |> authed()
        |> post(
          @path <> "/session-conv-nope/conversations",
          Jason.encode!(%{"conversation" => "conv-1"})
        )

      assert json_response(resp, 404)
    end

    test "an event logged with a conversation attr comes back on GET", %{conn: conn} do
      slug = "session-conv-event-attr"
      create = conn |> authed() |> post(@path, body(slug))
      assert json_response(create, 200)["ok"] == true

      resp =
        conn
        |> authed()
        |> post(
          @path <> "/" <> slug <> "/events",
          Jason.encode!(%{"kind" => "note", "note" => "hi", "conversation" => "conv-1"})
        )

      assert json_response(resp, 200)["ok"] == true

      show = conn |> authed() |> get(@path <> "/" <> slug)
      payload = json_response(show, 200)

      assert [%{"kind" => "note", "note" => "hi", "conversation" => "conv-1"}] =
               payload["events"]
    end
  end
end
