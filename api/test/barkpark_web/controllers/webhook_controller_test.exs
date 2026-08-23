defmodule BarkparkWeb.WebhookControllerTest do
  @moduledoc """
  HTTP-boundary coverage for `POST /v1/webhooks/:dataset/:id/test-send` (GR45).

  Filed as `gr-backlog-webhook-testsend-http-test`: the test-send route
  (`WebhookController.test_send/2`, `Webhooks.create_test_delivery/1`,
  `Dispatcher.deliver_test/3`) merged in #4391 with extensive context/dispatcher
  unit coverage but ZERO controller-level coverage — nothing exercised the HTTP
  boundary a real client calls: auth/authorization, the response envelope
  shape, 404 on an unknown webhook id, or that a FAILING test-send cannot
  perturb the real endpoint's auto-disable streak (the safety crux is the
  test delivery's `endpoint_id: nil`, see `Webhooks.create_test_delivery/1`
  and `Webhooks.record_endpoint_failure(nil, _)`).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Webhook

  # Controllable fake adapter: the test process tells it what to return via
  # `Application.put_env(:barkpark, :test_send_response, ...)` and every POST
  # is recorded back to the test process (mirrors webhook_deliveries_test.exs's
  # RecordingHTTP, extended with a settable verdict so failure can be forced).
  defmodule ControllableHTTP do
    def post(url, body, headers) do
      pid = Application.get_env(:barkpark, :test_recv_pid)
      if pid, do: send(pid, {:webhook_post, url, body, headers})
      Application.get_env(:barkpark, :test_send_response, {:ok, 200})
    end
  end

  setup do
    {:ok, admin_token} =
      Auth.create_token("barkpark-admin-token", "dev", "test", ["read", "write", "admin"])

    {:ok, write_only_token} =
      Auth.create_token("barkpark-write-token", "dev", "test", ["read", "write"])

    prev_adapter = Application.get_env(:barkpark, :webhook_http_adapter)
    Application.put_env(:barkpark, :webhook_http_adapter, ControllableHTTP)
    Application.put_env(:barkpark, :test_send_response, {:ok, 200})
    Application.put_env(:barkpark, :test_recv_pid, self())

    on_exit(fn ->
      case prev_adapter do
        nil -> Application.delete_env(:barkpark, :webhook_http_adapter)
        v -> Application.put_env(:barkpark, :webhook_http_adapter, v)
      end

      Application.delete_env(:barkpark, :test_send_response)
      Application.delete_env(:barkpark, :test_recv_pid)
    end)

    %{admin_token: admin_token, write_only_token: write_only_token}
  end

  defp authed(conn, token \\ "barkpark-admin-token") do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  # Create a webhook through the admin POST route (same path the app uses),
  # so it carries the conn's tenant scope. Returns the reloaded struct.
  defp make_webhook(conn, attrs \\ %{}) do
    dataset = Map.get(attrs, "dataset", "test")

    body =
      %{
        "name" => "Test-send Hook",
        "url" => "http://example.test/hook",
        "events" => ["patch"],
        "secret" => "s0"
      }
      |> Map.merge(Map.delete(attrs, "dataset"))

    resp = conn |> authed() |> post("/v1/webhooks/#{dataset}", Jason.encode!(body))
    assert resp.status == 201
    id = Jason.decode!(resp.resp_body)["webhook"]["id"]
    Repo.get!(Webhook, id)
  end

  describe "POST .../test-send — success envelope" do
    test "admin 200 with the documented {delivery: ...} envelope shape", %{conn: conn} do
      wh = make_webhook(conn)

      resp = conn |> authed() |> post("/v1/webhooks/test/#{wh.id}/test-send")
      assert resp.status == 200

      body = Jason.decode!(resp.resp_body)
      assert %{"delivery" => delivery} = body
      # The full render_delivery/1 shape — every key present, none extra beyond it.
      assert Map.keys(delivery) |> Enum.sort() ==
               Enum.sort([
                 "id",
                 "endpoint_id",
                 "event_id",
                 "status",
                 "attempts",
                 "last_status_code",
                 "last_error_text",
                 "last_latency_ms",
                 "created_at",
                 "updated_at"
               ])

      assert delivery["status"] == "ok"
      assert delivery["last_status_code"] == 200
      assert delivery["attempts"] == 1
      # No mutation_events row backs a test probe.
      assert delivery["event_id"] == nil
      # The crux of the safety contract asserted end-to-end below: a test
      # delivery's endpoint_id is NULL so it never feeds auto-disable streaks.
      assert delivery["endpoint_id"] == nil

      # The fake receiver saw the synthetic webhook.test envelope, signed.
      assert_receive {:webhook_post, url, raw_body, headers}, 2_000
      assert url == wh.url
      payload = Jason.decode!(raw_body)
      assert payload["type"] == "webhook.test"
      assert payload["dataset"] == "test"
      assert payload["webhook"]["id"] == wh.id
      hmap = Map.new(headers)
      assert Map.has_key?(hmap, "x-barkpark-signature")
      # No delivery-id header — test sends carry no mutation event id.
      refute Map.has_key?(hmap, "x-barkpark-delivery-id")
    end

    test "the delivery persists as a durable source_kind: test row", %{conn: conn} do
      wh = make_webhook(conn)
      resp = conn |> authed() |> post("/v1/webhooks/test/#{wh.id}/test-send")
      assert resp.status == 200

      delivery_id = Jason.decode!(resp.resp_body)["delivery"]["id"]

      row =
        Repo.get!(Barkpark.Webhooks.Delivery, delivery_id)

      assert row.source_kind == "test"
      assert row.endpoint_id == nil
    end
  end

  describe "POST .../test-send — not found + auth fencing" do
    @absent_webhook "00000000-0000-4000-8000-000000000000"

    test "unknown webhook id -> 404 webhook_not_found", %{conn: conn} do
      resp = conn |> authed() |> post("/v1/webhooks/test/#{@absent_webhook}/test-send")
      assert resp.status == 404
      err = Jason.decode!(resp.resp_body)["error"]
      assert err["code"] == "webhook_not_found"
      refute_receive {:webhook_post, _, _, _}, 200
    end

    test "a webhook id fetched under the wrong :dataset is 404", %{conn: conn} do
      wh = make_webhook(conn, %{"dataset" => "test"})
      resp = conn |> authed() |> post("/v1/webhooks/other/#{wh.id}/test-send")
      assert resp.status == 404
      refute_receive {:webhook_post, _, _, _}, 200
    end

    test "no token -> 401, no delivery attempted", %{conn: conn} do
      wh = make_webhook(conn)
      resp = post(conn, "/v1/webhooks/test/#{wh.id}/test-send")
      assert resp.status == 401
      refute_receive {:webhook_post, _, _, _}, 200
    end

    test "a non-admin (read+write only) token -> 403, no delivery attempted", %{
      conn: conn,
      write_only_token: _write_only_token
    } do
      wh = make_webhook(conn)

      resp =
        conn
        |> authed("barkpark-write-token")
        |> post("/v1/webhooks/test/#{wh.id}/test-send")

      assert resp.status == 403
      refute_receive {:webhook_post, _, _, _}, 200
    end
  end

  describe "POST .../test-send — a FAILING probe cannot perturb the real endpoint's auto-disable streak" do
    test "endpoint_id stays NULL on the delivery row, and the webhook's consecutive_failures is untouched",
         %{conn: conn} do
      wh = make_webhook(conn)

      # Give the endpoint a nonzero, sub-threshold failure streak the way a
      # real flaky delivery history would — a probe must leave THIS untouched
      # in either direction, not merely "stay at 0".
      wh
      |> Ecto.Changeset.change(%{consecutive_failures: 5})
      |> Repo.update!()

      # Force the probe itself to fail terminally (a non-2xx, non-retryable
      # status the dispatcher classifies as a give-up).
      Application.put_env(:barkpark, :test_send_response, {:ok, 500})

      resp = conn |> authed() |> post("/v1/webhooks/test/#{wh.id}/test-send")
      assert resp.status == 200

      delivery = Jason.decode!(resp.resp_body)["delivery"]
      assert delivery["status"] == "failed_giveup"
      assert delivery["last_status_code"] == 500
      assert delivery["endpoint_id"] == nil

      # The real endpoint's streak is EXACTLY what it was before the failing
      # probe — mark_giveup's record_endpoint_failure/2 no-ops on a nil
      # endpoint_id (Webhooks.create_test_delivery/1's whole safety contract).
      reloaded = Repo.get!(Webhook, wh.id)
      assert reloaded.consecutive_failures == 5
      assert reloaded.active == true
      assert reloaded.auto_disabled_at == nil
    end

    test "a run of failing test-sends at/past the real auto-disable threshold still never disables the endpoint",
         %{conn: conn} do
      wh = make_webhook(conn)
      Application.put_env(:barkpark, :test_send_response, {:error, :econnrefused})

      # One MORE than the threshold — if test-sends counted toward the streak
      # like a real delivery, this would auto-disable the endpoint.
      for _ <- 0..Webhooks.auto_disable_threshold() do
        resp = conn |> authed() |> post("/v1/webhooks/test/#{wh.id}/test-send")
        assert resp.status == 200
        assert Jason.decode!(resp.resp_body)["delivery"]["status"] == "failed_giveup"
      end

      reloaded = Repo.get!(Webhook, wh.id)
      assert reloaded.consecutive_failures == 0
      assert reloaded.active == true
      assert reloaded.auto_disabled_at == nil
      assert reloaded.disable_reason == nil
    end
  end
end
