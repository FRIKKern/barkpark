defmodule BarkparkWeb.ScimParamCoercionTest do
  @moduledoc """
  Fails-before regression guard for `wbqs-api-scim-param-coercion`.

  `ScimGroupsController.parse_display_name_filter/1` and
  `ScimUsersController.parse_username_filter/1` only matched `nil` and
  `is_binary` clauses. An IdP sending `?filter[]=x` — which `Plug.Conn.Query`
  parses to a LIST, not a binary — tripped `FunctionClauseError` -> HTTP 500.
  Each controller now has a trailing catch-all clause that degrades a
  non-binary filter to the no-filter path instead of crashing.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Scim, Tenancy}

  defp org_with_token(slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: "WS"})
    {:ok, _ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, {token, _}} = Scim.mint_token(org.id, "test")
    token
  end

  defp scim(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  describe "list-shaped ?filter[]= does not 500" do
    test "GET /scim/v2/Groups?filter[]=x stays not-500 and returns an empty result" do
      token = org_with_token("scimg")

      resp = scim(token) |> get("/scim/v2/Groups", %{"filter" => ["x"]})

      refute resp.status == 500
      body = json_response(resp, 200)
      assert body["totalResults"] == 0
    end

    test "GET /scim/v2/Users?filter[]=x stays not-500 and returns an empty result" do
      token = org_with_token("scimu")

      resp = scim(token) |> get("/scim/v2/Users", %{"filter" => ["x"]})

      refute resp.status == 500
      body = json_response(resp, 200)
      assert body["totalResults"] == 0
    end
  end
end
