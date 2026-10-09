defmodule BarkparkWeb.PreviewLinkDatasetBoundListRevokeTest do
  @moduledoc """
  task-4ad625842939ae8f — the same composite-scope `dataset_bound` bypass
  `ShareLinkController.list/2`/`revoke/2` had, reproduced and fixed on
  `PreviewLinkController`'s siblings. See
  `ShareLinkDatasetBoundListRevokeTest`'s moduledoc for why `list`'s denial is
  an explicit 403 `dataset_not_bound` (the caller named the dataset) while
  `revoke`'s folds into the existing `{:error, :not_found}` collapse (the
  caller names only an opaque id).
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "production"

  setup %{conn: conn} do
    suffix = System.unique_integer([:positive])
    ws = Barkpark.TenancyFixtures.create_workspace!("pldblr-ws-#{suffix}")
    proj = Barkpark.TenancyFixtures.create_project!(ws, "default")
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        "staging",
        scope
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts.pldblr-post", "title" => "T"},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "drafts.pldblr-staging-post", "title" => "T"},
        "staging",
        scope
      )

    bound_raw = "pldblr-bound-admin-#{suffix}"

    {:ok, bound_tok} =
      Auth.create_token(
        bound_raw,
        "pldblr-bound-admin",
        "staging",
        ["read", "write", "admin"],
        nil,
        dataset_bound: true
      )

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, bound_tok.id, "admin")

    unbound_raw = "pldblr-unbound-admin-#{suffix}"

    {:ok, unbound_tok} =
      Auth.create_token(unbound_raw, "pldblr-unbound-admin", @dataset, ["read", "write", "admin"])

    {:ok, _} = Tenancy.Auth.create_membership(ws.id, unbound_tok.id, "admin")

    %{
      conn: conn,
      production_scope: "#{ws.slug}/#{proj.slug}/#{@dataset}",
      staging_scope: "#{ws.slug}/#{proj.slug}/staging",
      bound_raw: bound_raw,
      unbound_raw: unbound_raw
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
    test "a staging-bound admin token listing the PRODUCTION scope gets 403 dataset_not_bound",
         %{conn: conn, production_scope: production_scope, bound_raw: raw} do
      resp =
        conn
        |> bearer(raw)
        |> get(
          "/v1/shares/preview-links?scope=#{URI.encode_www_form(production_scope)}&ref_type=post&doc_id=drafts.pldblr-post"
        )

      assert resp.status == 403

      assert Jason.decode!(resp.resp_body)["error"]["reason"] == "dataset_not_bound",
             "expected the dataset-binding refusal, got: #{resp.resp_body}"
    end

    test "the same staging-bound admin token CAN list its own bound dataset", %{
      conn: conn,
      staging_scope: staging_scope,
      bound_raw: raw
    } do
      link_id = mint_link!(conn, raw, staging_scope, "drafts.pldblr-staging-post")

      resp =
        conn
        |> bearer(raw)
        |> get(
          "/v1/shares/preview-links?scope=#{URI.encode_www_form(staging_scope)}&ref_type=post&doc_id=drafts.pldblr-staging-post"
        )
        |> json_response(200)

      assert Enum.any?(resp["links"], &(&1["id"] == link_id))
    end

    test "an unbound admin token still lists across datasets in its workspace, unchanged", %{
      conn: conn,
      production_scope: production_scope,
      unbound_raw: raw
    } do
      link_id = mint_link!(conn, raw, production_scope, "drafts.pldblr-post")

      resp =
        conn
        |> bearer(raw)
        |> get(
          "/v1/shares/preview-links?scope=#{URI.encode_www_form(production_scope)}&ref_type=post&doc_id=drafts.pldblr-post"
        )
        |> json_response(200)

      assert Enum.any?(resp["links"], &(&1["id"] == link_id))
    end
  end

  describe "DELETE /v1/shares/preview-links/:id (revoke)" do
    test "a staging-bound admin token revoking a PRODUCTION-dataset link gets the SAME 404 as an unknown id",
         %{
           conn: conn,
           production_scope: production_scope,
           unbound_raw: unbound_raw,
           bound_raw: raw
         } do
      link_id = mint_link!(conn, unbound_raw, production_scope, "drafts.pldblr-post")

      resp_foreign_dataset = conn |> bearer(raw) |> delete("/v1/shares/preview-links/#{link_id}")

      resp_unknown_id =
        conn |> bearer(raw) |> delete("/v1/shares/preview-links/#{Ecto.UUID.generate()}")

      assert resp_foreign_dataset.status == resp_unknown_id.status
      assert resp_foreign_dataset.status == 404

      strip_request_id = fn body ->
        body |> Jason.decode!() |> put_in(["error", "request_id"], nil)
      end

      assert strip_request_id.(resp_foreign_dataset.resp_body) ==
               strip_request_id.(resp_unknown_id.resp_body)
    end

    test "the same staging-bound admin token CAN revoke a link in its own bound dataset", %{
      conn: conn,
      staging_scope: staging_scope,
      bound_raw: raw
    } do
      link_id = mint_link!(conn, raw, staging_scope, "drafts.pldblr-staging-post")

      resp =
        conn
        |> bearer(raw)
        |> delete("/v1/shares/preview-links/#{link_id}")
        |> json_response(200)

      assert resp["revoked"] == true
    end

    test "an unbound admin token still revokes across datasets in its workspace, unchanged", %{
      conn: conn,
      production_scope: production_scope,
      unbound_raw: raw
    } do
      link_id = mint_link!(conn, raw, production_scope, "drafts.pldblr-post")

      resp =
        conn
        |> bearer(raw)
        |> delete("/v1/shares/preview-links/#{link_id}")
        |> json_response(200)

      assert resp["revoked"] == true
    end
  end
end
