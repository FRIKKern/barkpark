defmodule BarkparkCloud.Web.WorkerAllowedIpsTest do
  @moduledoc """
  dr-w24-bl-internal-write-route-is-publicly-reachable: `/v1/internal/*` is
  publicly reachable and the shared WORKER token was its only gate. The optional
  second factor `:worker_allowed_ips` (WORKER_ALLOWED_IPS) narrows WHERE a correct
  token is accepted from:

    * unset / empty → token alone, byte-identical to before;
    * set → a correct token from any other client IP is refused (401);
    * set but nothing parses → nobody is admitted (fails closed, never open);
    * the client IP is the one the router's `trust_forwarded_ip` resolved, so an
      UNTRUSTED peer cannot claim an allowed address through X-Forwarded-For.

  `async: false`: the tests flip application env.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @worker_token "worker-token-test-fixed"
  @path "/v1/internal/warm-servers/count"

  setup do
    prev = Application.get_env(:barkpark_cloud, :worker_allowed_ips)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:barkpark_cloud, :worker_allowed_ips),
        else: Application.put_env(:barkpark_cloud, :worker_allowed_ips, prev)
    end)

    :ok
  end

  defp allow(ips), do: Application.put_env(:barkpark_cloud, :worker_allowed_ips, ips)

  # Plug.Test's default peer is 127.0.0.1 (a trusted front), so X-Forwarded-For
  # sets the resolved client address exactly as Caddy does in production.
  defp call_from(client_ip, opts \\ []) do
    conn =
      conn(:get, @path)
      |> put_req_header("authorization", "Bearer " <> Keyword.get(opts, :token, @worker_token))
      |> put_req_header("x-forwarded-for", client_ip)

    conn = if peer = opts[:peer], do: %{conn | remote_ip: peer}, else: conn
    Router.call(conn, @opts)
  end

  test "unset: the token alone still passes, from any source" do
    allow([])
    assert call_from("198.51.100.20").status == 200
  end

  test "set: the token from an allowed client IP passes" do
    allow(["203.0.113.5"])
    assert call_from("203.0.113.5").status == 200
  end

  test "set: the SAME token from any other client IP is refused" do
    allow(["203.0.113.5"])
    assert call_from("198.51.100.20").status == 401
  end

  test "set: a wrong token from an allowed IP is still refused" do
    allow(["203.0.113.5"])
    assert call_from("203.0.113.5", token: "not-the-worker-token").status == 401
  end

  test "an UNTRUSTED peer cannot claim an allowed address through X-Forwarded-For" do
    allow(["203.0.113.5"])
    assert call_from("203.0.113.5", peer: {198, 51, 100, 77}).status == 401
  end

  test "a list that parses to no IP admits nobody (fails closed, never open)" do
    allow(["not-an-ip", " "])
    assert call_from("198.51.100.20").status == 401
    assert call_from("203.0.113.5").status == 401
  end
end
