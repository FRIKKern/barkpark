defmodule BarkparkCloud.Push.DeviceTokenRateLimitTest do
  @moduledoc """
  Push-relay wave-2 hardening (mob-bl-push-hardening) — the `push_register`
  bucket on POST /v1/push/device-tokens:

    * `push_register:<user_id>` → 429 past 10 hits/min for that USER;
    * per-USER scoping: one user's flood never brakes another user (mobile
      clients share carrier-NAT IPs — that is why the key is the user id,
      the approve:<user_id> idiom, not peer-ip);
    * action-scoped: the flood leaves the same principal's other buckets
      untouched.

  async: false — the rate-limit legs share the DeviceAuth.RateLimiter ETS
  table (`router_app_token_revoke_test.exs`'s idiom).
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.DeviceAuth.RateLimiter, as: DeviceAuthRateLimiter
  alias BarkparkCloud.Push.DevicePushToken
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  setup do
    DeviceAuthRateLimiter.reset()
    on_exit(fn -> DeviceAuthRateLimiter.reset() end)
    :ok
  end

  defp user_with_session do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, token} = Accounts.create_user_session_token(user)
    {user, token}
  end

  defp register(token, body) do
    conn(:post, "/v1/push/device-tokens", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  test "the 11th registration/min for one user → 429; another user still registers" do
    {user, session} = user_with_session()

    for i <- 1..10 do
      conn = register(session, %{"platform" => "apns", "token" => "flood-token-#{i}"})
      assert conn.status == 201, "hit #{i} should be under the limit, got #{conn.status}"
    end

    conn = register(session, %{"platform" => "apns", "token" => "flood-token-11"})
    assert conn.status == 429
    assert json_body(conn)["error"] == "rate_limited"

    # Per-USER bucket: a different user on the (same test) IP is untouched.
    {_other, other_session} = user_with_session()
    conn = register(other_session, %{"platform" => "apns", "token" => "other-user-token"})
    assert conn.status == 201

    # Action-scoped: the flood leaves the same principal's other buckets alone.
    assert DeviceAuthRateLimiter.check("approve:" <> user.id) == :ok
    assert DeviceAuthRateLimiter.check("app_token:127.0.0.1") == :ok
  end

  test "a rate-braked request writes NO row (the brake fires before the upsert)" do
    {user, session} = user_with_session()

    # Exhaust the bucket without endpoint work.
    for _ <- 1..10 do
      assert DeviceAuthRateLimiter.check("push_register:" <> user.id) == :ok
    end

    conn = register(session, %{"platform" => "apns", "token" => "braked-token"})
    assert conn.status == 429

    count = Repo.aggregate(from(t in DevicePushToken, where: t.user_id == ^user.id), :count)
    assert count == 0
  end
end
