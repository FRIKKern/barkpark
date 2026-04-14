defmodule Barkpark.ApiTester.EndpointsTest do
  use ExUnit.Case, async: true
  alias Barkpark.ApiTester.Endpoints

  test "all/1 returns endpoints for the given dataset" do
    endpoints = Endpoints.all("staging")
    assert is_list(endpoints)
    assert length(endpoints) >= 3
  end

  test "find/2 returns the query-list endpoint with a dataset-interpolated path" do
    ep = Endpoints.find("staging", "query-list")
    assert ep.kind == :endpoint
    assert ep.method == "GET"
    assert ep.path_template == "/v1/data/query/{dataset}/{type}"
    assert ep.auth == :public
    assert ep.category == "Query"
  end

  test "find/2 returns nil for unknown id" do
    assert Endpoints.find("staging", "bogus") == nil
  end

  test "query-single endpoint has path and doc_id params" do
    ep = Endpoints.find("production", "query-single")
    param_names = Enum.map(ep.path_params, & &1.name)
    assert "dataset" in param_names
    assert "type" in param_names
    assert "doc_id" in param_names
  end

  test "mutate-create is under Mutate category and has token auth" do
    ep = Endpoints.find("production", "mutate-create")
    assert ep.category == "Mutate"
    assert ep.auth == :token
    assert ep.method == "POST"
    assert is_map(ep.body_example)
  end
end
