defmodule Barkpark.Search.QueryParserTest do
  use ExUnit.Case, async: true

  alias Barkpark.Search.QueryParser

  test "tokenizes simple terms" do
    parsed = QueryParser.parse("hello world")
    assert parsed.terms == ["hello", "world"]
    assert parsed.phrases == []
    assert parsed.excludes == []
    assert parsed.prefixes == []
  end

  test "extracts quoted phrases" do
    parsed = QueryParser.parse(~s("exact phrase" extra))
    assert parsed.phrases == ["exact phrase"]
    assert parsed.terms == ["extra"]
  end

  test "parses exclude tokens" do
    parsed = QueryParser.parse("phoenix -wright")
    assert parsed.terms == ["phoenix"]
    assert parsed.excludes == ["wright"]
  end

  test "parses trailing star prefix tokens" do
    parsed = QueryParser.parse("phoe* guide")
    assert parsed.prefixes == ["phoe"]
    assert parsed.terms == ["guide"]
  end

  test "drops a trailing bare hyphen instead of excluding everything" do
    parsed = QueryParser.parse("foo -")
    assert parsed.terms == ["foo"]
    assert parsed.excludes == []
  end

  test "drops a leading bare hyphen but keeps the following term" do
    parsed = QueryParser.parse("- foo")
    assert parsed.terms == ["foo"]
    assert parsed.excludes == []
  end

  test "drops a bare star instead of leaking an empty prefix" do
    for q <- ["*", "**"] do
      parsed = QueryParser.parse(q)
      assert parsed.prefixes == []
      assert parsed.terms == []
    end
  end

  test "to_map returns API-friendly shape" do
    map = QueryParser.parse("a -b") |> QueryParser.to_map()
    assert map == %{terms: ["a"], phrases: [], excludes: ["b"], prefixes: []}
  end
end
