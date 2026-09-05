defmodule BarkparkCloud.Web.RouterAppTokenPerUserRateLimitTest do
  @moduledoc """
  acpc-bl-app-token-per-ip-on-authed-route — the `app_token:` and
  `app_token_revoke:` buckets key on the AUTHENTICATED USER, not on peer_ip.

  Both routes open with `Auth.require_user`, so the identity is already
  resolved when the limiter runs. Keying on the IP threw that identity away and
  let two colleagues behind one NAT share a 10/min budget — the exact failure
  `BarkparkCloud.DeviceAuth.RateLimiter`'s docstring rules out for
  `push_register:` ("clients share carrier-NAT IPs, so a per-IP bucket would let
  one user starve strangers").

  The proof drives two users from the SAME remote IP (Plug.Test's default
  127.0.0.1): user A exhausts the budget; user B is NOT braked. Under the old
  per-IP key user B's first call answers 429 — that is the red this file adds.

  async: false — the legs share the RateLimiter ETS table.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.DeviceAuth.RateLimiter, as: DeviceAuthRateLimiter
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery-staple-9!"

  setup do
    DeviceAuthRateLimiter.reset()
    on_exit(fn -> DeviceAuthRateLimiter.reset() end)
    :ok
  end

  defp user_with_team do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "user-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp call(method, path, token) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp exhaust(method, token) do
    for _ <- 1..10 do
      conn = call(method, "/v1/barkparks/#{Ecto.UUID.generate()}/app-token", token)
      assert conn.status == 404
    end

    conn = call(method, "/v1/barkparks/#{Ecto.UUID.generate()}/app-token", token)
    assert conn.status == 429, "the flooding user must still be braked at the 11th call"
  end

  for {label, method, bucket} <- [
        {"POST app-token (mint)", :post, "app_token"},
        {"DELETE app-token (revoke)", :delete, "app_token_revoke"}
      ] do
    @label label
    @method method
    @bucket bucket

    test "#{@label}: a second user behind the SAME IP is not starved by the first user's flood" do
      {user_a, _} = user_with_team()
      {user_b, _} = user_with_team()
      {:ok, token_a} = Accounts.create_user_session_token(user_a)
      {:ok, token_b} = Accounts.create_user_session_token(user_b)

      exhaust(@method, token_a)

      # Same peer IP (Plug.Test default), different authenticated identity: the
      # budget is user A's, not the address's.
      conn = call(@method, "/v1/barkparks/#{Ecto.UUID.generate()}/app-token", token_b)

      assert conn.status == 404,
             "user B from the same IP got #{conn.status} — the #{@bucket} bucket is keyed " <>
               "on the address, not the authenticated user"

      # The key really is the user id: A's bucket is full, B's has one hit, the
      # legacy IP-shaped key was never touched.
      assert DeviceAuthRateLimiter.check("#{@bucket}:" <> user_a.id) == {:error, :rate_limited}
      assert DeviceAuthRateLimiter.check("#{@bucket}:127.0.0.1") == :ok
    end
  end
end
