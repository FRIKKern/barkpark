defmodule Barkpark.Webhooks.DispatcherTest do
  use Barkpark.DataCase, async: false
  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Dispatcher

  # Fake HTTP adapter backed by an Agent. Test pushes a list of scripted
  # responses; each call pops one. Also records attempts (url/body/headers)
  # so we can assert on retries and header shape.
  # Blocking HTTP adapter for the backpressure test: every post/3 announces
  # itself to the test process, then parks until it receives `:release`. Lets
  # the test hold deliveries in-flight and observe the concurrency cap.
  defmodule BlockingHTTP do
    def post(_url, _body, _headers) do
      test_pid = Application.get_env(:barkpark, :test_blocking_pid)
      send(test_pid, {:blocked, self()})

      receive do
        :release -> {:ok, 200}
      end
    end
  end

  defmodule FakeHTTP do
    @name __MODULE__

    def start(responses) do
      case Process.whereis(@name) do
        nil ->
          {:ok, _} = Agent.start_link(fn -> %{responses: responses, calls: []} end, name: @name)

        _pid ->
          Agent.update(@name, fn _ -> %{responses: responses, calls: []} end)
      end

      :ok
    end

    def calls, do: Agent.get(@name, & &1.calls) |> Enum.reverse()

    def post(url, body, headers) do
      Agent.get_and_update(@name, fn %{responses: [resp | rest], calls: calls} = state ->
        new_state = %{state | responses: rest, calls: [{url, body, headers} | calls]}
        {resp, new_state}
      end)
    end
  end

  setup do
    prev_adapter = Application.get_env(:barkpark, :webhook_http_adapter)
    prev_delays = Application.get_env(:barkpark, :webhook_retry_delays_ms)
    prev_max = Application.get_env(:barkpark, :webhook_max_attempts)

    Application.put_env(:barkpark, :webhook_http_adapter, FakeHTTP)
    Application.put_env(:barkpark, :webhook_retry_delays_ms, [5, 10, 20])
    Application.put_env(:barkpark, :webhook_max_attempts, 3)

    on_exit(fn ->
      set_or_delete(:webhook_http_adapter, prev_adapter)
      set_or_delete(:webhook_retry_delays_ms, prev_delays)
      set_or_delete(:webhook_max_attempts, prev_max)
    end)

    Content.upsert_schema(
      %{"name" => "widget", "title" => "W", "visibility" => "public", "fields" => []},
      "test"
    )

    # Setup-race fix: scope the seed webhook's `events` filter so it does NOT
    # match the "create" action that `Content.create_document/3` (used inside
    # `new_event_id/0`) fires via `tap_broadcast → Dispatcher.dispatch_async`.
    # Without this, the fire-and-forget Task spawned by that create-broadcast
    # would race with the test's own `Dispatcher.deliver/3` call:
    # the Task would `claim_delivery` first (DB-side, via the shared sandbox),
    # then consume a scripted FakeHTTP response — leaving the test asserting
    # `{:ok, 200, 1}` against an already-claimed delivery and an empty Agent.
    # Tests still call `Dispatcher.deliver(wh, ...)` directly, which bypasses
    # `active_webhooks_for/3`, so this `events` filter does not change the
    # behaviour under test.
    {:ok, wh} =
      Webhooks.create_webhook(%{
        "name" => "ep",
        "url" => "http://example.test/hook",
        "dataset" => "test",
        "secret" => "sek",
        "events" => ["publish"]
      })

    %{webhook: wh}
  end

  defp set_or_delete(k, nil), do: Application.delete_env(:barkpark, k)
  defp set_or_delete(k, v), do: Application.put_env(:barkpark, k, v)

  defp new_event_id do
    id = "e-" <> (Ecto.UUID.generate() |> binary_part(0, 8))
    {:ok, doc} = Content.create_document("widget", %{"_id" => id, "title" => "t"}, "test")

    [ev | _] =
      Barkpark.Repo.all(
        from(e in Barkpark.Content.MutationEvent,
          where: e.doc_id == ^doc.doc_id,
          order_by: [desc: e.id]
        )
      )

    ev.id
  end

  test "build_payload creates correct structure" do
    payload = Dispatcher.build_payload("create", "post", "p1", %{"_id" => "p1"}, "production")

    assert payload.event == "create"
    assert payload.type == "post"
    assert payload.doc_id == "p1"
    assert payload.dataset == "production"
    assert payload.document == %{"_id" => "p1"}
    assert is_binary(payload.timestamp)
  end

  test "build_payload retains legacy bp:ds:* sync_tags for back-compat" do
    payload = Dispatcher.build_payload("publish", "post", "p1", %{"_id" => "p1"}, "production")

    # Legacy dataset-only tags must still be present (back-compat).
    assert "bp:ds:production:doc:p1" in payload.sync_tags
    assert "bp:ds:production:type:post" in payload.sync_tags
  end

  test "build_payload emits workspace/project-scoped sync_tags from scope opts" do
    {:ok, ws} = Barkpark.Tenancy.create_workspace(%{slug: "acme", name: "Acme"})

    {:ok, project} =
      Barkpark.Tenancy.create_project(ws, %{slug: "blog", name: "Blog"})

    payload =
      Dispatcher.build_payload(
        "publish",
        "post",
        "p1",
        %{"_id" => "p1"},
        "production",
        workspace_id: ws.id,
        project_id: project.id
      )

    # Workspace/project-scoped tags, resolved from the ids → slugs.
    assert "bp:ws:acme:p:blog:ds:production:doc:p1" in payload.sync_tags
    assert "bp:ws:acme:p:blog:ds:production:type:post" in payload.sync_tags
    # Legacy tags still carried.
    assert "bp:ds:production:doc:p1" in payload.sync_tags
    assert "bp:ds:production:type:post" in payload.sync_tags
    # Resolved slugs surfaced on the payload.
    assert payload.workspace == "acme"
    assert payload.project == "blog"
    assert payload.workspace_id == ws.id
    assert payload.project_id == project.id
  end

  test "build_payload falls back to default slugs when scope is unset" do
    payload = Dispatcher.build_payload("publish", "post", "p1", %{"_id" => "p1"}, "production")

    assert "bp:ws:default:p:default:ds:production:doc:p1" in payload.sync_tags
    assert payload.workspace == "default"
    assert payload.project == "default"
  end

  test "200 on first attempt succeeds without retry", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 200}])
    eid = new_event_id()

    assert {:ok, 200, 1} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 1

    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "ok"
    assert d.attempts == 1
  end

  test "500 → 500 → 200 yields 2 retries then success", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 500}, {:ok, 500}, {:ok, 200}])
    eid = new_event_id()

    assert {:ok, 200, 3} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 3

    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "ok"
    assert d.attempts == 3
  end

  test "400 is terminal — no retry", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 400}, {:ok, 200}])
    eid = new_event_id()

    assert {:error, :giveup_4xx, 1} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 1

    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "failed_giveup"
    assert d.last_status_code == 400
  end

  test "3 consecutive 500s exhaust retries and give up", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 500}, {:ok, 500}, {:ok, 500}])
    eid = new_event_id()

    assert {:error, :exhausted, 3} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 3

    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "failed_giveup"
  end

  test "429 is retried (not dropped) and eventually gives up at max attempts", %{webhook: wh} do
    # Regression: a 429 used to fall into the terminal 4xx branch and DROP the
    # delivery — losing the cache-revalidation event. It must now retry like a
    # 5xx, then give up at max_attempts (still bounded).
    :ok = FakeHTTP.start([{:ok, 429, []}, {:ok, 429, []}, {:ok, 429, []}])
    eid = new_event_id()

    assert {:error, :exhausted, 3} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 3

    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "failed_giveup"
    assert d.last_status_code == 429
  end

  test "408 and 425 are retried then recover", %{webhook: wh} do
    for status <- [408, 425] do
      :ok = FakeHTTP.start([{:ok, status, []}, {:ok, 200}])
      eid = new_event_id()

      assert {:ok, 200, 2} = Dispatcher.deliver(wh, "{}", eid)
      assert length(FakeHTTP.calls()) == 2
    end
  end

  test "429 with Retry-After header retries then recovers (honors the header)", %{webhook: wh} do
    # retry-after: 0 exercises the honor-the-header path without slowing the test.
    :ok = FakeHTTP.start([{:ok, 429, [{"retry-after", "0"}]}, {:ok, 200}])
    eid = new_event_id()

    assert {:ok, 200, 2} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 2

    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "ok"
    assert d.attempts == 2
  end

  test "410 Gone is still terminal — no retry (permanent 4xx unchanged)", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 410, []}, {:ok, 200}])
    eid = new_event_id()

    assert {:error, :giveup_4xx, 1} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 1

    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "failed_giveup"
    assert d.last_status_code == 410
  end

  describe "parse_retry_after/2" do
    test "integer seconds → clamped milliseconds" do
      assert Dispatcher.parse_retry_after([{"retry-after", "30"}]) == 30_000
      # Case-insensitive header name + Req-style [binary] value.
      assert Dispatcher.parse_retry_after([{"Retry-After", ["12"]}]) == 12_000
    end

    test "absurd value is clamped to the sane max" do
      max = Application.get_env(:barkpark, :webhook_retry_after_max_ms, 300_000)
      assert Dispatcher.parse_retry_after([{"retry-after", "999999"}]) == max
    end

    test "HTTP-date resolves to a positive, clamped delay" do
      now = 1_700_000_000
      # 45s in the future relative to `now`.
      date = "Tue, 14 Nov 2023 22:14:05 GMT"
      ms = Dispatcher.parse_retry_after([{"retry-after", date}], now)
      assert is_integer(ms) and ms > 0 and ms <= 300_000
    end

    test "past HTTP-date floors at 0" do
      now = 2_000_000_000

      assert Dispatcher.parse_retry_after([{"retry-after", "Tue, 14 Nov 2023 22:14:05 GMT"}], now) ==
               0
    end

    test "absent or unparseable → nil" do
      assert Dispatcher.parse_retry_after([]) == nil
      assert Dispatcher.parse_retry_after([{"x-other", "1"}]) == nil
      assert Dispatcher.parse_retry_after([{"retry-after", "soon"}]) == nil
    end
  end

  describe "jittered_delay/2" do
    test "stays within [base/2, base*1.5] and under the ceiling" do
      base = 1_000
      ceiling = 60_000

      delays = for _ <- 1..200, do: Dispatcher.jittered_delay(base, ceiling)

      assert Enum.all?(delays, &(&1 >= div(base, 2) and &1 <= div(base * 3, 2)))
      assert Enum.all?(delays, &(&1 <= ceiling))
      # Never collapses to a busy-spin 0.
      assert Enum.min(delays) >= div(base, 2)
      # De-synchronizes: a sample of 200 must not all land on one value.
      assert length(Enum.uniq(delays)) > 1
    end

    test "ceiling clamps a large base" do
      assert Dispatcher.jittered_delay(1_000_000, 30_000) == 30_000
    end
  end

  test "transport error triggers retry", %{webhook: wh} do
    :ok = FakeHTTP.start([{:error, :timeout}, {:ok, 200}])
    eid = new_event_id()

    assert {:ok, 200, 2} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 2
  end

  test "duplicate (endpoint, event) is skipped", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 200}])
    eid = new_event_id()

    assert {:ok, 200, 1} = Dispatcher.deliver(wh, "{}", eid)

    # Second attempt — no HTTP call should occur
    :ok = FakeHTTP.start([{:ok, 500}])
    assert {:skipped, :already_delivered} = Dispatcher.deliver(wh, "{}", eid)
    assert FakeHTTP.calls() == []
  end

  test "every attempt carries combined signature + timestamp + delivery-id headers", %{
    webhook: wh
  } do
    :ok = FakeHTTP.start([{:ok, 200}])
    eid = new_event_id()

    assert {:ok, 200, 1} = Dispatcher.deliver(wh, ~s({"a":1}), eid)
    [{_url, body, headers}] = FakeHTTP.calls()

    hmap = Map.new(headers)
    assert body == ~s({"a":1})
    assert hmap["content-type"] == "application/json"
    # Combined Stripe-style header the SDK handler parses: `t=<unix>,v1=<hex>`.
    assert "t=" <> _ = hmap["x-barkpark-signature"]
    assert hmap["x-barkpark-signature"] =~ ",v1="
    assert is_binary(hmap["x-barkpark-timestamp"])
    # delivery-id is what the SDK handler dedups on; event-id kept for back-compat.
    assert hmap["x-barkpark-delivery-id"] == Integer.to_string(eid)
    assert hmap["x-barkpark-event-id"] == Integer.to_string(eid)

    # The combined header embeds the timestamp + the raw sign_payload/3 signature.
    ts = String.to_integer(hmap["x-barkpark-timestamp"])
    assert hmap["x-barkpark-signature"] == "t=#{ts},#{Dispatcher.sign_payload(body, ts, "sek")}"

    # verify_signature accepts the combined wire form.
    assert Dispatcher.verify_signature(body, ts, hmap["x-barkpark-signature"], ["sek"])
  end

  describe "verify_signature/5 cross-twin parity (JS @barkpark/core)" do
    # A signature produced OUTSIDE Elixir by the JS twin's scheme — HMAC-SHA256
    # of `"<t>.<body>"`, lower-hex — must verify here. This hex was computed
    # independently (openssl + Node Web Crypto both agree), so the assertion
    # proves byte-for-byte agreement with `js/packages/core/src/webhook.ts`,
    # NOT circular agreement with our own `sign_payload/3`.
    @parity_secret "whsec_parity"
    @parity_body ~s({"event":"publish","doc_id":"p1"})
    @parity_ts 1_700_000_000
    @parity_hex "3ffb01d7b284df564792296b2f665dbc9fa78d7f95d1b2efdca45cd075da6863"

    test "a JS-scheme signature verifies in Elixir (fresh window pinned to signed time)" do
      header = "t=#{@parity_ts},v1=#{@parity_hex}"

      # Pin `now` to the signed timestamp so freshness passes deterministically;
      # this isolates the HMAC/material parity.
      assert Dispatcher.verify_signature(
               @parity_body,
               @parity_ts,
               header,
               [@parity_secret],
               @parity_ts
             )
    end

    test "and vice-versa: Elixir's signature matches the independent JS vector byte-for-byte" do
      # sign_payload/3 is our emitter; it must reproduce the exact hex the JS
      # twin (and openssl) produce for the same secret/body/timestamp.
      assert Dispatcher.sign_payload(@parity_body, @parity_ts, @parity_secret) ==
               "v1=#{@parity_hex}"
    end

    test "stale timestamp is rejected even though the HMAC is valid (replay defense)" do
      header = "t=#{@parity_ts},v1=#{@parity_hex}"
      stale_now = @parity_ts + 301

      refute Dispatcher.verify_signature(
               @parity_body,
               @parity_ts,
               header,
               [@parity_secret],
               stale_now
             )
    end

    test "tampered body is rejected (HMAC no longer matches the signed material)" do
      header = "t=#{@parity_ts},v1=#{@parity_hex}"

      refute Dispatcher.verify_signature(
               @parity_body <> "X",
               @parity_ts,
               header,
               [@parity_secret],
               @parity_ts
             )
    end

    test "wrong secret is rejected" do
      header = "t=#{@parity_ts},v1=#{@parity_hex}"

      refute Dispatcher.verify_signature(
               @parity_body,
               @parity_ts,
               header,
               ["whsec_wrong"],
               @parity_ts
             )
    end

    test "header t= that disagrees with the passed timestamp fails closed" do
      # Attacker swaps a fresh t= into the header while replaying an old-signed v1.
      header = "t=#{@parity_ts + 5},v1=#{@parity_hex}"

      refute Dispatcher.verify_signature(
               @parity_body,
               @parity_ts,
               header,
               [@parity_secret],
               @parity_ts
             )
    end
  end

  test "fan-out backpressures at :webhook_delivery_concurrency and drops nothing", %{
    webhook: wh
  } do
    cap = 2
    prev_conc = Application.get_env(:barkpark, :webhook_delivery_concurrency)
    Application.put_env(:barkpark, :webhook_delivery_concurrency, cap)
    Application.put_env(:barkpark, :webhook_http_adapter, BlockingHTTP)
    Application.put_env(:barkpark, :test_blocking_pid, self())

    on_exit(fn ->
      set_or_delete(:webhook_delivery_concurrency, prev_conc)
      Application.delete_env(:barkpark, :test_blocking_pid)
    end)

    # M = cap+3 webhooks all matching the "publish" event, so the fan-out must
    # queue more than the concurrency cap allows to run at once.
    extra =
      for i <- 1..3 do
        {:ok, w} =
          Webhooks.create_webhook(%{
            "name" => "burst#{i}",
            "url" => "http://example.test/hook#{i}",
            "dataset" => "test",
            "secret" => "sek",
            "events" => ["publish"]
          })

        w
      end

    m = 1 + length(extra)
    _ = wh

    eid = new_event_id()
    Dispatcher.dispatch_async("test", "publish", "widget", "d1", %{"_id" => "d1"}, eid)

    # Cap holds: exactly `cap` deliveries block; the (cap+1)th must NOT start
    # while the first `cap` are parked.
    assert_receive {:blocked, p1}, 2_000
    assert_receive {:blocked, p2}, 2_000
    refute_receive {:blocked, _}, 300
    assert length(Task.Supervisor.children(Barkpark.WebhookDeliverySupervisor)) <= cap

    # Drain: release each parked delivery; the next queued one starts, cap still
    # holds, until ALL M have been attempted (none silently dropped).
    send(p1, :release)
    send(p2, :release)

    for _ <- 1..(m - cap) do
      assert_receive {:blocked, p}, 2_000
      assert length(Task.Supervisor.children(Barkpark.WebhookDeliverySupervisor)) <= cap
      send(p, :release)
    end

    # No extra deliveries beyond the M webhooks were spawned.
    refute_receive {:blocked, _}, 300
  end
end
