defmodule BarkparkWeb.WebhookControllerParamCoercionTest do
  @moduledoc """
  Guards `WebhookController.parse_limit/1` against a non-scalar `?limit`
  (task `wbqs-api-webhook-param-coercion`).

  Phoenix's `Plug.Conn.Query` parser turns `?limit[]=5` into a LIST
  (`["5"]`). Before this fix `parse_limit/1` had only `nil` and
  `is_binary(value)` clauses, so a list value hit no clause and raised
  `FunctionClauseError` -> HTTP 500 at the deliveries listing (call site
  `WebhookController.deliveries/2`). The added catch-all
  (`defp parse_limit(_), do: nil`) treats any non-binary/non-nil value the
  same as absent, so the context applies its default instead of crashing —
  same idiom as `history_controller.ex`'s `parse_int/2` catch-all.
  """
  # async: false — every setup here mints the fixed dev token
  # ("barkpark-dev-token"), which hashes to the same `token_hash` regardless
  # of label/dataset/workspace. Concurrent async tests in this file would race
  # the unique index on that literal string; webhook_deliveries_test.exs hits
  # the same idiom and solves it the same way.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth

  setup do
    {:ok, token} =
      Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    %{token: token}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
  end

  defp make_webhook(conn) do
    body = %{
      "name" => "Hook",
      "url" => "http://example.test/hook",
      "events" => ["patch"],
      "secret" => "s0"
    }

    resp = conn |> authed() |> post("/v1/webhooks/test", Jason.encode!(body))
    assert resp.status == 201
    Jason.decode!(resp.resp_body)["webhook"]["id"]
  end

  describe "GET .../deliveries — non-scalar ?limit" do
    test "list param (?limit[]=5) degrades to the default, not a 500", %{conn: conn} do
      wh_id = make_webhook(conn)

      resp = conn |> authed() |> get("/v1/webhooks/test/#{wh_id}/deliveries?limit[]=5")

      refute resp.status == 500
      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["deliveries"] == []
    end

    test "map param (?limit[k]=5) degrades to the default, not a 500", %{conn: conn} do
      wh_id = make_webhook(conn)

      resp = conn |> authed() |> get("/v1/webhooks/test/#{wh_id}/deliveries?limit[k]=5")

      refute resp.status == 500
      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["deliveries"] == []
    end

    test "ordinary scalar ?limit still works", %{conn: conn} do
      wh_id = make_webhook(conn)

      resp = conn |> authed() |> get("/v1/webhooks/test/#{wh_id}/deliveries?limit=5")

      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["deliveries"] == []
    end
  end
end
