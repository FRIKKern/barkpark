defmodule BarkparkCloud.Push.CredentialGateTest do
  @moduledoc """
  The wave-2 relay build's central claim, tested rather than asserted: the relay
  is COMPLETE and INERT, and both halves of its severability are ABSENCE — never
  a feature flag, never a dead branch.

    * **Credential absence.** With the real adapters present in the tree and no
      APNs/FCM secrets anywhere, `Push.adapter_for/1` resolves to
      `Adapters.NotConfigured` for both platforms and the delivery worker
      returns a terminal `{:cancel, :not_configured}` — without raising, without
      retrying, and without revoking the user's device row (a missing
      credential is an operator fact, not a dead device).

    * **Row absence.** Delete the device rows and the whole pipeline goes quiet:
      the receiver still verifies its HMAC and answers 202, the fan-out selects
      nothing, zero jobs exist. With a row, jobs appear — so the negative is not
      vacuous.

  `async: false`: `:push_adapter` is node-global application env, and this
  module deliberately swaps it to `:auto` (the prod value) to exercise the real
  resolution the rest of the suite bypasses via `PushFakeAdapter`.
  """
  use BarkparkCloud.DataCase, async: false
  use Oban.Testing, repo: BarkparkCloud.Repo
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Push, Registry, Repo}
  alias BarkparkCloud.Push.Adapters
  alias BarkparkCloud.Push.DevicePushToken
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

  setup do
    # Swap to the PROD resolution for this module: :auto = pick the real
    # adapter per platform iff its credentials exist. They do not.
    previous = Application.get_env(:barkpark_cloud, :push_adapter)
    Application.put_env(:barkpark_cloud, :push_adapter, :auto)
    Application.delete_env(:barkpark_cloud, Adapters.APNS)
    Application.delete_env(:barkpark_cloud, Adapters.FCM)

    on_exit(fn -> Application.put_env(:barkpark_cloud, :push_adapter, previous) end)
    :ok
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp device_fixture(user, platform \\ "apns") do
    {:ok, device} =
      Push.register_device_token(user, %{
        "platform" => platform,
        "token" => "device-token-#{System.unique_integer([:positive])}"
      })

    device
  end

  # Sign a body the way the box's Webhooks.Dispatcher does: HMAC-SHA256 over
  # "<timestamp>.<body>", lower-hex, in a `t=<unix>,v1=<hex>` header.
  defp signed_deliver(bp, secret, payload) do
    body = Jason.encode!(payload)
    ts = System.system_time(:second)
    v1 = :crypto.mac(:hmac, :sha256, secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)

    conn(:post, "/v1/relay/chat-blocked/#{bp.id}", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-barkpark-signature", "t=#{ts},v1=#{v1}")
    |> Router.call(@opts)
  end

  describe "credential absence" do
    test "with an EMPTY config both platforms resolve to NotConfigured" do
      assert Push.adapter_for("apns") == Adapters.NotConfigured
      assert Push.adapter_for("fcm") == Adapters.NotConfigured
      # An unknown platform can never fall through to a real sender either.
      assert Push.adapter_for("carrier-pigeon") == Adapters.NotConfigured

      assert Push.credential_status() == %{"apns" => false, "fcm" => false}
    end

    test "the delivery worker NO-OPS terminally instead of raising, for both platforms" do
      user = user_fixture()

      for platform <- ["apns", "fcm"] do
        device = device_fixture(user, platform)

        assert {:cancel, :not_configured} =
                 perform_job(PushDeliveryWorker, %{
                   "device_push_token_id" => device.id,
                   "event" => "chat_blocked",
                   "payload" => @payload
                 })

        # A missing credential says NOTHING about the device: the row survives
        # untouched, so the relay starts working the moment a secret appears.
        reloaded = Repo.get!(DevicePushToken, device.id)
        assert is_nil(reloaded.revoked_at)
        assert is_nil(reloaded.last_used_at)
      end
    end

    test "the real adapters exist in the tree and refuse honestly when unconfigured" do
      # The point of the build: these modules ARE here (PR #6030's review
      # stamped 'zero APNs/FCM code anywhere on main'), and they decline
      # rather than pretend.
      assert Code.ensure_loaded?(Adapters.APNS)
      assert Code.ensure_loaded?(Adapters.FCM)
      refute Adapters.APNS.configured?()
      refute Adapters.FCM.configured?()

      device = %DevicePushToken{platform: "apns", token: "t"}
      assert Adapters.APNS.send_push(device, %{}) == {:error, :not_configured}
      assert Adapters.FCM.send_push(device, %{}) == {:error, :not_configured}
    end
  end

  describe "row absence (D15 severability, re-proven not assumed)" do
    setup do
      n = System.unique_integer([:positive])
      {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
      user = user_fixture()
      {:ok, _} = Accounts.add_member(team, user, "member")
      {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
      {:ok, secret, bp} = Registry.mint_push_relay_secret(bp)
      {:ok, bp: bp, secret: secret, user: user}
    end

    test "WITH a row, a verified webhook enqueues (the positive control)", ctx do
      _device = device_fixture(ctx.user)

      conn = signed_deliver(ctx.bp, ctx.secret, @payload)

      assert conn.status == 202
      assert Jason.decode!(conn.resp_body)["enqueued"] == 1
      assert_enqueued(worker: PushDeliveryWorker)
    end

    test "DELETE the row and the same verified webhook goes silent — no flags consulted", ctx do
      device = device_fixture(ctx.user)
      Repo.delete!(device)

      conn = signed_deliver(ctx.bp, ctx.secret, @payload)

      # The HMAC still verifies and the receiver still answers 202 — the relay
      # is not "off", there is simply nobody to notify. Zero jobs, zero flags,
      # and not one branch in the path reads a feature toggle.
      assert conn.status == 202
      assert Jason.decode!(conn.resp_body)["enqueued"] == 0
      refute_enqueued(worker: PushDeliveryWorker)
    end

    test "a REVOKED row is as absent as a deleted one", ctx do
      device = device_fixture(ctx.user)
      device |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update!()

      conn = signed_deliver(ctx.bp, ctx.secret, @payload)

      assert Jason.decode!(conn.resp_body)["enqueued"] == 0
      refute_enqueued(worker: PushDeliveryWorker)
    end
  end
end
