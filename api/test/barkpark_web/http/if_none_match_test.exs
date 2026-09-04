defmodule BarkparkWeb.Http.IfNoneMatchTest do
  @moduledoc """
  Table-driven RFC 9110 §13.1.2 pins for the one shared If-None-Match matcher.

  MUTATION PROOF: make `strip_weak/1` the identity (delete the
  `"W/" <> opaque_tag` clause) and every row tagged `:weak` below reds, plus
  the openapi and capabilities site suites — both emit `W/"…"` validators.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Http.IfNoneMatch

  @etag ~s("abc123")
  @weak_etag ~s(W/"abc123")

  defp conn_with(header_lines) do
    Enum.reduce(header_lines, Plug.Test.conn(:get, "/"), fn line, c ->
      %{c | req_headers: c.req_headers ++ [{"if-none-match", line}]}
    end)
  end

  # {name, header lines, etag served, expected}
  @cases [
    {"no header at all", [], @etag, false},
    {"single strong, byte-identical", [~s("abc123")], @etag, true},
    {"single strong, different tag", [~s("zzz999")], @etag, false},
    {"weak on BOTH sides", [~s(W/"abc123")], @weak_etag, true},
    {"weak client, strong served", [~s(W/"abc123")], @etag, true},
    {"strong client, weak served", [~s("abc123")], @weak_etag, true},
    {"weak on both sides, different opaque tag", [~s(W/"zzz999")], @weak_etag, false},
    {"comma list, match in the middle", [~s("p", "abc123", "q")], @etag, true},
    {"comma list, no member matches", [~s("p", "q")], @etag, false},
    {"comma list with a weak member", [~s("p", W/"abc123")], @etag, true},
    {"two header LINES, match on the second", [~s("p"), ~s("abc123")], @etag, true},
    {"two header lines, neither matches", [~s("p"), ~s("q")], @etag, false},
    {"the wildcard", ["*"], @etag, true},
    {"wildcard as a list member", [~s("p", *)], @etag, true},
    {"empty entries are dropped, not matched", [~s(, , "abc123")], @etag, true},
    {"a header of nothing but separators never matches", [", ,"], @etag, false},
    {"an empty header line never matches", [""], @etag, false},
    {"UNQUOTED bare validator does NOT match (the quotes are part of the tag)", ["abc123"], @etag,
     false},
    {"surrounding whitespace is trimmed", [~s(   "abc123"   )], @etag, true},
    {"a quoted tag does not match a DIFFERENT quoting", [~s('abc123')], @etag, false}
  ]

  for {name, lines, etag, expected} <- @cases do
    test "#{name}" do
      assert IfNoneMatch.match?(conn_with(unquote(lines)), unquote(etag)) == unquote(expected),
             "If-None-Match #{inspect(unquote(lines))} vs #{inspect(unquote(etag))}"
    end
  end

  describe "candidates/1 — the parse the matcher runs on" do
    test "folds every line, splits on commas, trims, and drops empties" do
      assert IfNoneMatch.candidates([~s("a" , "b"), ~s(, "c"), "", "  "]) ==
               [~s("a"), ~s("b"), ~s("c")]
    end

    test "no header lines parse to no candidates" do
      assert IfNoneMatch.candidates([]) == []
    end
  end
end
