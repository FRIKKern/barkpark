defmodule BarkparkWeb.WebhookDeliveriesTest do
  @moduledoc """
  Operator-console webhook surface on the instance API (epic slice C5):
  delivery log (newest-first, with latency), synchronous replay of a stored
  event, and secret rotation — all admin-scoped and dataset-fenced.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures, only: [create_workspace!: 0, create_project!: 1]
  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.{Dispatcher, Webhook}

  # Records every outbound POST to the test process and returns 200 so a replay
  # can be observed (body + headers) without a real network call.
  defmodule RecordingHTTP do
    def post(url, body, headers) do
      pid = Application.get_env(:barkpark, :test_recv_pid)
      if pid, do: send(pid, {:webhook_post, url, body, headers})
      {:ok, 200}
    end
  end

  setup do
    {:ok, token} = Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    prev_adapter = Application.get_env(:barkpark, :webhook_http_adapter)
    Application.put_env(:barkpark, :webhook_http_adapter, RecordingHTTP)
    Application.put_env(:barkpark, :test_recv_pid, self())

    on_exit(fn ->
      case prev_adapter do
        nil -> Application.delete_env(:barkpark, :webhook_http_adapter)
        v -> Application.put_env(:barkpark, :webhook_http_adapter, v)
      end

      Application.delete_env(:barkpark, :test_recv_pid)
    end)

    %{token: token}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
  end

  # Create a webhook the same way the app does — through the admin POST route —
  # so it is stamped with the conn's workspace/project scope and is therefore
  # visible to the scoped reads the controller performs. Returns the reloaded
  # struct (carrying the secret we supplied). `events` defaults OFF the "create"
  # /"publish" events fired elsewhere so the seed never auto-dispatches.
  defp make_webhook(conn, attrs \\ %{}) do
    dataset = Map.get(attrs, "dataset", "test")

    body =
      %{"name" => "Hook", "url" => "http://example.test/hook", "events" => ["patch"], "secret" => "s0"}
      |> Map.merge(Map.delete(attrs, "dataset"))

    resp = conn |> authed() |> post("/v1/webhooks/#{dataset}", Jason.encode!(body))
    assert resp.status == 201
    id = Jason.decode!(resp.resp_body)["webhook"]["id"]
    Repo.get!(Webhook, id)
  end

  # Insert a mutation_events row directly (no Content broadcast → no stray
  # auto-delivery), returning the row. `document` is the snapshot a replay must
  # faithfully reconstruct.
  defp make_event(attrs \\ %{}) do
    now = DateTime.utc_now()

    {:ok, ev} =
      %MutationEvent{}
      |> Ecto.Changeset.change(
        Map.merge(
          %{
            dataset: "test",
            type: "widget",
            doc_id: "doc-#{System.unique_integer([:positive])}",
            mutation: "publish",
            rev: "rev-#{System.unique_integer([:positive])}",
            document: %{"_id" => "doc", "title" => "Original"},
            inserted_at: now
          },
          attrs
        )
      )
      |> Repo.insert()

    ev
  end

  describe "GET .../deliveries — list + latency" do
    test "newest-first, includes last_latency_ms", %{conn: conn} do
      wh = make_webhook(conn)
      base = DateTime.utc_now()

      # Three deliveries at increasing inserted_at with distinct latencies.
      for {offset, latency} <- [{0, 11}, {1, 22}, {2, 33}] do
        ev = make_event()
        {:ok, d} = Webhooks.claim_delivery(wh.id, ev.id)

        d
        |> Ecto.Changeset.change(%{inserted_at: DateTime.add(base, offset, :second)})
        |> Repo.update!()

        {:ok, _} = Webhooks.mark_delivered(Repo.reload!(d), 200, 1, latency)
      end

      resp = conn |> authed() |> get("/v1/webhooks/test/#{wh.id}/deliveries")
      assert resp.status == 200
      rows = Jason.decode!(resp.resp_body)["deliveries"]

      assert length(rows) == 3
      # Newest-first: latencies 33, 22, 11 in that order.
      assert Enum.map(rows, & &1["last_latency_ms"]) == [33, 22, 11]
      assert Enum.all?(rows, &(&1["status"] == "ok"))
      assert Enum.all?(rows, &is_integer(&1["last_latency_ms"]))
    end

    test "empty endpoint returns an empty list, not an error", %{conn: conn} do
      wh = make_webhook(conn)
      resp = conn |> authed() |> get("/v1/webhooks/test/#{wh.id}/deliveries")
      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["deliveries"] == []
    end
  end

  describe "list_deliveries/2 limit clamp (context boundary)" do
    test "clamps absent/negative/zero/huge to 1..100" do
      {:ok, wh} =
        Webhooks.create_webhook(%{
          "name" => "Clamp",
          "url" => "http://example.test/hook",
          "dataset" => "test",
          "events" => ["patch"]
        })

      # 101 deliveries so 25 (default) and 100 (max) are both strictly below the
      # total — the clamp is observable, not masked by a small row count.
      for i <- 1..101 do
        ev = make_event()
        {:ok, d} = Webhooks.claim_delivery(wh.id, ev.id)
        {:ok, _} = Webhooks.mark_delivered(d, 200, 1, i)
      end

      # Absent → default 25.
      assert length(Webhooks.list_deliveries(wh.id)) == 25
      # Negative → clamped up to 1.
      assert length(Webhooks.list_deliveries(wh.id, limit: -5)) == 1
      # Zero → clamped up to 1.
      assert length(Webhooks.list_deliveries(wh.id, limit: 0)) == 1
      # Huge → clamped down to 100.
      assert length(Webhooks.list_deliveries(wh.id, limit: 100_000)) == 100
    end
  end

  describe "POST .../deliveries/:event_id/replay" do
    test "rebuilds the ORIGINAL payload snapshot, re-signs with the current secret, records a fresh attempt",
         %{conn: conn} do
      wh = make_webhook(conn, %{"secret" => "current-secret"})
      ev = make_event(%{document: %{"_id" => "doc9", "title" => "Snapshotted"}, doc_id: "doc9"})

      resp =
        conn
        |> authed()
        |> post("/v1/webhooks/test/#{wh.id}/deliveries/#{ev.id}/replay")

      assert resp.status == 200
      delivery = Jason.decode!(resp.resp_body)["delivery"]
      assert delivery["status"] == "ok"
      assert delivery["last_status_code"] == 200
      assert delivery["attempts"] == 1
      assert is_integer(delivery["last_latency_ms"])
      assert delivery["event_id"] == ev.id

      # The fake receiver saw the reconstructed original payload + correct headers.
      assert_receive {:webhook_post, url, body, headers}, 2_000
      assert url == wh.url

      payload = Jason.decode!(body)
      assert payload["document"] == %{"_id" => "doc9", "title" => "Snapshotted"}
      assert payload["event"] == "publish"
      assert payload["type"] == "widget"
      assert payload["doc_id"] == "doc9"

      hmap = Map.new(headers)
      assert hmap["x-barkpark-event-id"] == Integer.to_string(ev.id)
      assert hmap["x-barkpark-delivery-id"] == Integer.to_string(ev.id)

      # Re-signed with the CURRENT secret (verify_signature over the combined header).
      ts = String.to_integer(hmap["x-barkpark-timestamp"])
      assert Dispatcher.verify_signature(body, ts, hmap["x-barkpark-signature"], ["current-secret"])
      refute Dispatcher.verify_signature(body, ts, hmap["x-barkpark-signature"], ["s0"])
    end

    test "replaying against an existing delivery row bumps attempts on the SAME row", %{conn: conn} do
      wh = make_webhook(conn)
      ev = make_event()
      {:ok, d} = Webhooks.claim_delivery(wh.id, ev.id)
      {:ok, _} = Webhooks.mark_delivered(d, 200, 3, 5)

      resp =
        conn |> authed() |> post("/v1/webhooks/test/#{wh.id}/deliveries/#{ev.id}/replay")

      assert resp.status == 200
      delivery = Jason.decode!(resp.resp_body)["delivery"]
      # attempts 3 → 4 on the same row (no new row created).
      assert delivery["attempts"] == 4
      assert delivery["id"] == d.id

      assert Repo.aggregate(
               from(x in "webhook_deliveries", where: x.endpoint_id == type(^wh.id, :binary_id)),
               :count
             ) == 1
    end

    test "unknown event_id → 404 (event not found)", %{conn: conn} do
      wh = make_webhook(conn)

      resp =
        conn |> authed() |> post("/v1/webhooks/test/#{wh.id}/deliveries/999999999/replay")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["message"] == "event not found"
      # No delivery attempted.
      refute_receive {:webhook_post, _, _, _}, 200
    end

    test "non-integer event_id → 404", %{conn: conn} do
      wh = make_webhook(conn)
      resp = conn |> authed() |> post("/v1/webhooks/test/#{wh.id}/deliveries/abc/replay")
      assert resp.status == 404
    end

    test "an event from another dataset cannot be replayed to this webhook → 404", %{conn: conn} do
      wh = make_webhook(conn, %{"dataset" => "test"})
      foreign = make_event(%{dataset: "other"})

      resp =
        conn |> authed() |> post("/v1/webhooks/test/#{wh.id}/deliveries/#{foreign.id}/replay")

      assert resp.status == 404
      refute_receive {:webhook_post, _, _, _}, 200
    end

    test "an event from ANOTHER WORKSPACE's same-named dataset cannot be replayed → 404",
         %{conn: conn} do
      # The dataset STRING is not a tenant boundary: "test" here exists in this
      # scope AND in a foreign workspace, and event ids are global sequential
      # integers. A replay of the foreign workspace's event must 404 — otherwise
      # a webhook owner could exfiltrate another tenant's document snapshots by
      # replaying guessed event ids to their own URL.
      wh = make_webhook(conn, %{"dataset" => "test"})

      other_ws = create_workspace!()
      foreign = make_event(%{dataset: "test", workspace_id: other_ws.id})

      resp =
        conn |> authed() |> post("/v1/webhooks/test/#{wh.id}/deliveries/#{foreign.id}/replay")

      assert resp.status == 404
      assert Jason.decode!(resp.resp_body)["error"]["message"] == "event not found"
      refute_receive {:webhook_post, _, _, _}, 200
    end
  end

  describe "workspace-scoped route mirror (/w/:ws/p/:proj/v1/webhooks)" do
    setup %{conn: conn, token: token} do
      ws = create_workspace!()
      proj = create_project!(ws)
      # The scoped admin gate is per-membership (owner/admin role in THIS
      # workspace), not global token perms — grant it explicitly.
      {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, token.id, "admin")

      base = "/w/#{ws.slug}/p/#{proj.slug}/v1/webhooks"

      resp =
        conn
        |> authed()
        |> post(
          "#{base}/test",
          Jason.encode!(%{
            "name" => "Scoped hook",
            "url" => "http://example.test/scoped",
            "events" => ["patch"],
            "secret" => "scoped-secret"
          })
        )

      assert resp.status == 201
      wh_id = Jason.decode!(resp.resp_body)["webhook"]["id"]
      wh = Repo.get!(Webhook, wh_id)
      # The scoped POST stamped the webhook with the resolved tenant.
      assert wh.workspace_id == ws.id
      assert wh.project_id == proj.id

      %{ws: ws, proj: proj, base: base, wh: wh}
    end

    test "replays a SAME-scope event and lists it in deliveries", %{
      conn: conn,
      ws: ws,
      proj: proj,
      base: base,
      wh: wh
    } do
      ev = make_event(%{dataset: "test", workspace_id: ws.id, project_id: proj.id})

      resp =
        conn |> authed() |> post("#{base}/test/#{wh.id}/deliveries/#{ev.id}/replay")

      assert resp.status == 200
      delivery = Jason.decode!(resp.resp_body)["delivery"]
      assert delivery["status"] == "ok"
      assert delivery["event_id"] == ev.id
      assert_receive {:webhook_post, "http://example.test/scoped", _body, _headers}, 2_000

      # The scoped deliveries listing sees the fresh row.
      list = conn |> authed() |> get("#{base}/test/#{wh.id}/deliveries")
      assert list.status == 200
      rows = Jason.decode!(list.resp_body)["deliveries"]
      assert Enum.map(rows, & &1["event_id"]) == [ev.id]
    end

    test "fences a foreign-workspace event and a foreign-workspace webhook id", %{
      conn: conn,
      base: base,
      wh: wh
    } do
      other_ws = create_workspace!()
      foreign_ev = make_event(%{dataset: "test", workspace_id: other_ws.id})

      resp =
        conn |> authed() |> post("#{base}/test/#{wh.id}/deliveries/#{foreign_ev.id}/replay")

      assert resp.status == 404
      refute_receive {:webhook_post, _, _, _}, 200

      # A flat-route (unscoped/Default) webhook id is invisible under this
      # workspace's scoped routes.
      flat_wh = make_webhook(conn)
      assert conn |> authed() |> get("#{base}/test/#{flat_wh.id}/deliveries") |> Map.get(:status) == 404
      assert conn |> authed() |> post("#{base}/test/#{flat_wh.id}/rotate") |> Map.get(:status) == 404
    end
  end

  describe "POST .../rotate" do
    test "returns a fresh secret once; old signatures still verify within TTL", %{conn: conn} do
      wh = make_webhook(conn, %{"secret" => "old-secret"})

      resp = conn |> authed() |> post("/v1/webhooks/test/#{wh.id}/rotate")
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      new_secret = body["secret"]
      assert is_binary(new_secret)
      assert new_secret != "old-secret"
      # The webhook body itself never re-exposes the secret.
      refute Map.has_key?(body["webhook"], "secret")

      reloaded = Repo.get!(Webhook, wh.id)
      assert reloaded.secret == new_secret
      assert reloaded.previous_secret == "old-secret"
      assert reloaded.previous_secret_expires_at != nil

      # Old-secret signatures verify while the previous window is open.
      now = DateTime.utc_now()
      secrets = Webhook.effective_secrets(reloaded, now)
      assert new_secret in secrets
      assert "old-secret" in secrets

      # Timestamp must be FRESH: #994 added replay-freshness to
      # verify_signature, so an ancient ts (e.g. 42) is now correctly
      # rejected regardless of the secret. Use now.
      ts = System.system_time(:second)
      old_sig = Dispatcher.sign_payload("payload", ts, "old-secret")
      assert Dispatcher.verify_signature("payload", ts, old_sig, secrets)
    end
  end

  describe "cross-dataset + auth fencing" do
    test "a webhook id fetched under the wrong :dataset is 404", %{conn: conn} do
      wh = make_webhook(conn, %{"dataset" => "test"})

      # deliveries under a foreign dataset
      assert conn |> authed() |> get("/v1/webhooks/other/#{wh.id}/deliveries") |> Map.get(:status) ==
               404

      # rotate under a foreign dataset
      assert conn |> authed() |> post("/v1/webhooks/other/#{wh.id}/rotate") |> Map.get(:status) ==
               404

      # replay under a foreign dataset (webhook check fails before the event lookup)
      ev = make_event()

      assert conn
             |> authed()
             |> post("/v1/webhooks/other/#{wh.id}/deliveries/#{ev.id}/replay")
             |> Map.get(:status) == 404
    end

    test "the delivery routes require admin auth", %{conn: conn} do
      wh = make_webhook(conn)
      assert get(conn, "/v1/webhooks/test/#{wh.id}/deliveries").status == 401
      assert post(conn, "/v1/webhooks/test/#{wh.id}/rotate").status == 401
    end
  end
end
