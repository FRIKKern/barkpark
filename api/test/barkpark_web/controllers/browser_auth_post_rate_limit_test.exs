defmodule BarkparkWeb.BrowserAuthPostRateLimitTest do
  @moduledoc """
  Owner ruling #31 (2026-10-03, task-ebf2b68348ae7e5a): the four browser auth
  form POSTs — `/login/account`, `/login/mfa`, `/login/reset`, `/login/magic` —
  ride the existing per-IP write meter (60 a minute). Before this, the
  `:browser` pipeline mounted no rate limit, so one address could try passwords
  across every account with no per-IP bound. Page reads (`GET /login`, the reset
  and magic-link request pages) stay unmetered.

  Every request here is built with `scoped_conn/0`, so the bucket is this test
  process's own and no other test can drain or fill it.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Accounts

  @budget 60

  # Each body below takes the controller's cheapest refusal (missing fields, no
  # pending second step), so 60 of them cost no password hashing or mail.
  @posts [
    {"/login/account", %{"email" => "nobody@example.test"}},
    {"/login/mfa", %{"code" => "000000"}},
    {"/login/reset", %{}},
    {"/login/magic", %{}}
  ]

  defp post_from_one_ip(path, params), do: post(scoped_conn(), path, params)

  for {path, params} <- @posts do
    @path path
    @params params

    test "POST #{path}: the 61st POST from one IP in a minute is refused with 429" do
      for n <- 1..@budget do
        conn = post_from_one_ip(@path, @params)
        assert conn.status != 429, "POST #{@path} number #{n} was refused inside the budget"
      end

      conn = post_from_one_ip(@path, @params)
      assert conn.status == 429
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
      assert %{"error" => %{"code" => "rate_limited"}} = Jason.decode!(conn.resp_body)
    end
  end

  test "the four POSTs share one per-IP budget, so alternating routes buys no extra tries" do
    paths = Stream.cycle(@posts) |> Enum.take(@budget)

    for {path, params} <- paths do
      refute post_from_one_ip(path, params).status == 429
    end

    for {path, params} <- @posts do
      assert post_from_one_ip(path, params).status == 429, "POST #{path} was not metered"
    end
  end

  test "page reads stay unmetered after the POST budget is spent" do
    for _ <- 1..(@budget + 1), do: post_from_one_ip("/login/account", %{})

    for path <- ["/login", "/login/reset", "/login/magic"] do
      conn = get(scoped_conn(), path)

      assert conn.status == 200,
             "GET #{path} answered #{conn.status} after the POST budget ran out"
    end
  end

  test "a real sign-in inside the budget still lands in Studio" do
    email = "browser-auth-meter-#{System.unique_integer([:positive])}@example.test"
    {:ok, _user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    conn =
      post_from_one_ip("/login/account", %{
        "email" => email,
        "password" => "correct-horse-battery"
      })

    refute_rate_limited!(conn)
    assert conn.status == 302
    assert get_session(conn, "user_session")
  end
end
