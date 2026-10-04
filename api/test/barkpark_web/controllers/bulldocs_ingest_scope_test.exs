defmodule BarkparkWeb.BulldocsIngestScopeTest do
  @moduledoc """
  THE INGEST SCOPE RULE at the door (task-3f027a24e1330c6f).

  `POST /v1/plugins/bulldocs/papers` rides the `:ingest` pipeline, which mounts
  `DeriveWorkspaceFromToken` + `AssignDefaultScope` precisely so an ingest write
  names a tenant. `BulldocsIngestController.resolve_scope/2` read the
  `workspace`/`workspace_id` body field and the `x-barkpark-workspace` header
  and NOTHING else — `conn.assigns.current_workspace` appeared nowhere in the
  file — so a workspace-bound token that sent no header had its tenant thrown
  away and the paper landed in the seeded Default Workspace.

  Four states, one door:

    1. the pipeline resolved a tenant -> that workspace is stamped, header or
       no header;
    2. the pipeline resolved nothing but the credential can mean EXACTLY ONE
       workspace -> the ruled infer path (task-6fa023cdabdc5f6a) stamps it,
       never the seeded Default;
    3. the credential can mean NONE -> typed 422 `workspace_scope_required`,
       and nothing is written;
    4. a request slug that DISAGREES with the pipeline's tenant -> typed 422
       `workspace_scope_conflict`, and nothing is written (a header is not a
       credential).

  Plus the excluded population: the SHARED-SECRET arm carries no principal and
  keeps the pipeline's Default, byte-identical.

  SCOPE NOTE (shared test database): every assertion is keyed on ids this test
  minted — its own workspaces, its own tokens, its own slugs — so a parallel
  agent's rows can neither satisfy nor break it. `async: false` because the
  seeded Default Workspace is process-global state the Default arm reads.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.LabelFixtures

  @path "/v1/plugins/bulldocs/papers"
  # Set in config/test.exs — the instance-operator shared secret.
  @ingest_secret "barkpark-test-ingest-token"

  setup do
    ws_a = create_workspace!()
    _proj_a = create_project!(ws_a, "default")
    ws_b = create_workspace!()
    _proj_b = create_project!(ws_b, "default")

    {:ok, ws_a: ws_a, ws_b: ws_b}
  end

  # A wall-compliant blocks body (charter D26 walls the ingest birth path).
  defp body(slug) do
    LabelFixtures.paper_attrs(%{
      "slug" => slug,
      "blocks" => [
        %{"id" => "h-1", "type" => "heading", "level" => 1, "text" => slug},
        %{"id" => "p-1", "type" => "paragraph", "text" => "ingest scope rule"}
      ]
    })
  end

  defp post_paper(conn, raw_token, slug, headers \\ []) do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw_token}")
      |> put_req_header("content-type", "application/json")

    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> post(@path, body(slug))
  end

  # Both the published doc_id and its draft twin, so an absence assertion can
  # never pass by looking in the wrong place.
  defp find_paper(slug) do
    Repo.one(
      from d in Document,
        where: d.type == "paper" and d.doc_id in ^[slug, "drafts.#{slug}"],
        limit: 1
    )
  end

  # A HOMELESS admin token: `workspace_id` NULL, so `DeriveWorkspaceFromToken`
  # no-ops and `AssignDefaultScope` stamps the seeded Default. Minted through
  # the changeset rather than `Auth.create_token/5`, whose `workspace_id`
  # argument DEFAULTS to the seeded Default id — a token minted that way is
  # never homeless and could not reach the state under test.
  defp homeless_admin_token!(raw, member_of) do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "ingest-scope-rule",
        dataset: "production",
        permissions: ["read", "write", "admin"],
        workspace_id: nil
      })
      |> Repo.insert()

    for ws <- member_of do
      {:ok, _} = Tenancy.Auth.create_membership(ws.id, token.id, "member", "api_token")
    end

    token
  end

  describe "PREFER — the pipeline resolved a tenant" do
    test "a workspace-bound token with NO header and NO body scope lands in ITS workspace",
         %{conn: conn, ws_a: ws_a} do
      raw = "ingest-scope-bound-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(raw, "bound-a", "production", ["read", "write", "admin"], ws_a.id)

      slug = "ingest-scope-bound-#{System.unique_integer([:positive])}"

      resp = post_paper(conn, raw, slug)
      assert resp.status == 200, "expected the scoped ingest to succeed: #{resp.resp_body}"

      doc = find_paper(slug)
      assert doc, "the write must have landed a row"

      assert doc.workspace_id == ws_a.id,
             "the paper must carry the PIPELINE-resolved workspace, " <>
               "not the seeded Default (got #{inspect(doc.workspace_id)})"
    end

    test "a header naming the SAME workspace is honoured (it agrees)", %{conn: conn, ws_a: ws_a} do
      raw = "ingest-scope-agree-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(raw, "agree-a", "production", ["read", "write", "admin"], ws_a.id)

      slug = "ingest-scope-agree-#{System.unique_integer([:positive])}"

      resp = post_paper(conn, raw, slug, [{"x-barkpark-workspace", ws_a.slug}])
      assert resp.status == 200, resp.resp_body

      assert find_paper(slug).workspace_id == ws_a.id
    end
  end

  describe "REFUSE — a request slug that disagrees with the credential" do
    test "a token bound to A sending a header naming B is refused, and writes NOTHING",
         %{conn: conn, ws_a: ws_a, ws_b: ws_b} do
      raw = "ingest-scope-conflict-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(raw, "conflict-a", "production", ["read", "write", "admin"], ws_a.id)

      slug = "ingest-scope-conflict-#{System.unique_integer([:positive])}"

      resp = post_paper(conn, raw, slug, [{"x-barkpark-workspace", ws_b.slug}])

      assert resp.status == 422
      error = Jason.decode!(resp.resp_body)["error"]
      assert error["code"] == "workspace_scope_conflict"
      assert error["details"]["resolved"] == ws_a.slug
      assert error["details"]["sent"] == ws_b.slug

      refute find_paper(slug),
             "a refused write must leave no row — not in A, not in B, not in Default"
    end
  end

  describe "CONTROL — a scope-less token takes the ruled infer-or-refuse path" do
    test "a homeless token that can mean EXACTLY ONE workspace infers it, never Default",
         %{conn: conn, ws_b: ws_b} do
      raw = "ingest-scope-infer-#{System.unique_integer([:positive])}"
      _token = homeless_admin_token!(raw, [ws_b])
      slug = "ingest-scope-infer-#{System.unique_integer([:positive])}"

      resp = post_paper(conn, raw, slug)
      assert resp.status == 200, resp.resp_body

      doc = find_paper(slug)
      assert doc

      assert doc.workspace_id == ws_b.id,
             "the scope-less token's write must land in the ONE workspace it can mean"

      default = Tenancy.get_default_workspace()

      refute default && doc.workspace_id == default.id,
             "the ruled path must never stamp the seeded Default"
    end

    test "a homeless token that can mean NONE is refused 422 and writes NOTHING", %{conn: conn} do
      raw = "ingest-scope-platform-#{System.unique_integer([:positive])}"
      _token = homeless_admin_token!(raw, [])
      slug = "ingest-scope-platform-#{System.unique_integer([:positive])}"

      resp = post_paper(conn, raw, slug)

      assert resp.status == 422
      error = Jason.decode!(resp.resp_body)["error"]
      assert error["code"] == "workspace_scope_required"
      assert error["details"]["workspaces"] == []

      refute find_paper(slug), "a refused write must leave no row, not even in Default"
    end

    test "a homeless token that can mean TWO workspaces is refused 422",
         %{conn: conn, ws_a: ws_a, ws_b: ws_b} do
      raw = "ingest-scope-ambiguous-#{System.unique_integer([:positive])}"
      _token = homeless_admin_token!(raw, [ws_a, ws_b])
      slug = "ingest-scope-ambiguous-#{System.unique_integer([:positive])}"

      resp = post_paper(conn, raw, slug)

      assert resp.status == 422
      error = Jason.decode!(resp.resp_body)["error"]
      assert error["code"] == "workspace_scope_required"
      assert Enum.sort(error["details"]["workspaces"]) == Enum.sort([ws_a.slug, ws_b.slug])

      refute find_paper(slug)
    end
  end

  # A body project_id is not a credential either: it must name a project UNDER
  # the resolved workspace, or the paper lands with a workspace/project pair no
  # tenant owns (r2-lane-b paper write-path audit, 2026-09-30).
  describe "REFUSE — a body project_id outside the resolved workspace" do
    defp post_scoped(conn, raw, slug, ws_id, project_id) do
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")
      |> post(
        @path,
        Map.merge(body(slug), %{"workspace_id" => ws_id, "project_id" => project_id})
      )
    end

    test "a token bound to A naming A's workspace with B's project is refused, and writes NOTHING",
         %{conn: conn, ws_a: ws_a, ws_b: ws_b} do
      proj_b = create_project!(ws_b)
      raw = "ingest-scope-project-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(raw, "project-a", "production", ["read", "write", "admin"], ws_a.id)

      slug = "ingest-scope-project-#{System.unique_integer([:positive])}"
      resp = post_scoped(conn, raw, slug, ws_a.id, proj_b.id)

      assert resp.status == 422, resp.resp_body
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "project_scope_conflict"
      refute find_paper(slug), "a refused write must leave no row"
    end

    test "the shared secret naming A's workspace with B's project is refused too",
         %{conn: conn, ws_a: ws_a, ws_b: ws_b} do
      proj_b = create_project!(ws_b)
      slug = "ingest-scope-project-secret-#{System.unique_integer([:positive])}"
      resp = post_scoped(conn, @ingest_secret, slug, ws_a.id, proj_b.id)

      assert resp.status == 422, resp.resp_body
      refute find_paper(slug)
    end

    test "a project under the named workspace is stamped (positive control)",
         %{conn: conn, ws_a: ws_a} do
      proj_a = create_project!(ws_a)
      raw = "ingest-scope-project-ok-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(raw, "project-ok", "production", ["read", "write", "admin"], ws_a.id)

      slug = "ingest-scope-project-ok-#{System.unique_integer([:positive])}"
      resp = post_scoped(conn, raw, slug, ws_a.id, proj_a.id)

      assert resp.status == 200, resp.resp_body
      doc = find_paper(slug)
      assert doc.workspace_id == ws_a.id
      assert doc.project_id == proj_a.id
    end
  end

  # OWNER RULING 2026-10-03 #8 (task-8e46d70f7b5e3fc7): a token that names a
  # workspace must have write access there, or be on an ARMED operator
  # allowlist; the shared-secret producer is unchanged.
  describe "REFUSE — a homeless token naming a workspace it cannot write (ruling #8)" do
    test "a homeless admin token seated only in A cannot write a paper into B",
         %{conn: conn, ws_a: ws_a, ws_b: ws_b} do
      raw = "ingest-named-b-#{System.unique_integer([:positive])}"
      _token = homeless_admin_token!(raw, [ws_a])
      slug = "ingest-named-b-#{System.unique_integer([:positive])}"

      resp = post_paper(conn, raw, slug, [{"x-barkpark-workspace", ws_b.slug}])

      assert resp.status == 403, resp.resp_body
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "workspace_forbidden"
      refute find_paper(slug), "a refused write must leave no row"
    end

    test "the same token naming B by workspace_id in the body is refused too",
         %{conn: conn, ws_a: ws_a, ws_b: ws_b} do
      raw = "ingest-named-b-id-#{System.unique_integer([:positive])}"
      _token = homeless_admin_token!(raw, [ws_a])
      slug = "ingest-named-b-id-#{System.unique_integer([:positive])}"

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(@path, Map.put(body(slug), "workspace_id", ws_b.id))

      assert resp.status == 403, resp.resp_body
      refute find_paper(slug)
    end

    test "naming its OWN workspace still writes there", %{conn: conn, ws_a: ws_a} do
      raw = "ingest-named-a-#{System.unique_integer([:positive])}"
      _token = homeless_admin_token!(raw, [ws_a])
      slug = "ingest-named-a-#{System.unique_integer([:positive])}"

      resp = post_paper(conn, raw, slug, [{"x-barkpark-workspace", ws_a.slug}])

      assert resp.status == 200, resp.resp_body
      assert find_paper(slug).workspace_id == ws_a.id
    end

    test "the read twin: B's session is not readable by naming B", %{
      conn: conn,
      ws_a: ws_a,
      ws_b: ws_b
    } do
      slug = "ingest-named-session-#{System.unique_integer([:positive])}"

      seeded =
        conn
        |> put_req_header("authorization", "Bearer #{@ingest_secret}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-barkpark-workspace", ws_b.slug)
        |> post("/v1/plugins/bulldocs/sessions", %{
          "slug" => slug,
          "title" => slug,
          "blocks" => [%{"id" => "p-1", "type" => "paragraph", "text" => "b only"}]
        })

      assert seeded.status == 200, seeded.resp_body

      raw = "ingest-named-read-#{System.unique_integer([:positive])}"
      _token = homeless_admin_token!(raw, [ws_a])

      resp =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("x-barkpark-workspace", ws_b.slug)
        |> get("/v1/plugins/bulldocs/sessions/#{slug}")

      assert resp.status == 403, resp.resp_body
    end
  end

  describe "UNCHANGED — the excluded population" do
    test "the SHARED SECRET carries no principal and keeps the pipeline's Default",
         %{conn: conn} do
      slug = "ingest-scope-secret-#{System.unique_integer([:positive])}"

      resp = post_paper(conn, @ingest_secret, slug)
      assert resp.status == 200, resp.resp_body

      doc = find_paper(slug)
      assert doc, "the shared-secret producer must keep working, byte-identical"

      default = Tenancy.get_default_workspace()
      assert default, "this arm's assertion needs the seeded Default to exist"

      assert doc.workspace_id == default.id,
             "the shared secret is the ruling's excluded population: it keeps Default"
    end

    test "the shared secret can still address a workspace by SLUG", %{conn: conn, ws_b: ws_b} do
      slug = "ingest-scope-secret-slug-#{System.unique_integer([:positive])}"

      resp = post_paper(conn, @ingest_secret, slug, [{"x-barkpark-workspace", ws_b.slug}])
      assert resp.status == 200, resp.resp_body

      assert find_paper(slug).workspace_id == ws_b.id
    end
  end
end
