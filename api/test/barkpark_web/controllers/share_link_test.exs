defmodule BarkparkWeb.ShareLinkTest do
  @moduledoc """
  P7 — ITEM (per-document) share links: mint → `/s/:token` resolves the ONE
  bound item (paper / doc / media), scoped to the LINK's own workspace and
  INDEPENDENT of any section share. Revocable; admin-only management.

  OBJECT-AUTHZ (SA-S1): admin management is scoped to the ACTOR's workspace.
  A workspace-bound admin token cannot revoke, list (recover the raw
  `/s/<token>` credential), or mint against ANOTHER workspace's item — a foreign
  id/scope resolves `not_found`, fail-closed. A nil-workspace host/platform admin
  keeps cross-workspace reach. Reverting `Links.revoke/2`'s scoped resolve or the
  controller's `ensure_token_scope` guard REDs the cross-tenant tests below
  (red-without-fix — the IDOR was run-proven open on origin/main).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Media}
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth.ApiToken
  alias Barkpark.Sharing.Links

  @dataset "production"
  @admin "share-link-admin"
  @junior "share-link-junior"
  @host "share-link-host"

  defmodule MissingRedirectTenancy do
    def get_workspace_by_id(_id), do: nil
    def get_project_by_id(_id), do: nil
  end

  setup %{conn: conn} do
    # E3 tag registry: the fixture weighted tags (fixture-tag-N) these tests
    # publish must resolve to PUBLISHED type:tag docs in the dataset scope.
    Barkpark.LabelFixtures.register_tags!(@dataset)

    ws = create_workspace!("link-ws")
    proj = create_project!(ws, "link-proj")
    scope = [workspace_id: ws.id, project_id: proj.id]

    # @admin is BOUND to this fixture workspace (5th arg) — object-authz now
    # scopes mint/list/revoke to the actor's workspace, so a same-workspace admin
    # is what the happy-path tests exercise. (create_token/4 would bind to the
    # seeded DEFAULT workspace, a DIFFERENT tenant, and every mint here would 404.)
    {:ok, _} = Auth.create_token(@admin, "sl-admin", @dataset, ["read", "write", "admin"], ws.id)
    {:ok, _} = Auth.create_token(@junior, "sl-junior", @dataset, ["read", "write"], ws.id)

    # Workspace B + its own bound admin token — the cross-tenant attacker/victim
    # pair. And a nil-workspace HOST/platform admin token (direct insert; there is
    # no create_token arg for nil once a default workspace is seeded) that must
    # keep cross-workspace reach.
    ws_b = create_workspace!("link-ws-b")
    proj_b = create_project!(ws_b, "link-proj-b")
    host_admin_token!(@host)

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

    # A published paper + a published post in this scope.
    {:ok, _} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => "demo-paper",
          "title" => "Demo Paper",
          "content" =>
            Barkpark.LabelFixtures.with_labels(%{
              "body_html" => "<h1>Shared via a direct link</h1>"
            })
        },
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("demo-paper", "paper", @dataset, scope)

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "post1", "title" => "A Post"},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("post1", "post", @dataset, scope)

    media = put_media!(ws, proj)

    # No section share active — proves item links are independent.
    Application.delete_env(:barkpark, :shares)

    %{
      conn: conn,
      ws: ws,
      proj: proj,
      ws_b: ws_b,
      proj_b: proj_b,
      scope_str: "#{ws.slug}/#{proj.slug}/#{@dataset}",
      scope_str_b: "#{ws_b.slug}/#{proj_b.slug}/#{@dataset}",
      media: media
    }
  end

  # A nil-workspace HOST/platform admin token (RequireAdmin admits [admin]).
  # There is no create_token arg for a nil workspace once the default workspace is
  # seeded, so insert the row directly.
  defp host_admin_token!(raw) do
    %ApiToken{}
    |> ApiToken.changeset(%{
      token_hash: ApiToken.hash_token(raw),
      label: "sl-host",
      dataset: @dataset,
      permissions: ["read", "write", "admin"],
      workspace_id: nil
    })
    |> Repo.insert!()
  end

  # Create a ShareLink row directly in a workspace's scope (the victim link the
  # cross-tenant probes target), returning the persisted %ShareLink{}.
  defp seed_link!(ws, proj, ref_id) do
    {:ok, {_raw, link}} =
      Links.create(%{
        workspace_id: ws.id,
        project_id: proj.id,
        dataset: @dataset,
        kind: "doc",
        ref_type: "post",
        ref_id: ref_id,
        access: "read"
      })

    link
  end

  defp put_media!(ws, proj) do
    name = "link-#{System.unique_integer([:positive])}.png"
    rel = "uploads/share-link-test/#{name}"
    full = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "PNG-BYTES")
    on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

    %MediaFile{}
    |> MediaFile.changeset(%{
      filename: name,
      original_name: name,
      path: rel,
      mime_type: "image/png",
      size: 9,
      dataset: @dataset,
      workspace_id: ws.id,
      project_id: proj.id
    })
    |> Repo.insert!()
  end

  # A blob whose STORED mime_type is browser-executable, inserted raw to bypass
  # the ingest changeset's neutralize step — this is a legacy row (uploaded before
  # the neutralize changeset existed) that the backfill migration also targets.
  # Proves the anonymous serve edge neutralizes it even if the stored mime is bad.
  defp put_dangerous_media!(ws, proj) do
    name = "evil-#{System.unique_integer([:positive])}.svg"
    rel = "uploads/share-link-test/#{name}"
    full = Media.file_path(rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|)
    on_exit(fn -> File.rm_rf(Path.dirname(full)) end)

    Repo.insert!(%MediaFile{
      filename: name,
      original_name: name,
      path: rel,
      mime_type: "image/svg+xml",
      size: 60,
      dataset: @dataset,
      workspace_id: ws.id,
      project_id: proj.id
    })
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

  defp host(conn),
    do:
      conn
      |> put_req_header("authorization", "Bearer #{@host}")
      |> put_req_header("content-type", "application/json")

  defp mint(conn, body),
    do: conn |> admin() |> post("/v1/shares/links", body) |> json_response(201)

  # ── object-authz: cross-tenant confinement (SA-S1) ─────────────────────────
  #
  # RED-WITHOUT-FIX: on origin/main `Links.revoke/1` is a bare unscoped
  # `Repo.get(ShareLink, id)` and the controller resolves the workspace from the
  # CLIENT-supplied `scope` slug — so a workspace-A admin token could revoke,
  # list (recovering the raw `/s/<token>` credential), and mint against a
  # workspace-B item. Reverting the scoped resolve / `ensure_token_scope` guard
  # REDs each `not_found` / `revoked_at stays nil` assertion below.

  test "a ws-A admin CANNOT revoke a ws-B link (cross-tenant write IDOR closed)", %{
    conn: conn,
    ws_b: ws_b,
    proj_b: proj_b
  } do
    victim = seed_link!(ws_b, proj_b, "victim-post")

    resp = conn |> admin() |> delete("/v1/shares/links/#{victim.id}")
    assert resp.status == 404

    # The victim row is untouched — never revoked.
    assert Repo.get!(Barkpark.Sharing.ShareLink, victim.id).revoked_at == nil
  end

  test "a same-workspace admin revoke succeeds and stamps revoked_at", %{
    conn: conn,
    ws: ws,
    proj: proj
  } do
    link = seed_link!(ws, proj, "own-post")

    body = conn |> admin() |> delete("/v1/shares/links/#{link.id}") |> json_response(200)
    assert body["revoked"] == true

    assert Repo.get!(Barkpark.Sharing.ShareLink, link.id).revoked_at != nil
  end

  test "a nil-workspace HOST admin still revokes ANY workspace's link", %{
    conn: conn,
    ws_b: ws_b,
    proj_b: proj_b
  } do
    link = seed_link!(ws_b, proj_b, "host-target-post")

    body = conn |> host() |> delete("/v1/shares/links/#{link.id}") |> json_response(200)
    assert body["revoked"] == true

    assert Repo.get!(Barkpark.Sharing.ShareLink, link.id).revoked_at != nil
  end

  test "a ws-A admin listing a ws-B item leaks NO link / raw token", %{
    conn: conn,
    ws_b: ws_b,
    proj_b: proj_b,
    scope_str_b: scope_b
  } do
    _victim = seed_link!(ws_b, proj_b, "list-victim")

    resp =
      conn
      |> admin()
      |> get("/v1/shares/links?scope=#{scope_b}&kind=doc&ref_type=post&ref_id=list-victim")

    assert resp.status == 404
    # Absolutely no live share credential recovered.
    refute resp.resp_body =~ "/s/"
  end

  test "a same-workspace admin list DOES return the item's link", %{
    conn: conn,
    ws: ws,
    proj: proj,
    scope_str: scope
  } do
    link = seed_link!(ws, proj, "list-own")

    body =
      conn
      |> admin()
      |> get("/v1/shares/links?scope=#{scope}&kind=doc&ref_type=post&ref_id=list-own")
      |> json_response(200)

    ids = Enum.map(body["links"], & &1["id"])
    assert link.id in ids
  end

  test "a ws-A admin CANNOT mint against a ws-B scope (cross-tenant re-share closed)", %{
    conn: conn,
    scope_str_b: scope_b
  } do
    resp =
      conn
      |> admin()
      |> post("/v1/shares/links", %{
        scope: scope_b,
        kind: "doc",
        ref_type: "post",
        ref_id: "post1"
      })

    assert resp.status == 404
  end

  test "a same-workspace admin mint still succeeds", %{conn: conn, scope_str: scope} do
    body = mint(conn, %{scope: scope, kind: "doc", ref_type: "post", ref_id: "post1"})
    assert is_binary(body["token"])
    assert String.contains?(body["url"], "/s/")
  end

  # ── paper link ────────────────────────────────────────────────────────────

  test "a PAPER link renders the paper at /s/:token (no section share)", %{
    conn: conn,
    scope_str: scope
  } do
    %{"token" => token, "url" => url} =
      mint(conn, %{scope: scope, kind: "doc", ref_type: "paper", ref_id: "demo-paper"})

    # url is absolute on the advertised share host (LAN IP in test) or relative.
    assert String.ends_with?(url, "/s/#{token}")

    # P5 (Scoped-by-URL): the short link 302s to the CANONICAL scoped
    # reader with the token riding as ?share= — and following it serves
    # the paper anonymously through RequireShareScope's item-token arm.
    resp = get(build_conn(), "/s/#{token}")
    target = redirected_to(resp, 302)
    assert target =~ ~r{^/w/[^/]+/p/[^/]+/papers/demo-paper\?share=}

    followed = get(build_conn(), target)
    assert followed.status == 200
    assert followed.resp_body =~ "Shared via a direct link"
  end

  # preview-contract pc-w2 (charter A8/A13): when the link's tenancy scope no
  # longer resolves, `/s/:token` falls back to the STATIC paper render — that
  # path must (a) not KeyError on the shared template's backlinks/driven-tasks
  # sections and (b) still carry the branded social-share head, because a share
  # link IS the sharing flow.
  test "a PAPER link static fallback renders scoped blocks instead of stale cache",
       %{conn: conn, scope_str: scope, ws: ws, proj: proj} do
    %{"token" => token} =
      mint(conn, %{scope: scope, kind: "doc", ref_type: "paper", ref_id: "demo-paper"})

    # Same referenced id in another tenant. The static fallback must bind label
    # resolution to the LINK's still-valid scope, not global/default scope.
    other_ws = create_workspace!("link-static-other-ws")
    other_proj = create_project!(other_ws, "link-static-other-proj")
    other_scope = [workspace_id: other_ws.id, project_id: other_proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        other_scope
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "post1", "title" => "Other Tenant Post"},
        @dataset,
        other_scope
      )

    {:ok, _} = Content.publish_document("post1", "post", @dataset, other_scope)

    {:ok, paper} =
      Content.get_document(
        "demo-paper",
        "paper",
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    blocks = [
      %{
        "id" => "title",
        "type" => "heading",
        "role" => "title",
        "level" => 1,
        "text" => "Static Block Authority"
      },
      %{
        "id" => "ref",
        "type" => "field-reference",
        "label" => "Linked post",
        "refType" => "post",
        "value" => "post1"
      }
    ]

    stale_content =
      paper.content
      |> Map.put("blocks", blocks)
      |> Map.put("body_html", "<p>STALE STATIC CACHE</p>")

    paper
    |> Document.changeset(%{"content" => stale_content, "rev" => "share-static-stale"})
    |> Repo.update!()

    # Deterministically force the redirect lookup to miss while retaining the
    # link's real workspace/project ids for the static reader scope.
    resp =
      build_conn()
      |> Plug.Conn.put_private(:share_link_tenancy, MissingRedirectTenancy)
      |> get("/s/#{token}")

    assert resp.status == 200
    assert resp.resp_body =~ "Static Block Authority"
    assert resp.resp_body =~ "A Post"
    refute resp.resp_body =~ "Other Tenant Post"
    refute resp.resp_body =~ "STALE STATIC CACHE"
    # The share head: og/twitter tags with the paper title and (no manifest
    # image on this classic doc) the branded default card.
    assert resp.resp_body =~ ~s(property="og:title" content="Static Block Authority")
    assert resp.resp_body =~ ~s(property="og:site_name" content="Barkpark")
    assert resp.resp_body =~ "/images/og-default.jpg"
    assert resp.resp_body =~ ~s(name="twitter:card" content="summary_large_image")
  end

  test "JSON-API errors use the canonical envelope (code + request_id)", %{conn: conn} do
    # Missing scope/kind on mint → 422. Was a bare `%{"error" => "…required"}`;
    # now a keyable code + the human message + a request_id.
    bad = conn |> admin() |> post("/v1/shares/links", %{kind: "doc"})
    body = json_response(bad, 422)
    assert body["error"]["code"] == "validation_failed"
    assert is_binary(body["error"]["message"])
    assert is_binary(body["error"]["request_id"])

    # Revoking a nonexistent link → 404 canonical envelope (a valid-format UUID
    # that isn't in the table).
    nf = conn |> admin() |> delete("/v1/shares/links/11111111-1111-1111-1111-111111111111")
    nfb = json_response(nf, 404)
    assert nfb["error"]["code"] == "not_found"
    assert nfb["error"]["message"] == "link not found"
    assert is_binary(nfb["error"]["request_id"])

    # A malformed (non-UUID) link id is a clean 404, not an Ecto CastError 500 —
    # Links.revoke queries ShareLink by :binary_id and now guards the cast.
    garbage = conn |> admin() |> delete("/v1/shares/links/not-a-uuid")
    assert json_response(garbage, 404)["error"]["code"] == "not_found"
  end

  # ── doc link ──────────────────────────────────────────────────────────────

  test "a DOC link returns the document JSON at /s/:token", %{conn: conn, scope_str: scope} do
    %{"token" => token} =
      mint(conn, %{scope: scope, kind: "doc", ref_type: "post", ref_id: "post1"})

    body = get(build_conn(), "/s/#{token}") |> json_response(200)
    assert body["_id"] == "post1"
    assert body["title"] == "A Post"
  end

  # Wiring proof: `/s/:token` is an ANONYMOUS read — the doc is rendered through
  # Envelope.render(doc, schema, CallerContext.from_conn(conn)), so a `private`
  # field is DROPPED before the public link can serve it.
  test "a DOC link redacts a private field for the anonymous reader",
       %{conn: conn, scope_str: scope_str, ws: ws, proj: proj} do
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

    %{"token" => token} =
      mint(conn, %{scope: scope_str, kind: "doc", ref_type: "post", ref_id: "postsec"})

    body = get(build_conn(), "/s/#{token}") |> json_response(200)
    assert body["_id"] == "postsec"
    assert body["title"] == "Secret Post"
    refute Map.has_key?(body, "ssn")
    refute body |> Jason.encode!() |> String.contains?("SSN-777")
  end

  # ── media link ──────────────────────────────────────────────────────────

  test "a MEDIA link serves the file bytes at /s/:token", %{
    conn: conn,
    scope_str: scope,
    media: media
  } do
    %{"token" => token} = mint(conn, %{scope: scope, kind: "media", ref_id: media.id})

    resp = get(build_conn(), "/s/#{token}")
    assert resp.status == 200
    assert resp.resp_body == "PNG-BYTES"

    # A normal image keeps its honest type + inline, plus the nosniff pin.
    assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(resp, "content-disposition") == ["inline"]
    assert [ct] = get_resp_header(resp, "content-type")
    assert ct =~ "image/png"
  end

  test "a MEDIA link to a legacy dangerous blob is neutralized (nosniff + attachment)", %{
    conn: conn,
    scope_str: scope,
    ws: ws,
    proj: proj
  } do
    evil = put_dangerous_media!(ws, proj)
    %{"token" => token} = mint(conn, %{scope: scope, kind: "media", ref_id: evil.id})

    resp = get(build_conn(), "/s/#{token}")

    assert resp.status == 200
    # Served, but as a non-executable download — never inline image/svg+xml on
    # the API origin (the stored-XSS vector on this anonymous path).
    assert get_resp_header(resp, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(resp, "content-disposition") == ["attachment"]
    assert [ct] = get_resp_header(resp, "content-type")
    refute ct =~ "image/svg+xml"
    assert ct =~ "application/octet-stream"
  end

  # ── revoke + invalid ──────────────────────────────────────────────────────

  test "revoking a link makes /s/:token 404", %{conn: conn, scope_str: scope} do
    %{"token" => token, "link" => link} =
      mint(conn, %{scope: scope, kind: "doc", ref_type: "post", ref_id: "post1"})

    assert get(build_conn(), "/s/#{token}").status == 200

    assert conn
           |> admin()
           |> delete("/v1/shares/links/#{link["id"]}")
           |> json_response(200)
           |> Map.get("revoked") == true

    assert get(build_conn(), "/s/#{token}").status == 404
  end

  test "a garbage token is 404", %{} do
    assert get(build_conn(), "/s/not-a-real-token").status == 404
  end

  # ── admin gating + validation ─────────────────────────────────────────────

  test "minting / listing / revoking are admin-only", %{conn: conn, scope_str: scope} do
    body = %{scope: scope, kind: "doc", ref_type: "post", ref_id: "post1"}
    assert conn |> post("/v1/shares/links", body) |> Map.get(:status) == 401
    assert conn |> junior() |> post("/v1/shares/links", body) |> Map.get(:status) == 403

    assert conn
           |> junior()
           |> get("/v1/shares/links?scope=#{scope}&kind=doc&ref_type=post&ref_id=post1")
           |> Map.get(:status) == 403

    assert conn |> junior() |> delete("/v1/shares/links/x") |> Map.get(:status) == 403
  end

  test "minting a link for a non-existent item is 422", %{conn: conn, scope_str: scope} do
    resp =
      conn
      |> admin()
      |> post("/v1/shares/links", %{scope: scope, kind: "doc", ref_type: "post", ref_id: "ghost"})

    assert resp.status == 422
  end

  test "list shows an item's links (no token/hash)", %{conn: conn, scope_str: scope} do
    mint(conn, %{scope: scope, kind: "doc", ref_type: "post", ref_id: "post1"})

    list =
      conn
      |> admin()
      |> get("/v1/shares/links?scope=#{scope}&kind=doc&ref_type=post&ref_id=post1")
      |> json_response(200)

    assert length(list["links"]) == 1
    refute Map.has_key?(hd(list["links"]), "token_hash")
    refute Map.has_key?(hd(list["links"]), "token")
  end
end
