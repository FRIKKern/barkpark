defmodule BarkparkWeb.Studio.ApiTesterSweepCleanupTest do
  @moduledoc """
  Run all must not leave a live webhook behind.

  Stranger walk (2026-09-30): every Run all installed one more ACTIVE "Notify
  Slack" webhook to https://hooks.slack.com/services/... on `publish` of `post`
  (the Create webhook scenario's body_example), never removed — so each later
  post publish made an outbound POST to Slack's domain and counted
  consecutive_failures. The sweep now DELETEs the webhook its create returned.
  """
  use ExUnit.Case, async: true

  alias Barkpark.ApiTester.Endpoints
  alias Barkpark.ApiTester.Endpoints.Webhooks
  alias BarkparkWeb.Studio.ApiTesterLive

  defp create_spec, do: Enum.find(Endpoints.all("production"), &(&1.id == "webhooks-create"))

  test "the created-webhook cleanup deletes by the returned id, and nothing for a refused create" do
    assert Webhooks.created_webhook_cleanup(%{
             "webhook" => %{"id" => "w-1", "dataset" => "production"}
           }) == [%{method: :delete, path: "/v1/webhooks/production/w-1", auth: :admin}]

    assert Webhooks.created_webhook_cleanup(%{"error" => %{"code" => "validation_failed"}}) == []
    assert Webhooks.created_webhook_cleanup(nil) == []
  end

  test "sweep_cleanup DELETEs the created webhook with the sweep's token and records the outcome" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "DELETE", "/v1/webhooks/production/w-42", fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok-sweep"]
      Plug.Conn.resp(conn, 200, ~s({"deleted":"w-42"}))
    end)

    result = %{
      verdict: :pass,
      status: 201,
      body_json: %{"webhook" => %{"id" => "w-42", "dataset" => "production"}}
    }

    out =
      ApiTesterLive.sweep_cleanup(result, create_spec(), %{
        token: "tok-sweep",
        base: "http://localhost:#{bypass.port}"
      })

    assert [%{method: :delete, status: 200}] = out.sweep_cleanup
    assert out.verdict == :pass, "the undo must not change the scenario's own verdict"
  end

  test "an endpoint without a sweep cleanup, or a create that returned no webhook, is untouched" do
    plain = Enum.find(Endpoints.all("production"), &(&1.id == "webhooks-list"))
    result = %{verdict: :pass, body_json: %{"webhooks" => []}}

    assert ApiTesterLive.sweep_cleanup(result, plain, %{token: "t", base: "http://x"}) == result

    refused = %{verdict: :fail, body_json: %{"error" => %{"code" => "forbidden"}}}

    assert ApiTesterLive.sweep_cleanup(refused, create_spec(), %{token: "t", base: "http://x"}) ==
             refused
  end
end
