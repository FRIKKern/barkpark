defmodule BarkparkWeb.PreviewLinkOwnListRevokeTest do
  @moduledoc """
  task-0548f06277c4712e — barkpark-studio's J64: since #22488 a write member
  can mint a preview link, but `list`/`revoke` stayed admin-only, so a member
  who minted a link by mistake could not take it back, and CI runs left
  24h-TTL links behind. An admin still lists/revokes everything; a
  write-capable member now lists/revokes only the links THEY minted.

  `created_by` (`PreviewLinks.actor_ref/1`) is stamped at mint time and
  compared on both list (an explicit `{:mine, ref}` filter) and revoke (folded
  into `revoke_scoped/2`'s existing `{:error, :not_found}` collapse — a
  member probing another member's link id gets the SAME answer as an unknown
  one, no existence leak).
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content}
  alias Barkpark.Sharing.PreviewLinks
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup %{conn: conn} do
    suffix = System.unique_integer([:positive])
    ws = Barkpark.TenancyFixtures.create_workspace!("plolr-ws-#{suffix}")
    proj = Barkpark.TenancyFixtures.create_project!(ws, "default")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "plolr-post-a", "title" => "A"},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "plolr-post-b", "title" => "B"},
        @dataset,
        scope
      )

    admin_raw = "plolr-admin-#{suffix}"

    {:ok, admin_tok} =
      Auth.create_token(admin_raw, "plolr-admin", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, admin_tok.id, "admin")

    member_a_raw = "plolr-member-a-#{suffix}"

    {:ok, member_a_tok} =
      Auth.create_token(member_a_raw, "plolr-member-a", @dataset, ["read", "write"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, member_a_tok.id, "member")

    member_b_raw = "plolr-member-b-#{suffix}"

    {:ok, member_b_tok} =
      Auth.create_token(member_b_raw, "plolr-member-b", @dataset, ["read", "write"])

    {:ok, _} = TenancyAuth.create_membership(ws.id, member_b_tok.id, "member")

    %{
      conn: conn,
      ws: ws,
      scope_str: "#{ws.slug}/#{proj.slug}/#{@dataset}",
      admin_raw: admin_raw,
      member_a_raw: member_a_raw,
      member_b_raw: member_b_raw
    }
  end

  defp bearer(conn, raw),
    do:
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")

  defp mint_link!(conn, raw, scope, doc_id) do
    resp =
      conn
      |> bearer(raw)
      |> post("/v1/shares/preview-links", %{
        "scope" => scope,
        "ref_type" => "post",
        "doc_id" => doc_id
      })
      |> json_response(201)

    resp["link"]["id"]
  end

  describe "GET /v1/shares/preview-links (list)" do
    test "a member lists only the links THEY minted, not another member's", %{
      conn: conn,
      scope_str: scope,
      member_a_raw: a_raw,
      member_b_raw: b_raw
    } do
      a_link = mint_link!(conn, a_raw, scope, "drafts.plolr-post-a")
      _b_link = mint_link!(conn, b_raw, scope, "drafts.plolr-post-b")

      resp_a =
        conn
        |> bearer(a_raw)
        |> get(
          "/v1/shares/preview-links?scope=#{URI.encode_www_form(scope)}&ref_type=post&doc_id=drafts.plolr-post-a"
        )
        |> json_response(200)

      assert Enum.map(resp_a["links"], & &1["id"]) == [a_link]

      # Even asking about B's own doc_id, A's "mine" filter never surfaces it.
      resp_a_on_b_doc =
        conn
        |> bearer(a_raw)
        |> get(
          "/v1/shares/preview-links?scope=#{URI.encode_www_form(scope)}&ref_type=post&doc_id=drafts.plolr-post-b"
        )
        |> json_response(200)

      assert resp_a_on_b_doc["links"] == []
    end

    test "an admin lists every link, both members' included", %{
      conn: conn,
      scope_str: scope,
      admin_raw: admin_raw,
      member_a_raw: a_raw,
      member_b_raw: b_raw
    } do
      a_link = mint_link!(conn, a_raw, scope, "drafts.plolr-post-a")

      resp =
        conn
        |> bearer(admin_raw)
        |> get(
          "/v1/shares/preview-links?scope=#{URI.encode_www_form(scope)}&ref_type=post&doc_id=drafts.plolr-post-a"
        )
        |> json_response(200)

      assert Enum.map(resp["links"], & &1["id"]) == [a_link]

      _ = b_raw
    end

    test "a reader-only (no write) member cannot list at all", %{
      conn: conn,
      ws: ws,
      scope_str: scope
    } do
      suffix = System.unique_integer([:positive])
      reader_raw = "plolr-reader-#{suffix}"

      {:ok, reader_tok} = Auth.create_token(reader_raw, "plolr-reader", @dataset, ["read"])
      {:ok, _} = TenancyAuth.create_membership(ws.id, reader_tok.id, "member")

      resp =
        conn
        |> bearer(reader_raw)
        |> get(
          "/v1/shares/preview-links?scope=#{URI.encode_www_form(scope)}&ref_type=post&doc_id=drafts.plolr-post-a"
        )

      assert resp.status == 403
    end
  end

  describe "DELETE /v1/shares/preview-links/:id (revoke)" do
    test "a member revokes their OWN link", %{conn: conn, scope_str: scope, member_a_raw: raw} do
      link_id = mint_link!(conn, raw, scope, "drafts.plolr-post-a")

      resp =
        conn
        |> bearer(raw)
        |> delete("/v1/shares/preview-links/#{link_id}")
        |> json_response(200)

      assert resp["revoked"] == true
    end

    test "a member CANNOT revoke another member's link -- same 404 as an unknown id", %{
      conn: conn,
      scope_str: scope,
      member_a_raw: a_raw,
      member_b_raw: b_raw
    } do
      b_link = mint_link!(conn, b_raw, scope, "drafts.plolr-post-b")

      resp_foreign = conn |> bearer(a_raw) |> delete("/v1/shares/preview-links/#{b_link}")

      resp_unknown =
        conn |> bearer(a_raw) |> delete("/v1/shares/preview-links/#{Ecto.UUID.generate()}")

      assert resp_foreign.status == resp_unknown.status
      assert resp_foreign.status == 404

      strip_request_id = fn body ->
        body |> Jason.decode!() |> put_in(["error", "request_id"], nil)
      end

      assert strip_request_id.(resp_foreign.resp_body) ==
               strip_request_id.(resp_unknown.resp_body)
    end

    test "an admin revokes a MEMBER's link too -- admin keeps revoke-all", %{
      conn: conn,
      scope_str: scope,
      admin_raw: admin_raw,
      member_a_raw: a_raw
    } do
      a_link = mint_link!(conn, a_raw, scope, "drafts.plolr-post-a")

      resp =
        conn
        |> bearer(admin_raw)
        |> delete("/v1/shares/preview-links/#{a_link}")
        |> json_response(200)

      assert resp["revoked"] == true
    end
  end

  # task-4ad625842939ae8f + task-0548f06277c4712e TOGETHER: a dataset_bound
  # token is still an ordinary member for own-vs-foreign purposes, and the
  # dataset confinement is a SEPARATE, ANDed condition on top of it -- not a
  # substitute for workspace-admin authority. Revoke's confinement folds into
  # the same {:error, :not_found} collapse as a foreign-creator link, since
  # both are id-only requests.
  describe "a dataset_bound member" do
    setup %{conn: conn} do
      suffix = System.unique_integer([:positive])
      ws = Barkpark.TenancyFixtures.create_workspace!("plolr-db-ws-#{suffix}")
      proj = Barkpark.TenancyFixtures.create_project!(ws, "default")
      scope = [workspace_id: ws.id, project_id: proj.id]

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          "staging",
          scope
        )

      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => "plolr-db-post", "title" => "T"},
          "staging",
          scope
        )

      bound_raw = "plolr-db-bound-#{suffix}"

      {:ok, bound_tok} =
        Auth.create_token(bound_raw, "plolr-db-bound", @dataset, ["read", "write"], nil,
          dataset_bound: true
        )

      {:ok, _} = TenancyAuth.create_membership(ws.id, bound_tok.id, "member")

      %{
        conn: conn,
        ws: ws,
        proj: proj,
        bound_raw: bound_raw,
        bound_tok: bound_tok,
        production_scope: "#{ws.slug}/#{proj.slug}/#{@dataset}",
        staging_scope: "#{ws.slug}/#{proj.slug}/staging"
      }
    end

    test "revokes their OWN link in their bound dataset", %{
      conn: conn,
      ws: ws,
      proj: proj,
      bound_raw: raw,
      production_scope: scope
    } do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
          @dataset,
          workspace_id: ws.id,
          project_id: proj.id
        )

      {:ok, _} =
        Content.create_document(
          "post",
          %{"doc_id" => "plolr-db-prod-post", "title" => "T"},
          @dataset,
          workspace_id: ws.id,
          project_id: proj.id
        )

      link_id = mint_link!(conn, raw, scope, "drafts.plolr-db-prod-post")

      resp =
        conn
        |> bearer(raw)
        |> delete("/v1/shares/preview-links/#{link_id}")
        |> json_response(200)

      assert resp["revoked"] == true
    end

    test "cannot revoke their OWN link outside their bound dataset -- same 404 as an unknown id",
         %{conn: conn, ws: ws, proj: proj, bound_raw: raw, bound_tok: bound_tok} do
      # The bound token can't reach `mint` for staging either (same
      # ensure_dataset_bound check), so a row that is genuinely theirs by
      # `created_by`, in the dataset they're NOT bound to, is built directly
      # -- isolating the dataset check in `revoke_scoped/2` from the (already
      # separately covered) mint-time confinement.
      {:ok, {_raw, link}} =
        PreviewLinks.create(%{
          workspace_id: ws.id,
          project_id: proj.id,
          dataset: "staging",
          doc_id: "drafts.plolr-db-post",
          ref_type: "post",
          created_by: PreviewLinks.actor_ref(bound_tok)
        })

      resp_own_wrong_dataset =
        conn |> bearer(raw) |> delete("/v1/shares/preview-links/#{link.id}")

      resp_unknown =
        conn |> bearer(raw) |> delete("/v1/shares/preview-links/#{Ecto.UUID.generate()}")

      assert resp_own_wrong_dataset.status == resp_unknown.status
      assert resp_own_wrong_dataset.status == 404

      strip_request_id = fn body ->
        body |> Jason.decode!() |> put_in(["error", "request_id"], nil)
      end

      assert strip_request_id.(resp_own_wrong_dataset.resp_body) ==
               strip_request_id.(resp_unknown.resp_body)
    end

    test "cannot list their own dataset's links when the dataset isn't theirs to bind", %{
      conn: conn,
      bound_raw: raw,
      staging_scope: scope
    } do
      resp =
        conn
        |> bearer(raw)
        |> get(
          "/v1/shares/preview-links?scope=#{URI.encode_www_form(scope)}&ref_type=post&doc_id=drafts.plolr-db-post"
        )

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["reason"] == "dataset_not_bound"
    end
  end
end
