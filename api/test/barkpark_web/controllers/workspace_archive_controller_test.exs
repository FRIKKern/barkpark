defmodule BarkparkWeb.WorkspaceArchiveControllerTest do
  @moduledoc """
  task-55474a106554e65a — REVERSIBLE workspace archive over HTTP, the sibling
  of the hard `DELETE /api/workspaces/:workspace_slug`.

    * `POST /api/workspaces/:workspace_slug/archive`
    * `POST /api/workspaces/:workspace_slug/restore`

  What this suite pins, one describe per acceptance criterion:

    1. ROUND-TRIP — archive destroys nothing: a workspace holding a document is
       archived and restored, and the document row (every column, read raw out
       of Postgres) and the workspace row are byte-identical to before.
    2. INERT BUT NOT GONE — while archived, a scoped READ and a scoped WRITE are
       refused 409 `workspace_archived`; an unknown slug still 404s and a
       non-member still 403s `forbidden`, so the three states stay
       distinguishable.
    3. SAME FLOOR AS DELETE — archive and restore are admin-gated AND bound to
       the URL's workspace through `TenancyAuth.workspace_admin?/2`: an admin
       whose only seat is another workspace is refused, for BOTH verbs.

  async: false — the Default-workspace arm establishes the instance-Default
  seat, which is a singleton row.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @type_name "archive-post"

  defp authed(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp error_code(resp), do: Jason.decode!(resp.resp_body)["error"]["code"]

  defp token!(raw), do: elem(Auth.verify_token(raw), 1)

  # A workspace + project + public schema, with an ADMIN token bound to it
  # (`create_token/5` seats the token as `admin` — a real workspace admin).
  defp admin_workspace!(label) do
    ws = TenancyFixtures.create_workspace!()
    project = TenancyFixtures.create_project!(ws)
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => @type_name,
          "fields" => [%{"name" => "title", "type" => "string"}],
          "visibility" => "public"
        },
        @dataset,
        scope
      )

    raw = "ws-archive-#{label}-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(raw, "archive #{label}", "test", ["read", "write", "admin"], ws.id)

    assert TenancyAuth.workspace_admin?(token!(raw), ws.id)

    %{ws: ws, project: project, scope: scope, raw_admin: raw}
  end

  # The document row, EVERY column, straight out of Postgres — no Ecto schema
  # in between, so a column the schema does not load still counts.
  defp raw_rows(table, ws_id) do
    %{columns: cols, rows: rows} =
      Repo.query!(
        "SELECT * FROM #{table} WHERE #{if table == "workspaces", do: "id", else: "workspace_id"} = $1 ORDER BY 1",
        [Ecto.UUID.dump!(ws_id)]
      )

    Enum.map(rows, &Enum.zip(cols, &1))
  end

  defp archive(conn, raw, slug),
    do: conn |> authed(raw) |> post("/api/workspaces/#{slug}/archive")

  defp restore(conn, raw, slug),
    do: conn |> authed(raw) |> post("/api/workspaces/#{slug}/restore")

  defp scoped_read(conn, raw, ws, project),
    do: conn |> authed(raw) |> get("/w/#{ws.slug}/p/#{project.slug}/v1/data/counts/#{@dataset}")

  defp scoped_write(conn, raw, ws, project, doc_id) do
    body =
      Jason.encode!(%{
        "mutations" => [
          %{"create" => %{"_id" => doc_id, "_type" => @type_name, "title" => doc_id}}
        ]
      })

    conn
    |> authed(raw)
    |> post("/w/#{ws.slug}/p/#{project.slug}/v1/data/mutate/#{@dataset}", body)
  end

  # ── Criterion 1 — reversible, destroys nothing ───────────────────────────

  describe "ROUND-TRIP" do
    test "ROUND-TRIP: archive then restore leaves the document and the workspace row byte-identical",
         %{conn: conn} do
      %{ws: ws, project: project, raw_admin: raw} = admin_workspace!("rt")

      doc = TenancyFixtures.create_document_in!(ws, project, @type_name, %{"title" => "keep me"})
      assert doc

      docs_before = raw_rows("documents", ws.id)
      ws_before = raw_rows("workspaces", ws.id)

      # NON-VACUITY: there IS a document to lose.
      assert length(docs_before) >= 1

      resp = archive(build_conn(), raw, ws.slug)
      assert resp.status == 200, resp.resp_body
      body = Jason.decode!(resp.resp_body)
      assert body["archived"] == true
      assert is_binary(body["workspace"]["archived_at"])

      # WHILE ARCHIVED the document is still in the database.
      assert raw_rows("documents", ws.id) == docs_before

      resp = restore(conn, raw, ws.slug)
      assert resp.status == 200, resp.resp_body
      body = Jason.decode!(resp.resp_body)
      assert body["archived"] == false
      assert body["workspace"]["archived_at"] == nil

      assert raw_rows("documents", ws.id) == docs_before,
             "archive/restore changed the document row — archive must destroy nothing"

      assert raw_rows("workspaces", ws.id) == ws_before,
             "archive/restore did not return the workspace row to its pre-archive bytes"
    end

    test "archive is idempotent: a second archive keeps the ORIGINAL archived_at", %{conn: conn} do
      %{ws: ws, raw_admin: raw} = admin_workspace!("idem")

      first = archive(conn, raw, ws.slug)
      assert first.status == 200
      at = Jason.decode!(first.resp_body)["workspace"]["archived_at"]

      second = archive(build_conn(), raw, ws.slug)
      assert second.status == 200
      assert Jason.decode!(second.resp_body)["workspace"]["archived_at"] == at
    end
  end

  # ── Criterion 2 — inert but not gone, and distinguishable ────────────────

  describe "an archived workspace refuses scoped reads and writes with workspace_archived" do
    setup do
      %{ws: ws, project: project} = fixture = admin_workspace!("inert")

      # An UNBOUND member token (membership row, no token workspace binding),
      # so the refusal measured below is ResolveWorkspace's, not the flat
      # DeriveWorkspaceFromToken's.
      member_raw = "ws-archive-member-#{System.unique_integer([:positive])}"
      {:ok, member} = Auth.create_token(member_raw, "archive member", "test", ["read", "write"])
      {:ok, _} = TenancyAuth.create_membership(ws.id, member.id, "member")

      Map.merge(fixture, %{member_raw: member_raw, ws: ws, project: project})
    end

    test "CONTROL: before the archive the same member reads 200 and writes 200",
         %{conn: conn, ws: ws, project: project, member_raw: member_raw} do
      assert scoped_read(conn, member_raw, ws, project).status == 200

      resp = scoped_write(build_conn(), member_raw, ws, project, "pre-archive")
      assert resp.status == 200, resp.resp_body
    end

    test "READ against an archived workspace: 409 workspace_archived, naming the slug",
         %{conn: conn, ws: ws, project: project, raw_admin: raw, member_raw: member_raw} do
      assert archive(conn, raw, ws.slug).status == 200

      resp = scoped_read(build_conn(), member_raw, ws, project)
      assert resp.status == 409
      assert error_code(resp) == "workspace_archived"
      assert Jason.decode!(resp.resp_body)["error"]["details"]["workspace"] == ws.slug
    end

    test "WRITE against an archived workspace: 409 workspace_archived, and nothing is written",
         %{conn: conn, ws: ws, project: project, raw_admin: raw, member_raw: member_raw} do
      assert archive(conn, raw, ws.slug).status == 200
      before = raw_rows("documents", ws.id)

      resp = scoped_write(build_conn(), member_raw, ws, project, "while-archived")
      assert resp.status == 409
      assert error_code(resp) == "workspace_archived"
      assert raw_rows("documents", ws.id) == before
    end

    test "FLAT: a token BOUND to the archived workspace is refused 409 — never swapped to Default",
         %{conn: conn, ws: ws, raw_admin: raw} do
      TenancyFixtures.ensure_default_scope!()

      bound_raw = "ws-archive-bound-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(bound_raw, "archive bound", "test", ["read"], ws.id)

      assert conn |> authed(bound_raw) |> get("/v1/data/counts/#{@dataset}") |> Map.get(:status) ==
               200

      assert archive(build_conn(), raw, ws.slug).status == 200

      resp = build_conn() |> authed(bound_raw) |> get("/v1/data/counts/#{@dataset}")
      assert resp.status == 409
      assert error_code(resp) == "workspace_archived"
    end

    test "DISTINGUISHABLE: unknown slug 404, non-member 403 forbidden, member 409 workspace_archived",
         %{conn: conn, ws: ws, project: project, raw_admin: raw, member_raw: member_raw} do
      assert archive(conn, raw, ws.slug).status == 200

      stranger_raw = "ws-archive-stranger-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(stranger_raw, "stranger", "test", ["read", "write"])

      unknown =
        build_conn()
        |> authed(member_raw)
        |> get(
          "/w/no-such-ws-#{System.unique_integer([:positive])}/p/x/v1/data/counts/#{@dataset}"
        )

      forbidden = scoped_read(build_conn(), stranger_raw, ws, project)
      archived = scoped_read(build_conn(), member_raw, ws, project)

      assert {unknown.status, error_code(unknown)} == {404, "not_found"}
      assert {forbidden.status, error_code(forbidden)} == {403, "forbidden"}
      assert {archived.status, error_code(archived)} == {409, "workspace_archived"}
    end

    test "RESTORE lifts it: the same member reads 200 again", %{
      conn: conn,
      ws: ws,
      project: project,
      raw_admin: raw,
      member_raw: member_raw
    } do
      assert archive(conn, raw, ws.slug).status == 200
      assert scoped_read(build_conn(), member_raw, ws, project).status == 409
      assert restore(build_conn(), raw, ws.slug).status == 200
      assert scoped_read(build_conn(), member_raw, ws, project).status == 200
    end

    test "the /api/workspaces/:slug interior (projects list, project create) refuses 409 too",
         %{conn: conn, ws: ws, raw_admin: raw, member_raw: member_raw} do
      assert archive(conn, raw, ws.slug).status == 200

      listed = build_conn() |> authed(member_raw) |> get("/api/workspaces/#{ws.slug}/projects")
      assert {listed.status, error_code(listed)} == {409, "workspace_archived"}

      created =
        build_conn()
        |> authed(member_raw)
        |> post("/api/workspaces/#{ws.slug}/projects", Jason.encode!(%{name: "Nope"}))

      assert {created.status, error_code(created)} == {409, "workspace_archived"}
      refute Tenancy.get_project(ws.slug, "nope")
    end

    test "the LIST still shows the archived workspace to its member, marked with archived_at",
         %{conn: conn, ws: ws, raw_admin: raw, member_raw: member_raw} do
      assert archive(conn, raw, ws.slug).status == 200

      resp = build_conn() |> authed(member_raw) |> get("/api/workspaces")
      assert resp.status == 200

      listed = Enum.find(Jason.decode!(resp.resp_body)["workspaces"], &(&1["slug"] == ws.slug))
      assert listed, "the archived workspace vanished from its member's list"
      assert is_binary(listed["archived_at"])
    end
  end

  # ── Restore stays reachable for a token bound to the archived workspace ──

  test "RESTORE is not refused by the guard it lifts: an admin token BOUND to the archived workspace restores it",
       %{conn: conn} do
    %{ws: ws, raw_admin: raw} = admin_workspace!("self")

    # `raw` is bound to `ws` (create_token/5) — exactly the credential
    # DeriveWorkspaceFromToken halts on every non-exempt route.
    assert token!(raw).workspace_id == ws.id

    assert archive(conn, raw, ws.slug).status == 200

    listed = build_conn() |> authed(raw) |> get("/api/workspaces")
    assert listed.status == 200

    resp = restore(build_conn(), raw, ws.slug)
    assert resp.status == 200, resp.resp_body
    refute Tenancy.get_workspace_by_slug(ws.slug).archived_at
  end

  # ── Criterion 3 — same authorisation floor as delete ─────────────────────

  describe "authorisation floor" do
    test "CROSS-TENANT archive: a ws-A admin cannot archive ws-B — B stays live", %{conn: conn} do
      %{raw_admin: raw_a} = admin_workspace!("xa")
      %{ws: victim} = admin_workspace!("xb")

      # FIXTURE HONESTY: A holds no seat in B at all.
      refute TenancyAuth.member?(token!(raw_a), victim.id)

      resp = archive(conn, raw_a, victim.slug)
      assert resp.status == 403
      assert error_code(resp) == "forbidden"
      refute Tenancy.get_workspace_by_slug(victim.slug).archived_at
    end

    test "CROSS-TENANT restore: a ws-A admin cannot restore ws-B — B stays archived",
         %{conn: conn} do
      %{raw_admin: raw_a} = admin_workspace!("ra")
      %{ws: victim, raw_admin: raw_b} = admin_workspace!("rb")

      assert archive(conn, raw_b, victim.slug).status == 200
      refute TenancyAuth.member?(token!(raw_a), victim.id)

      resp = restore(build_conn(), raw_a, victim.slug)
      assert resp.status == 403
      assert error_code(resp) == "forbidden"
      assert Tenancy.get_workspace_by_slug(victim.slug).archived_at
    end

    test "predicate strength: a global admin holding a plain `member` seat in B cannot archive B",
         %{conn: conn} do
      raw_a = "ws-archive-mem-#{System.unique_integer([:positive])}"

      {:ok, token_a} =
        Auth.create_token(raw_a, "global admin", "test", ["read", "write", "admin"])

      %{ws: victim} = admin_workspace!("mb")

      {:ok, _} = TenancyAuth.create_membership(victim.id, token_a.id, "member")
      assert TenancyAuth.member?(token!(raw_a), victim.id)
      refute TenancyAuth.workspace_admin?(token!(raw_a), victim.id)

      resp = archive(conn, raw_a, victim.slug)
      assert resp.status == 403
      refute Tenancy.get_workspace_by_slug(victim.slug).archived_at
    end

    test "a NON-admin token is refused 403 before the action, for both verbs", %{conn: conn} do
      %{ws: ws} = admin_workspace!("na")
      raw = "ws-archive-nonadmin-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "non admin", "test", ["read", "write"], ws.id)

      assert archive(conn, raw, ws.slug).status == 403
      assert restore(build_conn(), raw, ws.slug).status == 403
      refute Tenancy.get_workspace_by_slug(ws.slug).archived_at
    end

    test "unauthenticated → 401; unknown slug → 404", %{conn: conn} do
      %{ws: ws, raw_admin: raw} = admin_workspace!("anon")

      assert post(conn, "/api/workspaces/#{ws.slug}/archive").status == 401
      assert post(build_conn(), "/api/workspaces/#{ws.slug}/restore").status == 401

      missing = archive(build_conn(), raw, "no-such-ws-#{System.unique_integer([:positive])}")
      assert {missing.status, error_code(missing)} == {404, "not_found"}
    end

    test "the instance-Default workspace refuses archive: 409 default_workspace_not_archivable",
         %{conn: conn} do
      {default_ws, _} = TenancyFixtures.ensure_default_scope!()
      raw = "ws-archive-default-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(raw, "default admin", "test", ["read", "write", "admin"], default_ws.id)

      assert TenancyAuth.workspace_admin?(token!(raw), default_ws.id)

      resp = archive(conn, raw, default_ws.slug)
      assert resp.status == 409
      assert error_code(resp) == "default_workspace_not_archivable"
      refute Tenancy.get_default_workspace().archived_at
    end
  end
end
