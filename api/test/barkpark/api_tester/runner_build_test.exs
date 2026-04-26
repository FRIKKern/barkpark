defmodule Barkpark.ApiTester.RunnerBuildTest do
  use ExUnit.Case, async: true
  alias Barkpark.ApiTester.{Endpoints, Runner}

  test "build_request interpolates path_params and appends query_params" do
    ep = Endpoints.find("staging", "query-list")

    form_state = %{
      "dataset" => "staging",
      "type" => "post",
      "perspective" => "drafts",
      "limit" => "5",
      "offset" => "0",
      "order" => "_updatedAt:desc",
      "filter[title]" => "hello world"
    }

    req = Runner.build_request(ep, form_state, %{token: "tk", base: "http://localhost:4000"})

    assert req.method == "GET"
    assert String.starts_with?(req.url, "http://localhost:4000/v1/data/query/staging/post?")
    assert String.contains?(req.url, "perspective=drafts")
    assert String.contains?(req.url, "limit=5")

    assert String.contains?(req.url, "filter%5Btitle%5D=hello+world") or
             String.contains?(req.url, "filter%5Btitle%5D=hello%20world")

    assert req.body_text in [nil, ""]
  end

  test "build_request drops empty query_params" do
    ep = Endpoints.find("production", "query-list")
    form_state = %{"dataset" => "production", "type" => "post", "filter[title]" => ""}
    req = Runner.build_request(ep, form_state, %{token: "tk", base: "http://x"})
    refute String.contains?(req.url, "filter")
  end

  test "build_request attaches Authorization for :token and :admin endpoints" do
    create = Endpoints.find("production", "mutate-create")

    req =
      Runner.build_request(
        create,
        %{"dataset" => "production", "_body_text" => Jason.encode!(create.body_example)},
        %{token: "dev-tok", base: "http://x"}
      )

    assert {"Authorization", "Bearer dev-tok"} in req.headers
    assert {"Content-Type", "application/json"} in req.headers
    assert req.method == "POST"
    assert req.body_text == Jason.encode!(create.body_example)
  end

  test "build_request does NOT attach Authorization for :public endpoints" do
    list = Endpoints.find("production", "query-list")

    req =
      Runner.build_request(list, %{"dataset" => "production", "type" => "post"}, %{
        token: "dev-tok",
        base: "http://x"
      })

    refute Enum.any?(req.headers, fn {k, _} -> k == "Authorization" end)
  end
end
