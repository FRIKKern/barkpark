defmodule BarkparkWeb.Plugs.RateLimitNamesBudgetTest do
  @moduledoc """
  task-fba67efa7f61c678 — a 429 names the budget that ran out: its class, size
  per minute, dataset scope and the kind of principal it is keyed on (a token
  or the client's IP, never an id or an address), plus when a request is
  admitted again. A token shared by two writers got 429 on single edits and the
  refusal did not say which bucket was spent.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox

  alias BarkparkWeb.Plugs.RateLimit

  setup :reset_rate_limiter!

  setup do
    original = Application.get_env(:barkpark, :rate_limits)

    Application.put_env(:barkpark, :rate_limits,
      read_per_minute: 300,
      write_per_minute: 2,
      datasets: %{}
    )

    on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)
    :ok
  end

  defp write(ip, dataset) do
    conn = %{scoped_conn() | remote_ip: ip, method: "POST", path_params: %{"dataset" => dataset}}
    RateLimit.call(conn, RateLimit.init([]))
  end

  test "the 429 names the spent budget and when it refills" do
    n = System.unique_integer([:positive])
    ip = {10, 77, rem(div(n, 256), 256), rem(n, 256)}

    refused = Enum.find_value(1..10, fn _ -> (c = write(ip, "ds-budget")).status == 429 && c end)
    assert refused, "the write bucket never refused"

    %{"error" => error} = Jason.decode!(refused.resp_body)
    assert error["code"] == "rate_limited"

    assert %{"class" => "write", "per_minute" => 2, "principal" => "ip", "scope" => scope} =
             error["details"]["budget"]

    assert scope in ["ds-budget", "global"]
    assert is_integer(error["details"]["retry_after"]) and error["details"]["retry_after"] > 0
    assert {:ok, _, _} = DateTime.from_iso8601(error["details"]["resets_at"])
    assert error["message"] =~ "write budget (2 per minute"
    refute error["message"] =~ "10.77."
    assert [_] = Plug.Conn.get_resp_header(refused, "retry-after")
  end
end
