defmodule BarkparkWeb.Contract.RateLimitTest do
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  # `:barkpark_rate_limiter` is a :named_table — WHOLE-NODE state no sandbox owns
  # and nothing used to reset, so a bucket one test spent stayed spent for the
  # rest of the run. Start from an unspent table.
  setup :reset_rate_limiter!

  setup do
    :ets.delete_all_objects(:barkpark_rate_limiter)

    original = Application.get_env(:barkpark, :rate_limits)

    # Small capacity ON PURPOSE: capacity == read_per_minute and refill ==
    # read_per_minute/60 tokens/sec, so a 200-request burst on a LOADED CI
    # runner takes long enough to refill ≥1 token and request 201 sails
    # through as 404 (seen live on 683301e's run — the suite grew and the
    # runner slowed; locally the burst takes 90ms and always passed). A
    # 10-burst finishes in ~5ms ≈ 0.001 refilled tokens: deterministic.
    Application.put_env(
      :barkpark,
      :rate_limits,
      read_per_minute: 10,
      write_per_minute: 60,
      datasets: %{}
    )

    on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)
    :ok
  end

  test "a burst past capacity hits the 429 on request capacity+1", %{conn: _conn} do
    base_conn = Phoenix.ConnTest.build_conn()

    for _ <- 1..10 do
      resp = get(base_conn, "/v1/data/query/ratelimit_test/nosuch")
      refute resp.status == 429
    end

    resp = get(base_conn, "/v1/data/query/ratelimit_test/nosuch")
    assert resp.status == 429
    # retry-after = time to refill one token = ceil(60 / read_per_minute).
    assert get_resp_header(resp, "retry-after") == ["6"]
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "rate_limited"
  end
end
