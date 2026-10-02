defmodule BarkparkWeb.Studio.ApiTesterRunnerBaseTest do
  @moduledoc """
  The API tester's runner calls back into THIS node, so its base must be this
  node's own listen port — not a literal `http://localhost:4000`.

  Found on the stranger walk (2026-09-30): Studio → API → Run all answered
  "Error" on every row of a dev server listening on a PORT other than 4000,
  and a blue/green box whose live slot is :4001 would send every run to the
  dormant slot. The test env listens on 4002 (config/test.exs), so the old
  hardcode is exactly what this reds on.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.ApiTesterLive

  test "the runner base is loopback on the Endpoint's configured http port" do
    port = BarkparkWeb.Endpoint.config(:http)[:port]
    assert is_integer(port)
    assert ApiTesterLive.runner_base_url() == "http://127.0.0.1:#{port}"
    refute ApiTesterLive.runner_base_url() == "http://localhost:4000"
  end
end
