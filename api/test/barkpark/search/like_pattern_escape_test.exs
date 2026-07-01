defmodule Barkpark.Search.LikePatternEscapeTest do
  @moduledoc """
  Pure string->string guard for the ILIKE wildcard-escape helpers. Backslash is
  PostgreSQL's default ESCAPE char, so it MUST be escaped first (before `%`/`_`),
  in lockstep with the canonical `Barkpark.Content.Query.escape_like/1`
  (content/query.ex:564-570). No DB — these are pure functions.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Media.Delivery.Retriever
  alias Barkpark.Media.Delivery.Search
  alias Barkpark.Search.DocumentsRetriever

  describe "DocumentsRetriever.like_pattern/1" do
    test "escapes backslash first (doubled) then wildcards" do
      # "a\b" -> backslash doubled, wrapped in contains anchors
      assert DocumentsRetriever.like_pattern("a\\b") == "%a\\\\b%"
      assert DocumentsRetriever.like_pattern("a%b") == "%a\\%b%"
      assert DocumentsRetriever.like_pattern("a_b") == "%a\\_b%"
    end
  end

  describe "Retriever.like_pattern/1 (media delivery)" do
    test "escapes backslash first (doubled) then wildcards" do
      assert Retriever.like_pattern("a\\b") == "%a\\\\b%"
      assert Retriever.like_pattern("a%b") == "%a\\%b%"
      assert Retriever.like_pattern("a_b") == "%a\\_b%"
    end
  end

  describe "Search.escape_like/1 (media library search)" do
    test "escapes backslash first (doubled) then wildcards" do
      # escape_like returns the bare escaped token (no anchors)
      assert Search.escape_like("a\\b") == "a\\\\b"
      assert Search.escape_like("a%b") == "a\\%b"
      assert Search.escape_like("a_b") == "a\\_b"
    end
  end
end
