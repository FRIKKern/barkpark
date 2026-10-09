defmodule BarkparkWeb.PreviewLinkTest do
  @moduledoc """
  task-6812c3100d7aedbc — DRAFT-capable preview links: mint -> `GET /sp/:token`
  resolves the ONE bound document, published OR unpublished, scoped to the
  LINK's own workspace. Mirrors `BarkparkWeb.ShareLinkTest`'s shape for its
  shared concerns (admin gating, revoke, garbage token); the tests specific to
  this feature are the draft serve, wrong-doc and cross-workspace cases below.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Repo}
  alias Barkpark.Sharing.PreviewLink

  import Barkpark.RateLimiterSandbox
  import Barkpark.TenancyFixtures

  # Whole-node ETS table (:barkpark_rate_limiter) — reset so an earlier test's
  # spend never leaks into the rate-limit tests below (same reset
  # RateLimitTest itself runs for the same reason).
  setup :reset_rate_limiter!

  @dataset "production"
  @admin "preview-link-admin"
  @junior "preview-link-junior"

  setup %{conn: conn} do
    {:ok, admin_tok} =
      Auth.create_token(@admin, "pl-admin", @dataset, ["read", "write", "admin"])

    {:ok, _} = Auth.create_token(@junior, "pl-junior", @dataset, ["read", "write"])

    ws = create_workspace!("preview-link-ws")
    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, admin_tok.id, "admin")
    proj = create_project!(ws, "preview-link-proj")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "post1", "title" => "A Post"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("post1", "post", @dataset, scope)

    %{
      conn: conn,
      ws: ws,
      proj: proj,
      scope: scope,
      admin_tok: admin_tok,
      scope_str: "#{ws.slug}/#{proj.slug}/#{@dataset}"
    }
  end

  defp admin(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer #{@admin}")
      |> put_req_header("content-type", "application/json")

  defp junior(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer #{@junior}")
      |> put_req_header("content-type", "application/json")

  defp mint(conn, body),
    do: conn |> admin() |> post("/v1/shares/preview-links", body) |> json_response(201)

  defp with_read_limit(n) do
    original = Application.get_env(:barkpark, :rate_limits)

    Application.put_env(
      :barkpark,
      :rate_limits,
      Keyword.merge([read_per_minute: n, write_per_minute: 60, datasets: %{}], [])
    )

    on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)
  end

  test "a PUBLISHED doc link returns the document JSON at /sp/:token", %{
    conn: conn,
    scope_str: scope
  } do
    %{"token" => token} = mint(conn, %{scope: scope, ref_type: "post", doc_id: "post1"})

    body = get(scoped_conn(), "/sp/#{token}") |> json_response(200)
    assert body["_id"] == "post1"
    assert body["title"] == "A Post"
  end

  test "a DRAFT doc link resolves the drafts. row — the feature's whole point", %{
    conn: conn,
    scope: scope,
    scope_str: scope_str
  } do
    {:ok, draft} =
      Content.upsert_document(
        "post",
        %{"doc_id" => "post1", "title" => "Edited Draft Title"},
        @dataset,
        scope
      )

    assert draft.doc_id == "drafts.post1"

    %{"token" => token} =
      mint(conn, %{scope: scope_str, ref_type: "post", doc_id: "drafts.post1"})

    body = get(scoped_conn(), "/sp/#{token}") |> json_response(200)
    assert body["title"] == "Edited Draft Title"
  end

  test "a DOC link redacts a private field for the anonymous reader", %{
    conn: conn,
    ws: ws,
    proj: proj,
    scope_str: scope_str
  } do
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "ssn", "type" => "string", "private" => true}
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "postsec", "title" => "Secret Post", "ssn" => "SSN-777"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("postsec", "post", @dataset, scope)

    %{"token" => token} = mint(conn, %{scope: scope_str, ref_type: "post", doc_id: "postsec"})

    body = get(scoped_conn(), "/sp/#{token}") |> json_response(200)
    refute Map.has_key?(body, "ssn")
    refute body |> Jason.encode!() |> String.contains?("SSN-777")
  end

  test "WRONG-DOC REFUSED: no param can redirect which document a token serves", %{
    conn: conn,
    scope_str: scope,
    scope: proj_scope
  } do
    {:ok, _} =
      Content.create_document("post", %{"doc_id" => "post2", "title" => "Other Post"}, @dataset,
        workspace_id: proj_scope[:workspace_id],
        project_id: proj_scope[:project_id]
      )

    {:ok, _} = Content.publish_document("post2", "post", @dataset, proj_scope)

    %{"token" => token} = mint(conn, %{scope: scope, ref_type: "post", doc_id: "post1"})

    # An attacker-supplied doc_id/ref_id query param is simply ignored — show/2
    # takes no such param, it reads only the resolved link's OWN doc_id.
    body =
      get(scoped_conn(), "/sp/#{token}?doc_id=post2&ref_id=post2") |> json_response(200)

    assert body["_id"] == "post1"
    refute body["_id"] == "post2"
  end

  test "CROSS-WORKSPACE REFUSED: a token minted in ws A never resolves ws B's same-id doc", %{
    conn: conn,
    scope_str: scope_a
  } do
    ws_b = create_workspace!("preview-link-ws-b")
    {:ok, admin_b} = Auth.create_token("preview-link-admin-b", "pl-admin-b", @dataset, ["admin"])
    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws_b.id, admin_b.id, "admin")
    proj_b = create_project!(ws_b, "preview-link-proj-b")
    scope_b_opts = [workspace_id: ws_b.id, project_id: proj_b.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        scope_b_opts
      )

    # SAME doc_id as ws A's "post1", different workspace, different content.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "post1", "title" => "Workspace B's Post"},
        @dataset,
        scope_b_opts
      )

    {:ok, _} = Content.publish_document("post1", "post", @dataset, scope_b_opts)

    %{"token" => token} = mint(conn, %{scope: scope_a, ref_type: "post", doc_id: "post1"})

    body = get(scoped_conn(), "/sp/#{token}") |> json_response(200)
    assert body["title"] == "A Post"
    refute body["title"] == "Workspace B's Post"
  end

  test "revoking a link makes /sp/:token 404", %{conn: conn, scope_str: scope} do
    %{"token" => token, "link" => link} =
      mint(conn, %{scope: scope, ref_type: "post", doc_id: "post1"})

    assert get(scoped_conn(), "/sp/#{token}").status == 200

    assert conn
           |> admin()
           |> delete("/v1/shares/preview-links/#{link["id"]}")
           |> json_response(200)
           |> Map.get("revoked") == true

    assert get(scoped_conn(), "/sp/#{token}").status == 404
  end

  test "an EXPIRED link is 404 — byte-identical to missing", %{conn: conn, scope_str: scope} do
    %{"token" => token, "link" => link} =
      mint(conn, %{scope: scope, ref_type: "post", doc_id: "post1", ttl: 3600})

    Repo.get!(PreviewLink, link["id"])
    |> Ecto.Changeset.change(
      expires_at: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    assert get(scoped_conn(), "/sp/#{token}").status == 404
  end

  test "a garbage token is 404", %{} do
    assert get(scoped_conn(), "/sp/not-a-real-token").status == 404
  end

  test "minting / listing / revoking refuse a caller with no membership in this workspace",
       %{conn: conn, scope_str: scope} do
    # @junior carries flat "write" permission (so it clears the router's
    # :require_write pipeline gate the same as an admin would) but is NEVER
    # made a MEMBER of this test's workspace -- task-0548f06277c4712e and
    # task-9cfe08fe1e91b6c9 both confine on workspace membership + write,
    # not on global "admin", so a stranger to this specific workspace is
    # still refused on mint/list exactly as before the widening.
    body = %{scope: scope, ref_type: "post", doc_id: "post1"}
    assert conn |> post("/v1/shares/preview-links", body) |> Map.get(:status) == 401
    assert conn |> junior() |> post("/v1/shares/preview-links", body) |> Map.get(:status) == 403

    assert conn
           |> junior()
           |> get("/v1/shares/preview-links?scope=#{scope}&ref_type=post&doc_id=post1")
           |> Map.get(:status) == 403

    # revoke is DIFFERENT (task-0548f06277c4712e): it is no longer gated by
    # `:require_admin` at the router, so a write-capable caller (junior
    # qualifies) reaches PreviewLinks.revoke_scoped/2, which answers
    # {:error, :not_found} for ANY id it cannot cast/resolve/authorize --
    # a malformed id ("x") is 404 for every caller now, not a workspace-level
    # 403, matching the "no existence oracle" law this door already holds.
    assert conn |> junior() |> delete("/v1/shares/preview-links/x") |> Map.get(:status) == 404
  end

  test "minting a link for a non-existent document is 422", %{conn: conn, scope_str: scope} do
    resp =
      conn
      |> admin()
      |> post("/v1/shares/preview-links", %{
        scope: scope,
        ref_type: "post",
        doc_id: "nope-nonexistent"
      })

    assert resp.status == 422
  end

  test "list shows a document's preview links (no token/hash)", %{conn: conn, scope_str: scope} do
    %{"link" => link} = mint(conn, %{scope: scope, ref_type: "post", doc_id: "post1"})

    body =
      conn
      |> admin()
      |> get("/v1/shares/preview-links?scope=#{scope}&ref_type=post&doc_id=post1")
      |> json_response(200)

    assert [listed] = body["links"]
    assert listed["id"] == link["id"]
    refute Map.has_key?(listed, "token")
    refute Map.has_key?(listed, "token_hash")
  end

  # ── hardening headers + per-IP rate limit (team-lead review) ─────────────

  test "the three hardening headers are on a SUCCESSFUL /sp response", %{
    conn: conn,
    scope_str: scope
  } do
    %{"token" => token} = mint(conn, %{scope: scope, ref_type: "post", doc_id: "post1"})

    resp = get(scoped_conn(), "/sp/#{token}")
    assert resp.status == 200
    assert get_resp_header(resp, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(resp, "cache-control") == ["private, no-store"]
    assert get_resp_header(resp, "x-robots-tag") == ["noindex"]
  end

  test "the three hardening headers are ALSO on a REFUSED /sp response", %{} do
    resp = get(scoped_conn(), "/sp/not-a-real-token")
    assert resp.status == 404
    assert get_resp_header(resp, "referrer-policy") == ["no-referrer"]
    assert get_resp_header(resp, "cache-control") == ["private, no-store"]
    assert get_resp_header(resp, "x-robots-tag") == ["noindex"]
  end

  test "RATE-LIMITED PER IP: a burst of anonymous /sp requests from one IP 429s", %{
    conn: conn,
    scope_str: scope
  } do
    with_read_limit(2)

    %{"token" => token} = mint(conn, %{scope: scope, ref_type: "post", doc_id: "post1"})

    assert get(scoped_conn(), "/sp/#{token}").status == 200
    assert get(scoped_conn(), "/sp/#{token}").status == 200
    limited = get(scoped_conn(), "/sp/#{token}")

    assert limited.status == 429
    assert Jason.decode!(limited.resp_body)["error"]["code"] == "rate_limited"
  end

  test "RATE-LIMITED PER IP: a different IP keeps its own budget", %{
    conn: conn,
    scope_str: scope
  } do
    with_read_limit(1)

    %{"token" => token} = mint(conn, %{scope: scope, ref_type: "post", doc_id: "post1"})

    ip_a = scoped_conn() |> put_req_header("x-forwarded-for", "203.0.113.10")
    ip_b = scoped_conn() |> put_req_header("x-forwarded-for", "203.0.113.20")

    assert get(ip_a, "/sp/#{token}").status == 200
    assert get(ip_a, "/sp/#{token}").status == 429
    # B is untouched — its own, unspent bucket.
    assert get(ip_b, "/sp/#{token}").status == 200
  end
end
