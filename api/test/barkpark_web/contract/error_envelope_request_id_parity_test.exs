defmodule BarkparkWeb.Contract.ErrorEnvelopeRequestIdParityTest do
  @moduledoc """
  §9 parity, BY STRING, for every controller PR #13642 routed through
  `BarkparkWeb.ErrorResponse`.

  #13642 replaced ~25 hand-built error bodies (social 6, oidc 6, saml 9,
  sso_routing 1 bare strings; onixedit export 3 `type`-keyed) with the canonical
  emitter. Its own request-level tests assert `is_binary(body["error"]["request_id"])`
  — which a controller that stamped a FRESH uuid, or the string "request_id",
  would also pass. `is_binary` proves a field exists; it does not prove the field
  CORRELATES. Correlation is the entire point of request_id: ops reads
  `x-request-id` off the response (or the load balancer log) and greps it against
  the Logger metadata `Plug.RequestId` stamped on the same request.

  So this file compares the body value to the `x-request-id` RESPONSE HEADER with
  `==`, one representative error path per #13642 controller —
  `BarkparkWeb.Contract.RequestIdTest` already does exactly this for the CORE
  data paths, and these are the SSO/plugin paths that were outside it.

  Scope note (task-bb83570ba0f6f9f2 C3): the five sites below are the #13642 set
  and nothing else. The separate ~90-site census of hand-built code-keyed error
  maps still in `api/lib` belongs to task-8737e2d7ff1884e0 and is NOT proven by
  this file.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content}

  # The one assertion this file exists to make. Named so a failure names the
  # controller and prints both sides, not just `false`.
  defp assert_request_id_parity(resp, site) do
    header =
      case Plug.Conn.get_resp_header(resp, "x-request-id") do
        [rid] -> rid
        other -> flunk("#{site}: expected exactly one x-request-id header, got #{inspect(other)}")
      end

    assert is_binary(header) and header != "",
           "#{site}: the response carries no usable x-request-id header"

    body = Jason.decode!(resp.resp_body)

    assert is_map(body["error"]),
           "#{site}: body is not a §9 error object, got #{inspect(body)}"

    assert body["error"]["request_id"] == header,
           """
           #{site}: error.request_id does NOT equal the x-request-id response header.
           A body id that differs from the header cannot correlate the refusal to a log line.

             header:              #{inspect(header)}
             body.error.request_id: #{inspect(body["error"]["request_id"])}
             body.error.code:       #{inspect(body["error"]["code"])}
           """

    body
  end

  describe "SSO callbacks (#13642 bare-string sites)" do
    test "sso_routing_controller: POST /v1/auth/sso/route without an email", %{conn: conn} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/v1/auth/sso/route", Jason.encode!(%{}))

      assert resp.status == 400
      body = assert_request_id_parity(resp, "sso_routing_controller.ex route/2 fallback")
      assert body["error"]["code"] == "malformed"
    end

    test "oidc_controller: GET callback with no code", %{conn: conn} do
      resp = get(conn, "/v1/auth/oidc/no-such-org/callback?state=s1")

      assert resp.status == 400
      body = assert_request_id_parity(resp, "oidc_controller.ex callback/2 fallback")
      assert body["error"]["code"] == "malformed"
    end

    test "saml_controller: POST ACS with no SAMLResponse", %{conn: conn} do
      resp = post(conn, "/v1/auth/saml/no-such-org/acs", %{})

      assert resp.status == 400
      body = assert_request_id_parity(resp, "saml_controller.ex acs/2 fallback")
      assert body["error"]["code"] == "malformed"
    end

    test "social_controller: GET start for a provider that is not enabled", %{conn: conn} do
      resp = get(conn, "/v1/auth/social/no-such-provider/start")

      assert resp.status == 404
      body = assert_request_id_parity(resp, "social_controller.ex start/2")
      assert body["error"]["code"] == "not_found"
    end
  end

  describe "onixedit export (#13642 type-keyed sites)" do
    @admin_token "barkpark-parity-admin-token"
    @dataset "test"

    setup do
      {:ok, _} = Auth.create_token(@admin_token, "parity-admin", "test", ["read", "write", "admin"])

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "book", "title" => "Book", "visibility" => "private", "fields" => []},
          @dataset
        )

      :ok
    end

    test "export_controller: 404 for a document that does not exist", %{conn: conn} do
      resp =
        conn
        |> put_req_header("authorization", "Bearer " <> @admin_token)
        |> get("/v1/plugins/onixedit/export/#{@dataset}/no-such-book.onix")

      assert resp.status == 404
      body = assert_request_id_parity(resp, "onixedit/web/export_controller.ex send_404/1")
      assert body["error"]["code"] == "not_found"
    end
  end
end
