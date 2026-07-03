defmodule Barkpark.WebhooksTest do
  use Barkpark.DataCase, async: false

  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.{Webhook, Dispatcher}

  test "create and list webhooks" do
    {:ok, wh} =
      Webhooks.create_webhook(%{
        "name" => "Test",
        "url" => "http://example.com/hook",
        "dataset" => "test"
      })

    assert wh.name == "Test"
    assert wh.active == true

    hooks = Webhooks.list_webhooks("test")
    assert length(hooks) == 1
  end

  test "update a webhook" do
    {:ok, wh} =
      Webhooks.create_webhook(%{
        "name" => "Test",
        "url" => "http://example.com/hook",
        "dataset" => "test"
      })

    {:ok, updated} = Webhooks.update_webhook(wh, %{"active" => false})
    assert updated.active == false
  end

  describe "update_webhook re-enable semantics (D55)" do
    # Build an auto-disabled hook the way the dispatcher does: raw update_all of
    # the server-managed columns (they are NOT client-castable), so the fixture
    # matches a real kill-streak + stamp state on disk.
    defp auto_disabled_hook do
      {:ok, wh} =
        Webhooks.create_webhook(%{
          "name" => "Disabled",
          "url" => "http://example.com/hook",
          "dataset" => "test"
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {1, _} =
        from(w in Webhook, where: w.id == ^wh.id)
        |> Repo.update_all(
          set: [
            active: false,
            consecutive_failures: 25,
            auto_disabled_at: now,
            disable_reason: "auto-disabled after 25 consecutive delivery failures (last: http 500)"
          ]
        )

      Repo.get!(Webhook, wh.id)
    end

    test "PUT {active:true} on an auto-disabled hook clears streak + auto-disable stamps" do
      wh = auto_disabled_hook()
      assert wh.active == false
      assert wh.consecutive_failures == 25
      assert wh.auto_disabled_at != nil
      assert wh.disable_reason != nil

      {:ok, updated} = Webhooks.update_webhook(wh, %{"active" => true})

      assert updated.active == true
      # The stale kill-streak + stamps are gone — otherwise the next single
      # terminal give-up would re-cross the threshold and re-disable it.
      assert updated.consecutive_failures == 0
      assert updated.auto_disabled_at == nil
      assert updated.disable_reason == nil
    end

    test "the false→true re-enable merges with other field updates in one write" do
      wh = auto_disabled_hook()

      {:ok, updated} =
        Webhooks.update_webhook(wh, %{"active" => true, "url" => "http://example.com/new"})

      assert updated.active == true
      assert updated.url == "http://example.com/new"
      assert updated.consecutive_failures == 0
      assert updated.auto_disabled_at == nil
      assert updated.disable_reason == nil
    end

    test "manual disable (active:false) NEVER fabricates a disable_reason (D55)" do
      {:ok, wh} =
        Webhooks.create_webhook(%{
          "name" => "Manual",
          "url" => "http://example.com/hook",
          "dataset" => "test"
        })

      # Pre-seed a streak so we can prove a manual disable does not touch the
      # server-managed columns either (it only flips `active`).
      {1, _} =
        from(w in Webhook, where: w.id == ^wh.id)
        |> Repo.update_all(set: [consecutive_failures: 3])

      wh = Repo.get!(Webhook, wh.id)

      {:ok, updated} = Webhooks.update_webhook(wh, %{"active" => false})

      assert updated.active == false
      # A user-initiated disable is not an auto-disable: no reason, no stamp
      # invented. The auto-disable metadata is written ONLY by the dispatcher.
      assert updated.disable_reason == nil
      assert updated.auto_disabled_at == nil
      assert updated.consecutive_failures == 3
    end

    test "re-enabling an already-active hook is an idempotent no-op on the stamps" do
      {:ok, wh} =
        Webhooks.create_webhook(%{
          "name" => "Active",
          "url" => "http://example.com/hook",
          "dataset" => "test"
        })

      assert wh.active == true

      {:ok, updated} = Webhooks.update_webhook(wh, %{"active" => true, "name" => "Renamed"})

      assert updated.active == true
      assert updated.name == "Renamed"
      assert updated.consecutive_failures == 0
      assert updated.auto_disabled_at == nil
      assert updated.disable_reason == nil
    end
  end

  test "delete a webhook" do
    {:ok, wh} =
      Webhooks.create_webhook(%{
        "name" => "Test",
        "url" => "http://example.com/hook",
        "dataset" => "test"
      })

    {:ok, _} = Webhooks.delete_webhook(wh)
    assert Webhooks.list_webhooks("test") == []
  end

  test "delete_webhook on a struct whose row was already deleted returns {:error, :not_found}, not a StaleEntryError" do
    {:ok, wh} =
      Webhooks.create_webhook(%{
        "name" => "Race",
        "url" => "http://example.com/hook",
        "dataset" => "test"
      })

    # Delete the row behind the struct's back — a concurrent double-DELETE.
    # Before stale_error_field, Repo.delete on the stale struct raised
    # Ecto.StaleEntryError (→ 500 at DELETE /v1/webhooks/:ds/:id).
    {1, _} = Repo.delete_all(from(w in Webhook, where: w.id == ^wh.id))

    assert {:error, :not_found} = Webhooks.delete_webhook(wh)
  end

  test "get_webhook with a malformed (non-UUID) id is {:error, :not_found}, not an Ecto CastError" do
    # id is :binary_id; before the UUID-cast guard a non-UUID crashed the query
    # (500 at GET/PUT/DELETE /v1/webhooks/:ds/:id). Now it's a clean not_found.
    assert {:error, :not_found} = Webhooks.get_webhook("not-a-uuid")
    assert {:error, :not_found} = Webhooks.get_webhook("garbage", dataset: "test")
  end

  test "active_webhooks_for matches event and type" do
    Webhooks.create_webhook(%{
      "name" => "All",
      "url" => "http://example.com/all",
      "dataset" => "test",
      "events" => [],
      "types" => []
    })

    Webhooks.create_webhook(%{
      "name" => "Creates",
      "url" => "http://example.com/create",
      "dataset" => "test",
      "events" => ["create"],
      "types" => []
    })

    Webhooks.create_webhook(%{
      "name" => "Posts",
      "url" => "http://example.com/post",
      "dataset" => "test",
      "events" => [],
      "types" => ["post"]
    })

    Webhooks.create_webhook(%{
      "name" => "Inactive",
      "url" => "http://example.com/off",
      "dataset" => "test",
      "active" => false
    })

    matches = Webhooks.active_webhooks_for("test", "create", "post")
    names = Enum.map(matches, & &1.name) |> Enum.sort()
    assert names == ["All", "Creates", "Posts"]
  end

  test "validates URL format" do
    {:error, changeset} = Webhooks.create_webhook(%{"name" => "Bad", "url" => "not-a-url"})
    assert errors_on(changeset).url != nil
  end

  describe "signing (P1-d)" do
    test "sign_payload returns deterministic v1=<sha256hex> for timestamp.body" do
      body = ~s({"hello":"world"})
      secret = "topsecret"
      ts = 1_700_000_000

      sig = Dispatcher.sign_payload(body, ts, secret)
      assert "v1=" <> hex = sig
      assert String.length(hex) == 64

      # Manual computation matches
      expected_hex =
        :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{body}")
        |> Base.encode16(case: :lower)

      assert sig == "v1=#{expected_hex}"
    end

    test "sign_payload is deterministic across calls" do
      assert Dispatcher.sign_payload("b", 1, "s") == Dispatcher.sign_payload("b", 1, "s")
    end

    test "different secret yields different signature" do
      refute Dispatcher.sign_payload("b", 1, "s1") == Dispatcher.sign_payload("b", 1, "s2")
    end
  end

  describe "dual-secret rotation (P1-d)" do
    test "effective_secrets returns primary + unexpired previous" do
      now = DateTime.utc_now()
      future = DateTime.add(now, 3600, :second)

      wh = %Webhook{secret: "new", previous_secret: "old", previous_secret_expires_at: future}
      assert Webhook.effective_secrets(wh, now) == ["new", "old"]
    end

    test "effective_secrets drops previous once expired" do
      now = DateTime.utc_now()
      past = DateTime.add(now, -3600, :second)

      wh = %Webhook{secret: "new", previous_secret: "old", previous_secret_expires_at: past}
      assert Webhook.effective_secrets(wh, now) == ["new"]
    end

    test "effective_secrets ignores previous when no expiry set" do
      wh = %Webhook{secret: "new", previous_secret: "old", previous_secret_expires_at: nil}
      assert Webhook.effective_secrets(wh) == ["new"]
    end

    test "rotate_secret moves current secret to previous with 24h expiry by default" do
      {:ok, wh} =
        Webhooks.create_webhook(%{
          "name" => "rot",
          "url" => "http://example.com/h",
          "dataset" => "test",
          "secret" => "s1"
        })

      {:ok, rotated} = Webhooks.rotate_secret(wh, "s2")

      assert rotated.secret == "s2"
      assert rotated.previous_secret == "s1"
      assert rotated.previous_secret_expires_at != nil

      diff = DateTime.diff(rotated.previous_secret_expires_at, DateTime.utc_now(), :second)
      assert diff > 86_000 and diff <= 86_400
    end

    test "verify_signature accepts either primary or previous secret" do
      now = DateTime.utc_now()
      future = DateTime.add(now, 3600, :second)

      wh = %Webhook{secret: "new", previous_secret: "old", previous_secret_expires_at: future}
      body = "payload"
      # Fresh timestamp: verify_signature/5 now rejects stale deliveries, so the
      # signed timestamp must sit inside the freshness window.
      ts = System.system_time(:second)

      old_sig = Dispatcher.sign_payload(body, ts, "old")
      new_sig = Dispatcher.sign_payload(body, ts, "new")
      secrets = Webhook.effective_secrets(wh, now)

      assert Dispatcher.verify_signature(body, ts, old_sig, secrets)
      assert Dispatcher.verify_signature(body, ts, new_sig, secrets)
      refute Dispatcher.verify_signature(body, ts, "v1=deadbeef", secrets)
    end

    test "verify_signature rejects a stale (replayed) timestamp even with a valid HMAC" do
      body = "payload"
      old_ts = 1_000
      sig = Dispatcher.sign_payload(body, old_ts, "sek")

      # HMAC is valid, but the signed timestamp is ~1970 → far outside the
      # ±300s window → rejected. This is the replay defense.
      refute Dispatcher.verify_signature(body, old_ts, sig, ["sek"])
      # Same signature, evaluated with `now` pinned next to the signed time,
      # verifies — proving it's the freshness gate (not the HMAC) that rejects.
      assert Dispatcher.verify_signature(body, old_ts, sig, ["sek"], old_ts)
    end
  end

  describe "delivery dedup (P1-d)" do
    setup do
      # Setup-race fix: scope `events` so the seed webhook does NOT match the
      # "create" action fired by `Content.create_document/3` below. Otherwise
      # `tap_broadcast → Dispatcher.dispatch_async` spawns a fire-and-forget
      # Task that claims `(endpoint_id, event_id)` against the shared Ecto
      # sandbox AND attempts a real `Req.post` to `http://example.com/d`,
      # both of which leak into these claim_delivery / mark_delivered tests.
      {:ok, wh} =
        Webhooks.create_webhook(%{
          "name" => "D",
          "url" => "http://example.com/d",
          "dataset" => "test",
          "secret" => "s",
          "events" => ["publish"]
        })

      # A real mutation_events row is needed for the FK. Use Content to create one.
      alias Barkpark.Content

      Content.upsert_schema(
        %{"name" => "widget", "title" => "W", "visibility" => "public", "fields" => []},
        "test"
      )

      {:ok, _doc} =
        Content.create_document("widget", %{"_id" => "dedup1", "title" => "x"}, "test")

      [ev | _] = Barkpark.Repo.all(Barkpark.Content.MutationEvent)
      %{webhook: wh, event_id: ev.id}
    end

    test "claim_delivery returns {:ok, delivery} the first time", %{webhook: wh, event_id: eid} do
      assert {:ok, d} = Webhooks.claim_delivery(wh.id, eid)
      assert d.status == "pending"
      assert d.endpoint_id == wh.id
      assert d.event_id == eid
    end

    test "claim_delivery returns {:error, :already_delivered} on duplicate", %{
      webhook: wh,
      event_id: eid
    } do
      assert {:ok, _d} = Webhooks.claim_delivery(wh.id, eid)
      assert {:error, :already_delivered} = Webhooks.claim_delivery(wh.id, eid)
    end

    test "mark_delivered updates status + attempts", %{webhook: wh, event_id: eid} do
      {:ok, d} = Webhooks.claim_delivery(wh.id, eid)
      {:ok, updated} = Webhooks.mark_delivered(d, 200, 2)
      assert updated.status == "ok"
      assert updated.last_status_code == 200
      assert updated.attempts == 2
    end

    test "mark_giveup records error + attempts", %{webhook: wh, event_id: eid} do
      {:ok, d} = Webhooks.claim_delivery(wh.id, eid)
      {:ok, updated} = Webhooks.mark_giveup(d, 500, "http 500", 3)
      assert updated.status == "failed_giveup"
      assert updated.last_error_text == "http 500"
      assert updated.attempts == 3
    end
  end
end
