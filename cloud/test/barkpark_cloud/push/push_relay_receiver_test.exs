defmodule BarkparkCloud.Push.PushRelayReceiverTest do
  @moduledoc """
  Push-relay spike (mobile charter D15b/D15c) — Cloud's inbound receiver for the
  instance-originated chat_blocked webhook, end to end:

      POST /v1/relay/chat-blocked/:barkpark_id   NO auth — HMAC IS the auth

  `content_publish_receiver_test.exs`'s sibling. Proves:

    * signature contract (the box's Webhooks.Dispatcher scheme —
      `t=<unix>,v1=<hex>` = HMAC-SHA256 over "<t>.<raw-body>", ±300s):
      valid → 202; forged / stale / tampered-body-under-valid-sig / missing →
      401, nothing enqueued;
    * TRUE replay dedupe (mob-bl-push-hardening): an identical signed re-send
      inside the window still 202s but enqueues ZERO new jobs
      (PushDeliveryWorker args-uniqueness); a fresh `blocked_since` — a
      genuinely new event — is never deduped;
    * probe-proofing: unknown barkpark and no-relay-configured barkpark are the
      SAME 404;
    * fan-out mapping (D15c): owning team's members' unrevoked devices each get
      ONE PushDeliveryWorker job; revoked rows and other teams' devices never do;
    * ROW-ABSENCE severability: zero registrations → 202 {enqueued: 0}, no jobs —
      the relay is inert with no rows and no flags;
    * NO payload widening: job args carry exactly the D59h 5 fields; extra keys
      an instance sends are dropped;
    * a payload without session_id (nothing to deep-link to) → 422.
  """
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Push, Registry, Repo}
  alias BarkparkCloud.Web.Router
  alias BarkparkCloud.Workers.PushDeliveryWorker

  @opts Router.init([])

  @payload %{
    "session_id" => "sess-42",
    "title" => "Deploy the docs site?",
    "workspace_id" => "ws-acme",
    "blocked_since" => "2026-07-24T10:00:00Z",
    "ask_role" => "approver"
  }

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp member_fixture(team, role \\ "member") do
    user = user_fixture()
    {:ok, _} = Accounts.add_member(team, user, role)
    user
  end

  # A barkpark WITH a minted push-relay secret. Returns {barkpark, secret}.
  defp relay_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, secret, bp} = Registry.mint_push_relay_secret(bp)
    {bp, secret}
  end

  defp register_device(user, platform \\ "apns") do
    {:ok, device} =
      Push.register_device_token(user, %{
        "platform" => platform,
        "token" => "device-token-#{System.unique_integer([:positive])}"
      })

    device
  end

  # Sign a body the way the box's Webhooks.Dispatcher does: HMAC-SHA256 over
  # "<timestamp>.<body>", lower-hex, in a `t=<unix>,v1=<hex>` header.
  defp sign(secret, ts, body) do
    v1 = :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)
    "t=#{ts},v1=#{v1}"
  end

  defp deliver(barkpark_id, body, sig) do
    conn(:post, "/v1/relay/chat-blocked/#{barkpark_id}", body)
    |> put_req_header("content-type", "application/json")
    |> maybe_sig(sig)
    |> Router.call(@opts)
  end

  defp maybe_sig(conn, nil), do: conn
  defp maybe_sig(conn, sig), do: put_req_header(conn, "x-barkpark-signature", sig)

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp signed_deliver(bp, secret, payload) do
    body = Jason.encode!(payload)
    deliver(bp.id, body, sign(secret, System.system_time(:second), body))
  end

  ## ---------------------------------------------------------------------------

  describe "signature verification (the box's Dispatcher scheme)" do
    test "a valid signature 202s and enqueues one job per registered device" do
      team = team_fixture()
      {bp, secret} = relay_barkpark(team)
      device = register_device(member_fixture(team))

      conn = signed_deliver(bp, secret, @payload)

      assert conn.status == 202
      assert %{"ok" => true, "enqueued" => 1} = json_body(conn)

      assert_enqueued(
        worker: PushDeliveryWorker,
        args: %{
          "device_push_token_id" => device.id,
          "event" => "chat_blocked",
          "payload" => @payload
        }
      )
    end

    test "a FORGED signature 401s and enqueues nothing" do
      team = team_fixture()
      {bp, _secret} = relay_barkpark(team)
      register_device(member_fixture(team))

      body = Jason.encode!(@payload)
      forged = "t=#{System.system_time(:second)},v1=#{String.duplicate("0", 64)}"
      conn = deliver(bp.id, body, forged)

      assert conn.status == 401
      assert json_body(conn)["error"] == "bad_signature"
      refute_enqueued(worker: PushDeliveryWorker)
    end

    test "a STALE (>300s) timestamp 401s even though the HMAC itself is correct" do
      team = team_fixture()
      {bp, secret} = relay_barkpark(team)
      register_device(member_fixture(team))

      body = Jason.encode!(@payload)
      stale_ts = System.system_time(:second) - 400
      conn = deliver(bp.id, body, sign(secret, stale_ts, body))

      assert conn.status == 401
      refute_enqueued(worker: PushDeliveryWorker)
    end

    test "a TAMPER (a valid signature over a different body) 401s" do
      team = team_fixture()
      {bp, secret} = relay_barkpark(team)
      register_device(member_fixture(team))

      original = Jason.encode!(@payload)
      good_sig = sign(secret, System.system_time(:second), original)
      tampered = Jason.encode!(Map.put(@payload, "session_id", "sess-evil"))

      conn = deliver(bp.id, tampered, good_sig)

      assert conn.status == 401
      refute_enqueued(worker: PushDeliveryWorker)
    end

    test "a TRUE REPLAY (identical signed request twice) enqueues ZERO new jobs" do
      # mob-bl-push-hardening: inside the ±300s HMAC window an identical
      # re-send verifies fine (the signature IS valid) — dedupe happens at the
      # Oban layer via PushDeliveryWorker's args-uniqueness window, and the
      # receiver still answers 202 (a webhook sender must not retry-storm).
      team = team_fixture()
      {bp, secret} = relay_barkpark(team)
      register_device(member_fixture(team))

      body = Jason.encode!(@payload)
      sig = sign(secret, System.system_time(:second), body)

      first = deliver(bp.id, body, sig)
      assert first.status == 202
      assert json_body(first)["enqueued"] == 1

      replay = deliver(bp.id, body, sig)
      assert replay.status == 202
      assert json_body(replay)["enqueued"] == 0

      assert length(all_enqueued(worker: PushDeliveryWorker)) == 1
    end

    test "a genuinely NEW event for the same session (fresh blocked_since) is NOT deduped" do
      team = team_fixture()
      {bp, secret} = relay_barkpark(team)
      register_device(member_fixture(team))

      assert signed_deliver(bp, secret, @payload).status == 202

      fresh = Map.put(@payload, "blocked_since", "2026-07-24T11:30:00Z")
      conn = signed_deliver(bp, secret, fresh)

      assert conn.status == 202
      assert json_body(conn)["enqueued"] == 1
      assert length(all_enqueued(worker: PushDeliveryWorker)) == 2
    end

    test "a missing signature header 401s" do
      team = team_fixture()
      {bp, _secret} = relay_barkpark(team)

      conn = deliver(bp.id, Jason.encode!(@payload), nil)
      assert conn.status == 401
    end

    test "an unknown barkpark id → 404" do
      body = Jason.encode!(@payload)
      ts = System.system_time(:second)
      conn = deliver(Ecto.UUID.generate(), body, sign("whatever", ts, body))
      assert conn.status == 404
    end

    test "a barkpark with NO relay secret configured → the same 404 (no probe leak)" do
      team = team_fixture()
      n = System.unique_integer([:positive])
      {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
      assert {:ok, nil} = Registry.reveal_push_relay_secret(bp)

      body = Jason.encode!(@payload)
      ts = System.system_time(:second)
      conn = deliver(bp.id, body, sign("whatever", ts, body))

      assert conn.status == 404
      assert json_body(conn)["error"] == "not_found"
    end
  end

  describe "fan-out mapping (D15c: barkpark → team → members → devices)" do
    test "every unrevoked device of every team member gets a job; other teams never do" do
      team = team_fixture()
      {bp, secret} = relay_barkpark(team)

      member_a = member_fixture(team)
      member_b = member_fixture(team, "owner")
      a_phone = register_device(member_a, "apns")
      a_tablet = register_device(member_a, "fcm")
      b_phone = register_device(member_b, "apns")

      # A revoked device on the SAME team must be excluded.
      revoked = register_device(member_b, "fcm")
      revoked |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update!()

      # Another team's member with a live device must NEVER be selected.
      other_team = team_fixture()
      register_device(member_fixture(other_team))

      conn = signed_deliver(bp, secret, @payload)

      assert conn.status == 202
      assert json_body(conn)["enqueued"] == 3

      enqueued_ids =
        all_enqueued(worker: PushDeliveryWorker)
        |> Enum.map(& &1.args["device_push_token_id"])
        |> Enum.sort()

      assert enqueued_ids == Enum.sort([a_phone.id, a_tablet.id, b_phone.id])
    end

    test "ROW-ABSENCE severability: zero registrations → 202 {enqueued: 0}, nothing fires" do
      team = team_fixture()
      {bp, secret} = relay_barkpark(team)
      _member_without_devices = member_fixture(team)

      conn = signed_deliver(bp, secret, @payload)

      assert conn.status == 202
      assert %{"ok" => true, "enqueued" => 0} = json_body(conn)
      refute_enqueued(worker: PushDeliveryWorker)
    end

    test "NO payload widening: extra keys are dropped; args carry exactly the D59h 5 fields" do
      team = team_fixture()
      {bp, secret} = relay_barkpark(team)
      register_device(member_fixture(team))

      widened = Map.merge(@payload, %{"message_body" => "SECRET", "user_email" => "x@y.z"})
      conn = signed_deliver(bp, secret, widened)

      assert conn.status == 202
      [job] = all_enqueued(worker: PushDeliveryWorker)
      assert job.args["payload"] == @payload
    end

    test "a payload without session_id → 422 (nothing to deep-link to)" do
      team = team_fixture()
      {bp, secret} = relay_barkpark(team)
      register_device(member_fixture(team))

      conn = signed_deliver(bp, secret, Map.delete(@payload, "session_id"))

      assert conn.status == 422
      assert json_body(conn)["error"] == "invalid_payload"
      refute_enqueued(worker: PushDeliveryWorker)
    end
  end

  describe "secret custody (D15b: registry row, Vault-encrypted like admin tokens)" do
    test "mint stores ciphertext (never plaintext) and reveal round-trips" do
      team = team_fixture()
      {bp, secret} = relay_barkpark(team)

      assert is_binary(bp.push_relay_secret_encrypted)
      assert bp.push_relay_secret_encrypted != secret
      assert {:ok, ^secret} = Registry.reveal_push_relay_secret(bp)
    end
  end
end
