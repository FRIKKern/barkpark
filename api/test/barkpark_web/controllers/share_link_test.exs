defmodule BarkparkWeb.ShareLinkTest do
  @moduledoc """
  P7 — ITEM (per-document) share links: mint → `/s/:token` resolves the ONE
  bound item (paper / doc / media), scoped to the LINK's own workspace and
  INDEPENDENT of any section share. Revocable; admin-only management.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Media}
  alias Barkpark.Content.Document
  alias Barkpark.Media.Storage.MediaFile
  alias Barkpark.Repo
  alias Barkpark.Sharing.ShareLink

  import Ecto.Query, only: [from: 2]

  import Barkpark.TenancyFixtures

  @dataset "production"
  @admin "share-link-admin"
  @junior "share-link-junior"

  defmodule MissingRedirectTenancy do
    def get_workspace_by_id(_id), do: nil
    def get_project_by_id(_id), do: nil
  end

  setup %{conn: conn} do
    # E3 tag registry: the fixture weighted tags (fixture-tag-N) these tests
    # publish must resolve to PUBLISHED type:tag docs in the dataset scope.
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, admin_tok} = Auth.create_token(@admin, "sl-admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@junior, "sl-junior", @dataset, ["read", "write"])

    ws = create_workspace!("link-ws")

    # FIXTURE REPAIR (arpss-w8): `Auth.create_token/4` resolves
    # `workspace_id || default_workspace_id()`, so @admin's home membership lands
    # in the seeded `default` workspace, while `create_workspace!/1` writes NO
    # membership at all — the admin was a total STRANGER to the workspace these
    # tests act on. That is a fixture that never expressed tenancy, not a
    # contract saying a stranger may manage another tenant's links. @junior
    # needs nothing: `:require_admin` stops it upstream.
    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, admin_tok.id, "admin")
    proj = create_project!(ws, "link-proj")
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
      admin_tok: admin_tok,
      proj: proj,
      scope_str: "#{ws.slug}/#{proj.slug}/#{@dataset}",
      media: media
    }
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

  defp attacker(conn, raw),
    do:
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")

  defp mint(conn, body),
    do: conn |> admin() |> post("/v1/shares/links", body) |> json_response(201)

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
      |> Map.put("style", "article-wide")
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
    assert resp.resp_body =~ "bp-paper-article"
    refute resp.resp_body =~ "bp-paper-article-wide"
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

  # ── arpss-w8: cross-tenant confinement ────────────────────────────────────
  #
  # The test just above ("no token/hash") refutes two absent MAP KEYS and passes
  # on the LEAKING controller, because the secret rides in `url`. It is left in
  # place as this wave's own resident failure mode, and it is why everything
  # below asserts on the SERIALIZED BODY (`resp_body =~`) instead.
  describe "tenancy confinement on /v1/shares/links" do
    # The attacker is the shape the predicate choice turns on: an admin of its
    # OWN workspace A, built the way a real install builds one
    # (`Auth.create_token/5`, which writes the home membership), PLUS a REAL
    # plain `member` membership in the victim workspace B. A total stranger to B
    # is denied under BOTH candidate predicates and would prove nothing.
    setup %{ws: ws} do
      raw = "sl-attacker-#{System.unique_integer([:positive])}"
      ws_a = create_workspace!("attacker-ws-#{System.unique_integer([:positive])}")

      {:ok, actor} =
        Auth.create_token(raw, "sl-attacker", @dataset, ["read", "write", "admin"], ws_a.id)

      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, actor.id, "member")

      # PRECONDITION, asserted inline so the predicate choice is provably
      # load-bearing: this actor IS a member of B and DOES pass authorize/3
      # (whose api_token arm ORs in the token's GLOBAL permissions), and is NOT
      # a workspace admin of B. Swap the gate to authorize/3 and these tests go
      # green on a leaking controller.
      assert Barkpark.Tenancy.Auth.membership_role(actor, ws.id) == "member"
      assert Barkpark.Tenancy.Auth.authorize(actor, ws.id, :admin) == :ok
      refute Barkpark.Tenancy.Auth.workspace_admin?(actor, ws.id)

      %{attacker_raw: raw, attacker: actor}
    end

    test "POSITIVE CONTROL: the legitimate own-workspace 200 body DOES carry the raw token",
         %{conn: conn, scope_str: scope} do
      %{"token" => raw} =
        mint(conn, %{scope: scope, kind: "doc", ref_type: "post", ref_id: "post1"})

      resp =
        conn
        |> admin()
        |> get("/v1/shares/links?scope=#{scope}&kind=doc&ref_type=post&ref_id=post1")

      # Without this control, `refute body =~ raw` is green on ANY denial body
      # and proves nothing about serialization.
      assert resp.status == 200
      assert resp.resp_body =~ raw
      assert resp.resp_body =~ "/s/#{raw}"
    end

    test "LEAK CLOSED — list: a foreign admin never sees B's raw token in the body", %{
      conn: conn,
      scope_str: scope,
      attacker_raw: raw_actor
    } do
      %{"token" => raw} =
        mint(conn, %{scope: scope, kind: "doc", ref_type: "post", ref_id: "post1"})

      resp =
        conn
        |> attacker(raw_actor)
        |> get("/v1/shares/links?scope=#{scope}&kind=doc&ref_type=post&ref_id=post1")

      # ORDER IS LOAD-BEARING: with the status assert first, deleting the
      # confinement reds on the STATUS and never demonstrates the credential
      # leak. Assert only on the raw token and the bare "/s/" — never a host
      # prefix (`Sharing.share_link_base/0` is a LAN IP locally, nil in CI).
      refute resp.resp_body =~ raw
      refute resp.resp_body =~ "/s/"
      assert resp.status == 403
      assert json_response(resp, 403)["error"]["code"] == "forbidden"
    end

    test "LEAK CLOSED — mint: a foreign admin cannot manufacture an edit credential in B", %{
      conn: conn,
      scope_str: scope,
      ws: ws,
      attacker_raw: raw_actor
    } do
      before = Repo.aggregate(from(l in ShareLink, where: l.workspace_id == ^ws.id), :count)

      resp =
        conn
        |> attacker(raw_actor)
        |> post("/v1/shares/links", %{
          scope: scope,
          kind: "doc",
          ref_type: "post",
          ref_id: "post1",
          access: "edit"
        })

      refute resp.resp_body =~ "/s/"
      assert resp.status == 403
      assert json_response(resp, 403)["error"]["code"] == "forbidden"

      # The gate sits BEFORE get_project/2 and before ensure_item_exists, so no
      # row is written and the item-existence oracle is closed in its loudest
      # (201) form too.
      assert Repo.aggregate(from(l in ShareLink, where: l.workspace_id == ^ws.id), :count) ==
               before
    end

    test "LEAK CLOSED — revoke: a foreign admin gets a 404 byte-identical to a missing row", %{
      conn: conn,
      scope_str: scope,
      attacker_raw: raw_actor
    } do
      %{"link" => %{"id" => link_id}, "token" => raw} =
        mint(conn, %{scope: scope, kind: "doc", ref_type: "post", ref_id: "post1"})

      foreign = conn |> attacker(raw_actor) |> delete("/v1/shares/links/#{link_id}")
      missing = conn |> attacker(raw_actor) |> delete("/v1/shares/links/#{Ecto.UUID.generate()}")

      refute foreign.resp_body =~ raw
      assert foreign.status == 404
      assert missing.status == 404

      # Byte-identity modulo the ONE per-request value in the envelope: the
      # request_id, which Plug.RequestId regenerates per connection. Everything
      # else — code, message, hint — must match, and it does because both arms
      # reach the SAME `not_found_json(conn, "link not found")` call site.
      assert blank_request_id(foreign) == blank_request_id(missing)
      assert json_response(foreign, 404)["error"]["message"] == "link not found"

      # ...and the row survives the denial: a 404 that silently revoked would be
      # the same cross-tenant write in disguise.
      refute is_nil(Repo.get(ShareLink, link_id))
      assert is_nil(Repo.get(ShareLink, link_id).revoked_at)
    end

    test "a non-castable link id is a denial, never a 500", %{
      conn: conn,
      attacker_raw: raw_actor
    } do
      resp = conn |> attacker(raw_actor) |> delete("/v1/shares/links/not-a-uuid")
      assert resp.status == 404

      admin_resp = conn |> admin() |> delete("/v1/shares/links/not-a-uuid")
      assert admin_resp.status == 404
    end

    test "HOST-ADMIN PRESERVED: a real-install admin does list -> show -> revoke end to end", %{
      conn: conn,
      scope_str: scope
    } do
      # The actor here is the setup's @admin, minted by `Auth.create_token/4`
      # and granted its membership the way `create_token/5` grants one — never a
      # hand-inserted `%ApiToken{workspace_id: nil}`, a shape `create_token` can
      # never produce.
      %{"link" => %{"id" => link_id}, "token" => raw} =
        mint(conn, %{scope: scope, kind: "doc", ref_type: "post", ref_id: "post1"})

      listed =
        conn
        |> admin()
        |> get("/v1/shares/links?scope=#{scope}&kind=doc&ref_type=post&ref_id=post1")
        |> json_response(200)

      assert Enum.any?(listed["links"], &(&1["id"] == link_id))
      assert Enum.any?(listed["links"], &(&1["url"] =~ "/s/#{raw}"))

      served = get(build_conn(), "/s/#{raw}")
      assert served.status in [200, 302]

      revoked = conn |> admin() |> delete("/v1/shares/links/#{link_id}") |> json_response(200)
      assert revoked["revoked"] == true
    end
  end

  # Blank the ONE per-connection value in the v1 error envelope so two bodies
  # can be compared as bytes.
  defp blank_request_id(%Plug.Conn{} = conn) do
    case Jason.decode!(conn.resp_body) do
      %{"error" => %{"request_id" => id}} when is_binary(id) ->
        String.replace(conn.resp_body, id, "<request_id>")

      _ ->
        conn.resp_body
    end
  end
end
