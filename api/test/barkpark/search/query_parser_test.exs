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

  test "to_map returns API-friendly shape" do
    map = QueryParser.parse("a -b") |> QueryParser.to_map()
    assert map == %{terms: ["a"], phrases: [], excludes: ["b"], prefixes: []}
  end
end
