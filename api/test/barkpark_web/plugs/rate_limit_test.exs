defmodule BarkparkWeb.Plugs.RateLimitTest do
  use BarkparkWeb.ConnCase, async: false

  alias BarkparkWeb.Plugs.RateLimit

  setup do
    original = Application.get_env(:barkpark, :rate_limits)
    on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)
    :ok
  end

  defp with_limits(overrides) do
    Application.put_env(
      :barkpark,
      :rate_limits,
      Keyword.merge(
        [read_per_minute: 300, write_per_minute: 60, datasets: %{}],
        overrides
      )
    )
  end

  defp build(method, path, path_params \\ %{}, headers \\ []) do
    conn = build_conn(method, path, "")
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)
    %{conn | path_params: path_params}
  end

  test "GETs are billed against the read bucket (burst = read_per_minute)" do
    with_limits(read_per_minute: 2, write_per_minute: 1)

    c1 =
      build(:get, "/v1/data/query/production/post", %{"dataset" => "production"}, [
        {"authorization", "Bearer get-token"}
      ])

    assert Plug.Conn.halted?(RateLimit.call(c1, RateLimit.init([]))) == false
    assert Plug.Conn.halted?(RateLimit.call(c1, RateLimit.init([]))) == false
    out = RateLimit.call(c1, RateLimit.init([]))
    assert out.halted
    assert out.status == 429
  end

  test "POSTs have their own bucket (GET exhaustion does not affect POST)" do
    with_limits(read_per_minute: 1, write_per_minute: 1)

    get_conn =
      build(:get, "/v1/data/query/production/post", %{"dataset" => "production"}, [
        {"authorization", "Bearer same-token"}
      ])

    post_conn =
      build(:post, "/v1/data/mutate/production", %{"dataset" => "production"}, [
        {"authorization", "Bearer same-token"}
      ])

    assert RateLimit.call(get_conn, RateLimit.init([])).halted == false
    assert RateLimit.call(get_conn, RateLimit.init([])).halted == true

    # The POST bucket is untouched — still has its allowance
    assert RateLimit.call(post_conn, RateLimit.init([])).halted == false
  end

  test "429 response uses retry_after envelope and header" do
    with_limits(read_per_minute: 1, write_per_minute: 1)

    conn =
      build(:post, "/v1/data/mutate/production", %{"dataset" => "production"}, [
        {"authorization", "Bearer retry-token"}
      ])

    _ = RateLimit.call(conn, RateLimit.init([]))
    denied = RateLimit.call(conn, RateLimit.init([]))

    assert denied.halted
    assert denied.status == 429

    [retry_after_hdr] = Plug.Conn.get_resp_header(denied, "retry-after")
    assert retry_after_hdr == "60"

    body = Jason.decode!(denied.resp_body)
    assert body["error"]["code"] == "rate_limited"
    assert body["error"]["details"]["retry_after"] == 60
  end

  test "per-dataset override wins over defaults" do
    with_limits(
      read_per_minute: 1,
      write_per_minute: 1,
      datasets: %{"staging" => %{read: 3}}
    )

    conn =
      build(:get, "/v1/data/query/staging/post", %{"dataset" => "staging"}, [
        {"authorization", "Bearer ds-token"}
      ])

    # Default read would allow 1; override bumps it to 3
    assert RateLimit.call(conn, RateLimit.init([])).halted == false
    assert RateLimit.call(conn, RateLimit.init([])).halted == false
    assert RateLimit.call(conn, RateLimit.init([])).halted == false
    assert RateLimit.call(conn, RateLimit.init([])).halted == true
  end

  test "unauthenticated callers are bucketed by IP" do
    with_limits(read_per_minute: 1, write_per_minute: 1)

    conn = build(:get, "/v1/data/query/production/post", %{"dataset" => "production"})

    assert RateLimit.call(conn, RateLimit.init([])).halted == false
    assert RateLimit.call(conn, RateLimit.init([])).halted == true
  end

  test "different IPs have independent buckets" do
    with_limits(read_per_minute: 1, write_per_minute: 1)

    conn_a = build(:get, "/v1/data/query/production/post", %{"dataset" => "production"})
    conn_a = %{conn_a | remote_ip: {10, 0, 0, 1}}
    conn_b = build(:get, "/v1/data/query/production/post", %{"dataset" => "production"})
    conn_b = %{conn_b | remote_ip: {10, 0, 0, 2}}

    assert RateLimit.call(conn_a, RateLimit.init([])).halted == false
    assert RateLimit.call(conn_a, RateLimit.init([])).halted == true
    assert RateLimit.call(conn_b, RateLimit.init([])).halted == false
  end
end
