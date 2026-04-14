defmodule Barkpark.ApiTester.TestCasesTest do
  use ExUnit.Case, async: true
  alias Barkpark.ApiTester.TestCases

  test "all/1 builds URLs for the given dataset" do
    cases = TestCases.all("staging")
    envelope = Enum.find(cases, &(&1.id == "query-flat-envelope"))
    assert envelope.path == "/v1/data/query/staging/post?limit=1"

    schemas = Enum.find(cases, &(&1.id == "schemas-list"))
    assert schemas.path == "/v1/schemas/staging"
  end

  test "find/2 returns a case by id for a given dataset" do
    tc = TestCases.find("staging", "query-flat-envelope")
    assert tc.path == "/v1/data/query/staging/post?limit=1"
  end
end
