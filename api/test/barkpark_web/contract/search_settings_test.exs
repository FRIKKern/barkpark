defmodule BarkparkWeb.Contract.SearchSettingsTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Search.SurfaceConfigs

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])
    SurfaceConfigs.seed_defaults!()
    :ok
  end

  test "admin can get and update document search settings", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> get("/v1/data/search/test/settings")

    body = json_response(conn, 200)
    assert body["result"]["zero_hit_strategy"] == "drop_tokens"

    conn =
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> put("/v1/data/search/test/settings", %{"zeroHitStrategy" => "typo_widen"})

    body = json_response(conn, 200)
    assert body["result"]["zero_hit_strategy"] == "typo_widen"
  end

  # §9 error-envelope conformance for the settings validation path — an invalid
  # cast (zeroHitStrategy is a :string, not a map) routes through
  # validation_error/2, which must now carry code + request_id.
  test "document settings invalid value → validation_failed envelope", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> put("/v1/data/search/test/settings", %{"zeroHitStrategy" => %{"bad" => true}})

    body = json_response(conn, 422)
    assert body["error"]["code"] == "validation_failed"
    assert is_binary(body["error"]["request_id"])
    assert body["error"]["request_id"] != ""
  end

  test "admin can get media search settings", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-dev-token")
      |> get("/v1/media/test/search/settings")

    body = json_response(conn, 200)
    assert is_list(body["result"]["searchable_fields"])
  end
end
