defmodule BarkparkWeb.Plugs.RateLimitDeliveryTest do
  @moduledoc """
  task-fe397d8f5f0a2c47: media DELIVERY GETs (/media/files, /media/renditions)
  have their own bucket. One Paper with 168 videos and 232 images made ~400 GETs
  from one reader; on the shared JSON read bucket (300/min per client) 21 came back
  429, and a browser never retries a media src. The JSON read bucket itself is
  unchanged, and delivery is still metered, on its own budget.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  setup :reset_rate_limiter!

  setup do
    original = Application.get_env(:barkpark, :rate_limits)

    # Small budgets so a burst is deterministic (see rate_limit_test.exs).
    Application.put_env(:barkpark, :rate_limits,
      read_per_minute: 10,
      write_per_minute: 60,
      delivery_per_minute: 40,
      datasets: %{}
    )

    on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)
    :ok
  end

  defp statuses(n, path) do
    conn = Phoenix.ConnTest.build_conn()
    for _ <- 1..n, do: get(conn, path).status
  end

  test "media delivery GETs do not spend the JSON read bucket, and it is unchanged" do
    # Three times the read budget in media GETs: none is refused.
    files = statuses(15, "/media/files/d/nosuch/2026/10/pixel.png")
    renditions = statuses(15, "/media/renditions/nosuch/thumb")
    refute 429 in files, inspect(files)
    refute 429 in renditions, inspect(renditions)

    # The same client's JSON reads still have their whole budget, and its edge.
    reads = statuses(11, "/v1/data/query/ratelimit_delivery/nosuch")
    refute 429 in Enum.take(reads, 10), inspect(reads)
    assert List.last(reads) == 429
  end

  test "delivery is still metered, on its own budget" do
    got = statuses(41, "/media/files/d/nosuch/2026/10/pixel.png")
    refute 429 in Enum.take(got, 40), inspect(got)
    assert List.last(got) == 429
  end
end
