defmodule BarkparkWeb.Contract.RateLimitTest do
  use BarkparkWeb.ConnCase, async: false

  setup do
    :ets.delete_all_objects(:barkpark_rate_limiter)
    :ok
  end

  test "burst of 201 requests hits the 429 on the 201st", %{conn: _conn} do
    base_conn = Phoenix.ConnTest.build_conn()

    for _ <- 1..200 do
      resp = get(base_conn, "/v1/data/query/ratelimit_test/nosuch")
      refute resp.status == 429
    end

    resp = get(base_conn, "/v1/data/query/ratelimit_test/nosuch")
    assert resp.status == 429
    assert get_resp_header(resp, "retry-after") == ["60"]
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "rate_limited"
  end
end
