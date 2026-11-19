defmodule BarkparkCloud.Web.WarmPoolTargetTest do
  @moduledoc """
  task-48a556bfbe221dcf: `GET /v1/operator/warm-pool` reports the warm-pool
  target the Go worker last sent on its job poll, beside the ready count.

  On 2026-11-19 the claim store held two ready warm servers while the worker
  ran with WARM_POOL_SIZE=0, and this route answered `{ready: 2}` alone. These
  tests pin the worker half: a poll carrying `x-barkpark-warm-pool-target`
  becomes `worker_target`, a control-plane slot that has not heard from the
  worker says "unknown" (never 0, never "on"), and a bad header cannot
  overwrite a good value.

  `async: false`: the operator allowlist is process-global config and the
  target table is one per node.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.WarmPoolTarget
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @worker_token "worker-token-test-fixed"

  setup do
    prior = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    WarmPoolTarget.reset()

    on_exit(fn ->
      Application.put_env(:barkpark_cloud, :platform_admin_emails, prior)
      WarmPoolTarget.reset()
    end)

    {:ok, user} =
      Accounts.register_user(%{
        email: "op-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
    {:ok, session} = Accounts.create_user_session_token(user)
    %{session: session}
  end

  defp worker_poll(target_header) do
    conn =
      conn(:post, "/v1/internal/provision-jobs/claim")
      |> put_req_header("authorization", "Bearer #{@worker_token}")

    conn =
      if target_header,
        do: put_req_header(conn, WarmPoolTarget.header(), target_header),
        else: conn

    Router.call(conn, @opts)
  end

  defp warm_pool(session) do
    conn =
      conn(:get, "/v1/operator/warm-pool")
      |> put_req_header("authorization", "Bearer #{session}")
      |> Router.call(@opts)

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  test "before any worker poll the target is unknown, never 0 or on", %{session: s} do
    body = warm_pool(s)
    assert body["ready"] == Registry.count_ready_warm_servers()
    assert body["worker_target"] == nil
    assert body["worker_pool"] == "unknown"
    assert body["worker_seen_at"] == nil
    assert body["worker_seen_ago_s"] == nil
  end

  test "the endpoint returns the target the worker's poll reported", %{session: s} do
    assert worker_poll("0").status == 204

    body = warm_pool(s)
    assert body["worker_target"] == 0
    assert body["worker_pool"] == "off"
    assert is_binary(body["worker_seen_at"])
    assert body["worker_seen_ago_s"] in 0..5

    assert worker_poll("2").status == 204
    body = warm_pool(s)
    assert body["worker_target"] == 2
    assert body["worker_pool"] == "on"
  end

  test "a poll without the header, or with a bad one, keeps the last good value", %{session: s} do
    worker_poll("3")
    worker_poll(nil)
    worker_poll("-1")
    worker_poll("lots")
    assert warm_pool(s)["worker_target"] == 3
  end

  test "an unauthenticated poll records nothing", %{session: s} do
    conn =
      conn(:post, "/v1/internal/provision-jobs/claim")
      |> put_req_header(WarmPoolTarget.header(), "7")
      |> Router.call(@opts)

    assert conn.status == 401
    assert warm_pool(s)["worker_pool"] == "unknown"
  end
end
