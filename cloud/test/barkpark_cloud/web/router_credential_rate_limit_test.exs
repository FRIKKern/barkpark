defmodule BarkparkCloud.Web.RouterCredentialRateLimitTest do
  @moduledoc """
  task-9f03e6725aacd1c1 — POST /v1/auth/login and POST /v1/auth/request-reset
  had no rate limit: unbounded online password guessing (each attempt a bcrypt
  verification) and unlimited reset mail to any registered address. These arms
  run against the PRODUCTION budgets (the suite-wide override in config/test.exs
  is removed for the duration).
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.DeviceAuth.RateLimiter
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "right horse battery"

  setup do
    prev = Application.fetch_env(:barkpark_cloud, :rate_limit_overrides)
    Application.delete_env(:barkpark_cloud, :rate_limit_overrides)
    RateLimiter.reset()

    on_exit(fn ->
      RateLimiter.reset()

      case prev do
        {:ok, v} -> Application.put_env(:barkpark_cloud, :rate_limit_overrides, v)
        :error -> Application.delete_env(:barkpark_cloud, :rate_limit_overrides)
      end
    end)

    {:ok, user} = Accounts.register_user(%{email: "victim@example.com", password: @password})
    %{user: user}
  end

  defp post_json(path, body, ip \\ {203, 0, 113, 9}) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> Map.put(:remote_ip, ip)
    |> Router.call(@opts)
  end

  test "wrong-password guesses against ONE address are cut off at the per-address budget" do
    budget = RateLimiter.limit("login_email")

    statuses =
      for i <- 1..(budget + 2) do
        # A different source IP each time: only the per-ADDRESS bucket can stop this.
        post_json(
          "/v1/auth/login",
          %{email: "victim@example.com", password: "guess-#{i}"},
          {198, 51, 100, rem(i, 250) + 1}
        ).status
      end

    assert Enum.take(statuses, budget) |> Enum.all?(&(&1 == 401))
    assert Enum.drop(statuses, budget) |> Enum.all?(&(&1 == 429))
  end

  test "one IP spraying many addresses is cut off at the per-IP budget" do
    budget = RateLimiter.limit("login")

    statuses =
      for i <- 1..(budget + 2) do
        post_json("/v1/auth/login", %{email: "nobody-#{i}@example.com", password: "x"}).status
      end

    assert Enum.take(statuses, budget) |> Enum.all?(&(&1 == 401))
    assert Enum.drop(statuses, budget) |> Enum.all?(&(&1 == 429))
  end

  test "a correct password inside the budget still logs in (control)" do
    conn = post_json("/v1/auth/login", %{email: "victim@example.com", password: @password})
    assert conn.status == 200
    assert is_binary(Jason.decode!(conn.resp_body)["token"])
  end

  test "request-reset mails at most the per-address budget, and always answers 200" do
    budget = RateLimiter.limit("reset_email")

    statuses =
      for _ <- 1..(budget + 3),
          do: post_json("/v1/auth/request-reset", %{email: "victim@example.com"}).status

    assert Enum.all?(statuses, &(&1 == 200))

    minted =
      BarkparkCloud.Repo.aggregate(
        Ecto.Query.from(t in BarkparkCloud.Accounts.UserToken, where: t.context == "reset"),
        :count
      )

    assert minted == budget
  end
end
