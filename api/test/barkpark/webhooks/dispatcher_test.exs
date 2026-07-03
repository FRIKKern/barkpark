defmodule Barkpark.Webhooks.DispatcherTest do
  use Barkpark.DataCase, async: false
  use Oban.Testing, repo: Barkpark.Repo
  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Dispatcher
  alias Barkpark.Webhooks.RetryWorker
  alias Barkpark.Webhooks.StuckDeliverySweeper

  # A retryable failure no longer sleeps in-task — it schedules a `RetryWorker`
  # job. Draining the `:default` queue (scheduled + recursively) runs the whole
  # retry chain to its terminal state so a single call settles the delivery, the
  # deterministic stand-in for wall-clock backoff elapsing.
  defp drain_retries do
    Oban.drain_queue(queue: :default, with_scheduled: true, with_recursion: true)
  end

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

  test "500 → 500 → 200 yields 2 scheduled retries then success", %{webhook: wh} do
    :ok = FakeHTTP.start([{:ok, 500}, {:ok, 500}, {:ok, 200}])
    eid = new_event_id()

    # First attempt (500) schedules a retry and RETURNS — slot freed, not slept.
    assert {:scheduled, _id, 2} = Dispatcher.deliver(wh, "{}", eid)
    assert length(FakeHTTP.calls()) == 1

    # Draining runs the scheduled retry chain to its terminal state.
    drain_retries()
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

    assert {:scheduled, _id, 2} = Dispatcher.deliver(wh, "{}", eid)
    drain_retries()
    assert length(FakeHTTP.calls()) == 3

    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "failed_giveup"
    assert d.attempts == 3
  end

  test "429 is retried (not dropped) and eventually gives up at max attempts", %{webhook: wh} do
    # Regression: a 429 used to fall into the terminal 4xx branch and DROP the
    # delivery — losing the cache-revalidation event. It must now retry like a
    # 5xx, then give up at max_attempts (still bounded).
    :ok = FakeHTTP.start([{:ok, 429, []}, {:ok, 429, []}, {:ok, 429, []}])
    eid = new_event_id()

    assert {:scheduled, _id, 2} = Dispatcher.deliver(wh, "{}", eid)
    drain_retries()
    assert length(FakeHTTP.calls()) == 3

    d = Webhooks.get_delivery(wh.id, eid)
    assert d.status == "failed_giveup"
    assert d.last_status_code == 429
  end

  test "408 and 425 are retried then recover", %{webhook: wh} do
    for status <- [408, 425] do
      :ok = FakeHTTP.start([{:ok, status, []}, {:ok, 200}])
      eid = new_event_id()

      assert {:scheduled, _id, 2} = Dispatcher.deliver(wh, "{}", eid)
      drain_retries()
      assert length(FakeHTTP.calls()) == 2

      assert Webhooks.get_delivery(wh.id, eid).status == "ok"
    end
  end

  test "429 with Retry-After header retries then recovers (honors the header)", %{webhook: wh} do
    # retry-after: 0 exercises the honor-the-header path without slowing the test.
    :ok = FakeHTTP.start([{:ok, 429, [{"retry-after", "0"}]}, {:ok, 200}])
    eid = new_event_id()

    assert {:scheduled, _id, 2} = Dispatcher.deliver(wh, "{}", eid)
    drain_retries()
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

    assert {:scheduled, _id, 2} = Dispatcher.deliver(wh, "{}", eid)
    drain_retries()
    assert length(FakeHTTP.calls()) == 2

    assert Webhooks.get_delivery(wh.id, eid).status == "ok"
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

  describe "blank secret → unsigned delivery (no fake empty-key HMAC)" do
    import ExUnit.CaptureLog

    setup do
      # Same endpoint as the seed webhook but with NO secret. persisted so
      # Dispatcher.deliver/3 can claim a durable delivery row.
      {:ok, wh} =
        Webhooks.create_webhook(%{
          "name" => "ep-nosecret",
          "url" => "http://example.test/nosecret",
          "dataset" => "test",
          "secret" => "",
          "events" => ["publish"]
        })

      %{nosecret_webhook: wh}
    end

    test "delivers WITHOUT the signature header when the secret is blank", %{
      nosecret_webhook: wh
    } do
      :ok = FakeHTTP.start([{:ok, 200}])
      eid = new_event_id()

      assert {:ok, 200, 1} = Dispatcher.deliver(wh, ~s({"a":1}), eid)
      [{_url, _body, headers}] = FakeHTTP.calls()
      hmap = Map.new(headers)

      # Signature + its redundant timestamp are OMITTED — an empty-key HMAC would
      # be fake authenticity; an absent header is honestly "unsigned".
      refute Map.has_key?(hmap, "x-barkpark-signature")
      refute Map.has_key?(hmap, "x-barkpark-timestamp")

      # Everything else is unchanged: content-type + delivery-id still present.
      assert hmap["content-type"] == "application/json"
      assert hmap["x-barkpark-delivery-id"] == Integer.to_string(eid)
      assert hmap["x-barkpark-event-id"] == Integer.to_string(eid)
    end

    test "logs the unsigned warning ONCE per delivery, not per retry", %{
      nosecret_webhook: wh
    } do
      # 500 → schedule retry → 200: two HTTP attempts across the delivery, but a
      # single unsigned warning (gated to the first attempt).
      :ok = FakeHTTP.start([{:ok, 500}, {:ok, 200}])
      eid = new_event_id()

      log =
        capture_log(fn ->
          assert {:scheduled, _id, 2} = Dispatcher.deliver(wh, "{}", eid)
          drain_retries()
          assert Webhooks.get_delivery(wh.id, eid).status == "ok"
        end)

      warnings =
        log
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ "blank/nil secret" and &1 =~ "UNSIGNED"))

      assert length(warnings) == 1
    end

    test "a whitespace-only secret is also treated as blank" do
      {:ok, wh} =
        Webhooks.create_webhook(%{
          "name" => "ep-wsonly",
          "url" => "http://example.test/wsonly",
          "dataset" => "test",
          "secret" => "   ",
          "events" => ["publish"]
        })

      :ok = FakeHTTP.start([{:ok, 200}])
      eid = new_event_id()

      assert {:ok, 200, 1} = Dispatcher.deliver(wh, "{}", eid)
      [{_url, _body, headers}] = FakeHTTP.calls()
      refute Map.has_key?(Map.new(headers), "x-barkpark-signature")
    end

    test "secret-ful delivery is unchanged: header present and verifies", %{webhook: wh} do
      # `wh` is the seed webhook (secret "sek") — regression guard that the blank
      # path did not alter the signed path.
      :ok = FakeHTTP.start([{:ok, 200}])
      eid = new_event_id()

      assert {:ok, 200, 1} = Dispatcher.deliver(wh, ~s({"a":1}), eid)
      [{_url, body, headers}] = FakeHTTP.calls()
      hmap = Map.new(headers)

      assert is_binary(hmap["x-barkpark-signature"])
      ts = String.to_integer(hmap["x-barkpark-timestamp"])
      assert Dispatcher.verify_signature(body, ts, hmap["x-barkpark-signature"], ["sek"])
    end
  end

  describe "signature_headers/3 + blank_secret?/1" do
    test "blank_secret? recognises nil, empty, and whitespace-only" do
      assert Dispatcher.blank_secret?(nil)
      assert Dispatcher.blank_secret?("")
      assert Dispatcher.blank_secret?("   ")
      refute Dispatcher.blank_secret?("sek")
    end

    test "signature_headers returns [] for a blank secret, signed pair otherwise" do
      assert [] == Dispatcher.signature_headers("{}", 1_700_000_000, nil)
      assert [] == Dispatcher.signature_headers("{}", 1_700_000_000, "")

      headers = Dispatcher.signature_headers("{}", 1_700_000_000, "sek")
      hmap = Map.new(headers)
      assert hmap["x-barkpark-signature"] =~ ",v1="
      assert hmap["x-barkpark-timestamp"] == "1700000000"
    end
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

  describe "scheduled re-enqueue (bounded-slot fix)" do
    # Routes by URL so the async_stream fan-out test can hold one endpoint in a
    # retry loop while another stays healthy, regardless of delivery order.
    defmodule RoutingHTTP do
      def post(url, _body, _headers) do
        if String.contains?(url, "slow"), do: {:ok, 500}, else: {:ok, 200}
      end
    end

    defp eventually(fun, tries \\ 100) do
      cond do
        fun.() -> true
        tries <= 0 -> false
        true -> Process.sleep(20) && eventually(fun, tries - 1)
      end
    end

    test "a retryable failure schedules a RetryWorker at the computed delay and frees the slot",
         %{webhook: wh} do
      # Retry-After: 2 → a deterministic 2000ms schedule offset (no jitter).
      :ok = FakeHTTP.start([{:ok, 429, [{"retry-after", "2"}]}, {:ok, 200}])
      eid = new_event_id()
      before = DateTime.utc_now()

      # First attempt (429) schedules the retry and RETURNS — the slot is freed,
      # not parked in Process.sleep for the backoff.
      assert {:scheduled, delivery_id, 2} = Dispatcher.deliver(wh, "{}", eid)
      assert length(FakeHTTP.calls()) == 1

      # The row is fenced for its next attempt, still pending (attempts advanced).
      d = Webhooks.get_delivery(wh.id, eid)
      assert d.id == delivery_id
      assert d.status == "pending"
      assert d.attempts == 1

      # Exactly one scheduled RetryWorker job, targeting this row, ~2s out.
      assert [job] = all_enqueued(worker: RetryWorker)
      assert job.args["delivery_id"] == delivery_id
      assert job.args["attempt"] == 1
      offset_ms = DateTime.diff(job.scheduled_at, before, :millisecond)
      assert offset_ms >= 1_500 and offset_ms <= 2_500
    end

    test "the scheduled retry and a crash-sweep cannot both deliver (shared updated_at fence)",
         %{webhook: wh} do
      :ok = FakeHTTP.start([{:ok, 200}])
      eid = new_event_id()

      # The exact state after a retryable first attempt: a pending row + a
      # RetryWorker fenced on the row's current updated_at.
      {:ok, d} = Webhooks.claim_delivery(wh.id, eid)

      {:ok, _job} =
        %{
          "delivery_id" => d.id,
          "attempt" => 1,
          "fence" => DateTime.to_iso8601(d.updated_at)
        }
        |> RetryWorker.new(scheduled_at: DateTime.utc_now())
        |> Oban.insert()

      # A crash-sweep fires FIRST and CAS-claims the SAME fence, then delivers.
      assert %{swept: 1} = StuckDeliverySweeper.sweep(0)
      assert Webhooks.get_delivery(wh.id, eid).status == "ok"
      assert length(FakeHTTP.calls()) == 1

      # Draining the scheduled retry now no-ops: its fence no longer matches the
      # (bumped, terminal) row, so it cannot re-deliver. No second HTTP call.
      drain_retries()
      assert length(FakeHTTP.calls()) == 1
      assert Webhooks.get_delivery(wh.id, eid).status == "ok"
    end

    test "a retrying delivery frees its slot so healthy endpoints are not head-of-line blocked",
         %{webhook: wh} do
      Application.put_env(:barkpark, :webhook_http_adapter, RoutingHTTP)
      prev_conc = Application.get_env(:barkpark, :webhook_delivery_concurrency)
      Application.put_env(:barkpark, :webhook_delivery_concurrency, 1)
      on_exit(fn -> set_or_delete(:webhook_delivery_concurrency, prev_conc) end)

      {:ok, slow} =
        Webhooks.create_webhook(%{
          "name" => "slow",
          "url" => "http://example.test/slow",
          "dataset" => "test",
          "secret" => "s",
          "events" => ["publish"]
        })

      {:ok, healthy} =
        Webhooks.create_webhook(%{
          "name" => "healthy",
          "url" => "http://example.test/healthy",
          "dataset" => "test",
          "secret" => "s",
          "events" => ["publish"]
        })

      _ = wh
      eid = new_event_id()
      Dispatcher.dispatch_async("test", "publish", "widget", "d1", %{"_id" => "d1"}, eid)

      # Even at concurrency 1, the healthy delivery reaches `ok` — the retrying
      # one scheduled its retry and freed the slot instead of sleeping in it.
      assert eventually(fn ->
               match?(%{status: "ok"}, Webhooks.get_delivery(healthy.id, eid))
             end)

      # The slow endpoint is parked as a SCHEDULED retry (pending), NOT driven to
      # a synchronous give-up while holding the slot (the old in-task behaviour).
      slow_d = Webhooks.get_delivery(slow.id, eid)
      assert slow_d.status == "pending"
      assert Enum.any?(all_enqueued(worker: RetryWorker), &(&1.args["delivery_id"] == slow_d.id))
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

  defp reload_wh(wh), do: Barkpark.Repo.get!(Barkpark.Webhooks.Webhook, wh.id)

  # One TRUE terminal give-up (permanent 4xx) against `wh`, on a fresh event.
  defp giveup_once(wh) do
    :ok = FakeHTTP.start([{:ok, 400}])
    eid = new_event_id()
    assert {:error, :giveup_4xx, 1} = Dispatcher.deliver(wh, "{}", eid)
  end

  defp active_ids do
    Webhooks.active_webhooks_for("test", "publish", "widget") |> Enum.map(& &1.id)
  end

  describe "auto-disable of permanently-dead endpoints" do
    setup do
      prev = Application.get_env(:barkpark, :webhook_auto_disable_threshold)
      # A low threshold keeps the streak tests fast + deterministic.
      Application.put_env(:barkpark, :webhook_auto_disable_threshold, 3)
      on_exit(fn -> set_or_delete(:webhook_auto_disable_threshold, prev) end)
      :ok
    end

    test "N consecutive terminal give-ups auto-disable the endpoint and skip it", %{webhook: wh} do
      # Below the threshold: still active, counter climbing.
      giveup_once(wh)
      giveup_once(wh)
      mid = reload_wh(wh)
      assert mid.consecutive_failures == 2
      assert mid.active == true
      assert is_nil(mid.auto_disabled_at)
      assert wh.id in active_ids()

      # The give-up that crosses the threshold flips it inactive + stamps why.
      giveup_once(wh)
      dead = reload_wh(wh)
      assert dead.consecutive_failures == 3
      assert dead.active == false
      refute is_nil(dead.auto_disabled_at)
      assert dead.disable_reason =~ "auto-disabled after 3 consecutive"

      # Skipped: a disabled endpoint drops out of selection — no wasted attempts.
      refute wh.id in active_ids()
    end

    test "a success mid-streak resets the counter (no disable)", %{webhook: wh} do
      giveup_once(wh)
      giveup_once(wh)
      assert reload_wh(wh).consecutive_failures == 2

      # A single successful delivery clears the streak.
      :ok = FakeHTTP.start([{:ok, 200}])
      eid = new_event_id()
      assert {:ok, 200, 1} = Dispatcher.deliver(wh, "{}", eid)
      assert reload_wh(wh).consecutive_failures == 0

      # Two more give-ups now sit at 2 (< threshold 3) — a healthy endpoint with
      # transient blips is never auto-disabled.
      giveup_once(wh)
      giveup_once(wh)
      w = reload_wh(wh)
      assert w.consecutive_failures == 2
      assert w.active == true
    end

    test "re-enable fully restores the endpoint and it re-delivers", %{webhook: wh} do
      for _ <- 1..3, do: giveup_once(wh)
      dead = reload_wh(wh)
      assert dead.active == false

      {:ok, revived} = Webhooks.reenable_webhook(dead)
      assert revived.active == true
      assert revived.consecutive_failures == 0
      assert is_nil(revived.auto_disabled_at)
      assert is_nil(revived.disable_reason)

      # Back in selection, and a delivery now goes through.
      assert wh.id in active_ids()
      :ok = FakeHTTP.start([{:ok, 200}])
      eid = new_event_id()
      assert {:ok, 200, 1} = Dispatcher.deliver(revived, "{}", eid)
      assert Webhooks.get_delivery(wh.id, eid).status == "ok"
    end

    test "retried 429s do NOT increment the counter (only terminal give-ups count)", %{
      webhook: wh
    } do
      # Two 429-then-200 cycles: each 429 is RETRIED, not a terminal give-up, and
      # the eventual 200 records success. The counter never moves off 0, so a
      # rate-limited-but-alive endpoint is never auto-disabled (threshold is 3).
      for _ <- 1..2 do
        :ok = FakeHTTP.start([{:ok, 429, []}, {:ok, 200}])
        eid = new_event_id()
        assert {:scheduled, _id, 2} = Dispatcher.deliver(wh, "{}", eid)
        drain_retries()
      end

      w = reload_wh(wh)
      assert w.consecutive_failures == 0
      assert w.active == true
    end
  end
end
