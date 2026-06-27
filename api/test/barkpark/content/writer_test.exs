defmodule Barkpark.Content.WriterTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Writer

  # ── deep_merge/2 ──────────────────────────────────────────────────────────

  describe "deep_merge/2" do
    test "merges flat maps, right side wins on conflict" do
      a = %{"x" => 1, "y" => 2}
      b = %{"y" => 99, "z" => 3}
      assert Writer.deep_merge(a, b) == %{"x" => 1, "y" => 99, "z" => 3}
    end

    test "merges nested maps recursively" do
      a = %{"top" => %{"a" => 1, "b" => 2}}
      b = %{"top" => %{"b" => 99, "c" => 3}}
      assert Writer.deep_merge(a, b) == %{"top" => %{"a" => 1, "b" => 99, "c" => 3}}
    end

    test "a list in b replaces a list in a (no list merging)" do
      a = %{"items" => [1, 2, 3]}
      b = %{"items" => [4, 5]}
      assert Writer.deep_merge(a, b) == %{"items" => [4, 5]}
    end

    test "non-map left side is discarded in favour of b" do
      assert Writer.deep_merge("old", "new") == "new"
      assert Writer.deep_merge(nil, %{"k" => 1}) == %{"k" => 1}
    end
  end

  # ── resolve_dynamics/1 ────────────────────────────────────────────────────

  describe "resolve_dynamics/1" do
    test "$today resolves to today's ISO-8601 date string" do
      result = Writer.resolve_dynamics("$today")
      expected = Date.utc_today() |> Date.to_iso8601()
      assert result == expected
    end

    test "$today.year resolves to a 4-digit year string" do
      result = Writer.resolve_dynamics("$today.year")
      expected = Date.utc_today().year |> Integer.to_string()
      assert result == expected
      assert String.length(result) == 4
    end

    test "non-token strings are returned unchanged" do
      assert Writer.resolve_dynamics("hello") == "hello"
      assert Writer.resolve_dynamics("$unknown") == "$unknown"
    end

    test "resolves tokens nested inside a map" do
      input = %{"date" => "$today", "static" => "keep"}
      result = Writer.resolve_dynamics(input)
      expected_date = Date.utc_today() |> Date.to_iso8601()
      assert result == %{"date" => expected_date, "static" => "keep"}
    end

    test "resolves tokens inside a list" do
      result = Writer.resolve_dynamics(["$today", "literal"])
      expected_date = Date.utc_today() |> Date.to_iso8601()
      assert result == [expected_date, "literal"]
    end
  end

  # ── from_envelope/1 ───────────────────────────────────────────────────────

  describe "from_envelope/1" do
    test "passes through legacy shape (already has content map)" do
      attrs = %{"doc_id" => "x-1", "title" => "T", "content" => %{"body" => "hi"}}
      result = Writer.from_envelope(attrs)
      assert result["doc_id"] == "x-1"
      assert result["content"] == %{"body" => "hi"}
    end

    test "coerces flat Sanity-style envelope: non-reserved keys go into content" do
      attrs = %{
        "_id" => "s-1",
        "title" => "Flat",
        "status" => "published",
        "body" => "text",
        "tags" => ["a"]
      }

      result = Writer.from_envelope(attrs)
      assert result["doc_id"] == "s-1"
      assert result["title"] == "Flat"
      assert result["status"] == "published"
      assert result["content"]["body"] == "text"
      assert result["content"]["tags"] == ["a"]
      # reserved keys must NOT leak into content
      refute Map.has_key?(result["content"], "title")
      refute Map.has_key?(result["content"], "_id")
    end

    test "honours _id when content map present but doc_id is absent" do
      attrs = %{"_id" => "fallback-id", "content" => %{"k" => "v"}}
      result = Writer.from_envelope(attrs)
      assert result["doc_id"] == "fallback-id"
    end

    test "defaults status to draft when missing in flat envelope" do
      attrs = %{"_id" => "s-2", "body" => "hello"}
      result = Writer.from_envelope(attrs)
      assert result["status"] == "draft"
    end
  end

  # ── validate_task_kind/2 ──────────────────────────────────────────────────

  describe "validate_task_kind/2" do
    test "non-task types always return :ok regardless of content" do
      assert Writer.validate_task_kind("post", %{}) == :ok
      assert Writer.validate_task_kind("page", %{"anything" => "here"}) == :ok
    end
  end
end
