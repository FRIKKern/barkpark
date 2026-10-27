defmodule BarkparkWeb.GroqLargeDatasetTimeoutTest do
  @moduledoc """
  The query timeout over the 10,500 products of `BarkparkWeb.GroqLargeDatasetTest`.
  These two live apart because a timed-out query is killed while it holds its
  connection, which ends the sandbox transaction it ran in; that module shares
  one transaction across its tests, so each test here seeds its own.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Test.GroqSyntheticProducts

  @dataset "groq_big"
  @version "v2025-02-19"
  @products 10_500

  setup do
    GroqSyntheticProducts.seed_site!(@dataset, @products)
  end

  defp query(token, query) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/w/groq-big/p/site/#{@version}/data/query/#{@dataset}",
      Jason.encode!(%{"query" => query, "params" => %{}})
    )
  end

  defp with_groq_config(config) do
    previous = Application.get_env(:barkpark, Barkpark.Groq, [])
    Application.put_env(:barkpark, Barkpark.Groq, config)
    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Groq, previous) end)
  end

  test "the query timeout still applies to a count SQL cannot match exactly", %{token: token} do
    with_groq_config(timeout_ms: 50)

    body =
      token
      |> query(~s'count(*[_type == "product" && lower(isbn) > "0"])')
      |> json_response(422)

    assert body["error"]["description"] =~ "ran longer than 50 ms"
  end

  test "the query timeout still applies to a slice over more documents than one read may load",
       %{token: token} do
    with_groq_config(timeout_ms: 50)

    body =
      token
      |> query(~s'*[_type == "product" && lower(isbn) > "0"] | order(lower(isbn) desc)[0]')
      |> json_response(422)

    assert body["error"]["description"] =~ "ran longer than 50 ms"
  end
end
