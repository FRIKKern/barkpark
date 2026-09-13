defmodule BarkparkWeb.SessionAutoLogTest do
  @moduledoc """
  task-bc34e83515bbd91f — session-handoff design v1.5 (§5b): SERVER-SIDE session
  auto-log.

  v1 shipped the `type:session` document, `Content.Sessions.append_event/5` and
  the `POST .../sessions/:slug/events` door, and then left the trail to agent
  discipline: somebody had to REMEMBER to call `bp session log` after every
  milestone. §5b removes that for the two milestones Barkpark itself witnesses —
  a task close and a paper publish — by appending `{ts, kind, ref}` at the
  endpoint when the request names an open session.

  What each arm pins, and what reds without it:

    1. `POST /v1/tasks/:id/close` + the header appends
       `{ts, kind: "task-closed", ref: <doc_id>}`.
    2. `POST /v1/plugins/bulldocs/papers` + the header appends
       `{ts, kind: "paper-published", ref: <slug>}`.
    3. THE CONTROL — the SAME two calls with NO header append NOTHING. Without
       this arm an implementation that logged every close to every session
       would pass arms 1 and 2.
    4. An unknown slug is a NO-OP, not a failure: the close still returns 200
       and the row is still closed. §5b's error contract is explicit — "never
       fail a task close or a push because the session log call failed".
    5. TENANCY, FAIL CLOSED — a session in ANOTHER workspace is not appended to,
       and the close still succeeds. The rule applied is
       `SessionAutoLog.doc_scope_opts/1`: the lookup runs under the workspace of
       the document the milestone just WROTE (workspace-exact, project-agnostic,
       `:shared_only` rather than `nil` for a global doc — `nil` at
       `Content.Scope.scope_to_workspace_or_global/3` is the CROSS-TENANT read).

  THE HEADER IS `X-Barkpark-Session-Slug`, NOT the `X-Barkpark-Session` §5b
  spelled. That name was already taken on main by the claim-session
  discriminator (`Barkpark.Tasks.SessionId.derive/2`, read at
  `TasksController.session_id/2`), where the value is a SECRET whose
  unforgeability is the point. A session slug is a public doc_id. Arm 6 pins
  that the two headers stay separate: a slug sent on the OLD header logs
  nothing.

  MUTATION PROOF: delete the `SessionAutoLog.maybe_log(...)` call from
  `TasksController.close/2`'s `:closed` arm and from
  `BulldocsIngestController.auto_log_publish/3` — arms 1, 2 red by name; the
  control arms stay green (which is what makes them controls).
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, Tasks, Tenancy, TenancyFixtures}
  alias Barkpark.Content.Document
  alias Barkpark.LabelFixtures
  alias BarkparkWeb.SessionAutoLog

  @token "barkpark-test-session-autolog"
  @ingest_token "barkpark-test-ingest-token"
  @dataset "production"
  @papers_path "/v1/plugins/bulldocs/papers"
  @header "x-barkpark-session-slug"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-session-autolog", "test", ["read", "write"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope, ws: ws, project: project}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  # A session row in `workspace_id`. Created through the context (not the HTTP
  # door) so the fixture cannot itself depend on the code under test.
  defp session!(slug, workspace_id) do
    {:ok, doc} =
      Content.upsert_blocks_doc("session", %{
        "slug" => slug,
        "title" => slug,
        "status" => "open",
        "workspace_id" => workspace_id
      })

    doc
  end

  # Read the trail back UNSCOPED-BY-doc_id (Repo, not the scoped reader) so a
  # scoping bug in the READ cannot be mistaken for "nothing was appended".
  defp events(slug) do
    case Repo.get_by(Document, doc_id: slug, type: "session") do
      %Document{content: content} -> content["events"] || []
      nil -> flunk("no session row at #{slug}")
    end
  end

  # ── the task-close door ───────────────────────────────────────────────────

  defp claimable_task!(scope) do
    doc_id = uniq("autolog-task")
    phase = uniq("autolog-phase")

    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "parent_id" => phase,
            "acceptance_criteria" => [
              %{"criterion" => "built", "met" => true, "evidence" => "this test"}
            ]
          }
        },
        @dataset,
        scope
      )

    %{doc_id: doc_id, phase: phase}
  end

  defp claim!(conn, %{phase: phase}) do
    payload =
      conn
      |> authed(@token)
      |> post("/v1/tasks/claim", Jason.encode!(%{worker_id: "api-wE-r16", phase_id: phase}))
      |> json_response(200)

    {payload["doc"]["doc_id"], payload["doc"]["claim"]["epoch"]}
  end

  # Close the task, optionally naming a session on `header_slug`.
  defp close!(conn, scope, header_slug) do
    task = claimable_task!(scope)
    {doc_id, epoch} = claim!(conn, task)

    conn = authed(conn, @token)

    conn =
      if header_slug, do: put_req_header(conn, @header, header_slug), else: conn

    body =
      conn
      |> post(
        "/v1/tasks/#{doc_id}/close",
        Jason.encode!(%{worker_id: "api-wE-r16", observed_epoch: epoch})
      )
      |> json_response(200)

    {doc_id, body}
  end

  # ── the paper-publish door ────────────────────────────────────────────────

  defp publish!(conn, header_slug) do
    slug = uniq("autolog-paper")

    payload =
      LabelFixtures.paper_attrs(%{
        "slug" => slug,
        "blocks" => [
          %{"type" => "heading", "level" => 1, "text" => "Session auto-log fixture"},
          %{
            "type" => "paragraph",
            "content" => [
              %{
                "type" => "text",
                "text" =>
                  "Body copy long enough that the hollow-paper gate sees a real document " <>
                    "and not a skeleton with a lone heading block on top of it."
              }
            ]
          }
        ]
      })

    conn = authed(conn, @ingest_token)
    conn = if header_slug, do: put_req_header(conn, @header, header_slug), else: conn

    body = conn |> post(@papers_path, payload) |> json_response(200)
    assert body["ok"] == true
    slug
  end

  # ── arm 1 ─────────────────────────────────────────────────────────────────

  describe "task close" do
    test "WITH the session header appends {ts, kind: task-closed, ref} to the trail",
         %{conn: conn, scope: scope, ws: ws} do
      slug = uniq("session-close")
      session!(slug, ws.id)

      {doc_id, body} = close!(conn, scope, slug)
      assert body["ok"] != false

      assert [event] = events(slug)
      assert event["kind"] == "task-closed"
      assert event["ref"] == doc_id
      assert {:ok, ts, _} = DateTime.from_iso8601(event["ts"])
      assert DateTime.diff(DateTime.utc_now(), ts, :second) < 30
    end

    # ── arm 3 (control) ──
    test "WITHOUT the header appends NOTHING", %{conn: conn, scope: scope, ws: ws} do
      slug = uniq("session-close-control")
      session!(slug, ws.id)

      {_doc_id, _body} = close!(conn, scope, nil)

      assert events(slug) == []
    end

    # ── arm 6 (the header-collision control) ──
    test "the slug on the OLD x-barkpark-session header logs NOTHING — that header is the claim secret",
         %{conn: conn, scope: scope, ws: ws} do
      slug = uniq("session-close-oldheader")
      session!(slug, ws.id)

      task = claimable_task!(scope)
      {doc_id, epoch} = claim!(conn, task)

      conn
      |> authed(@token)
      |> put_req_header("x-barkpark-session", slug)
      |> post(
        "/v1/tasks/#{doc_id}/close",
        Jason.encode!(%{worker_id: "api-wE-r16", observed_epoch: epoch})
      )
      |> json_response(200)

      assert events(slug) == []
    end

    # ── arm 4 ──
    test "an UNKNOWN slug leaves the close successful and writes nothing",
         %{conn: conn, scope: scope} do
      {doc_id, body} = close!(conn, scope, "session-does-not-exist-anywhere")

      assert body["ok"] != false
      row = Repo.get_by!(Document, doc_id: doc_id)
      assert row.content["lifecycle_status"] in ["done", "closed", "completed"]
      refute Repo.get_by(Document, doc_id: "session-does-not-exist-anywhere", type: "session")
    end

    # ── arm 5 (tenancy, fail closed) ──
    test "a session in ANOTHER workspace is NOT appended to, and the close still succeeds",
         %{conn: conn, scope: scope} do
      {:ok, other} =
        Tenancy.create_workspace(%{slug: uniq("autolog-other"), name: "autolog-other"})

      slug = uniq("session-foreign")
      session!(slug, other.id)

      {_doc_id, body} = close!(conn, scope, slug)

      assert body["ok"] != false
      assert events(slug) == []
    end
  end

  # ── arm 2 ─────────────────────────────────────────────────────────────────

  describe "paper publish" do
    test "WITH the session header appends {ts, kind: paper-published, ref}",
         %{conn: conn, ws: ws} do
      slug = uniq("session-publish")
      session!(slug, ws.id)

      paper_slug = publish!(conn, slug)

      assert [event] = events(slug)
      assert event["kind"] == "paper-published"
      assert event["ref"] == paper_slug
      assert {:ok, _ts, _} = DateTime.from_iso8601(event["ts"])
    end

    # ── arm 3 (control) ──
    test "WITHOUT the header appends NOTHING", %{conn: conn, ws: ws} do
      slug = uniq("session-publish-control")
      session!(slug, ws.id)

      _ = publish!(conn, nil)

      assert events(slug) == []
    end

    # ── arm 5 (tenancy, fail closed) ──
    test "a session in ANOTHER workspace is NOT appended to, and the publish still succeeds",
         %{conn: conn} do
      {:ok, other} =
        Tenancy.create_workspace(%{slug: uniq("autolog-other-p"), name: "autolog-other-p"})

      slug = uniq("session-publish-foreign")
      session!(slug, other.id)

      _ = publish!(conn, slug)

      assert events(slug) == []
    end
  end

  # ── the scope rule itself ─────────────────────────────────────────────────

  describe "doc_scope_opts/1 (the tenancy rule)" do
    test "a workspace-owned doc scopes to THAT workspace, project-agnostic" do
      assert SessionAutoLog.doc_scope_opts(%{workspace_id: "ws-1", project_id: "p-1"}) ==
               [workspace_id: "ws-1"]
    end

    # nil is the CROSS-TENANT read at Scope.scope_to_workspace_or_global/3, so a
    # global doc must NOT produce one. :shared_only pins the lookup to
    # `workspace_id IS NULL`.
    test "a doc with no workspace fails CLOSED to :shared_only, never nil" do
      assert SessionAutoLog.doc_scope_opts(%{workspace_id: nil, project_id: nil}) ==
               [workspace_id: :shared_only]

      refute Keyword.get(SessionAutoLog.doc_scope_opts(%{}), :workspace_id) == nil
    end
  end
end
