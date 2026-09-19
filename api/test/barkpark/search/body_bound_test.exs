defmodule Barkpark.Search.BodyBoundTest do
  @moduledoc """
  Unit cover for `Barkpark.Search.BodyBound` — the `?bodyChars=` prose bound.

  The property under test is not "the response got smaller"; it is that what
  survives the bound is a PREFIX of whole blocks carrying at least the asked-for
  characters of prose, and that a hit whose tree was cut SAYS so. A bound that
  silently returns a short document is indistinguishable from a document that
  was short, and that ambiguity is the whole reason `_bodyTruncated` exists.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Search.BodyBound

  defp para(text), do: %{"_type" => "paragraph", "children" => [%{"value" => text}]}

  defp blocks(n, chars),
    do: for(i <- 1..n, do: para(String.duplicate("#{rem(i, 10)}", chars)))

  describe "parse/1" do
    test "absent / blank is unbounded, not zero" do
      # The distinction matters: 0 means "no prose at all", nil means "every
      # caller that never heard of this parameter is unchanged".
      assert BodyBound.parse(nil) == {:ok, nil}
      assert BodyBound.parse("") == {:ok, nil}
      assert BodyBound.parse("   ") == {:ok, nil}
    end

    test "a non-negative integer parses; the cap is clamped" do
      assert BodyBound.parse("0") == {:ok, 0}
      assert BodyBound.parse("1000") == {:ok, 1000}
      assert BodyBound.parse(" 1000 ") == {:ok, 1000}
      assert BodyBound.parse("99999999") == {:ok, 1_000_000}
    end

    test "garbage is :error, NEVER a silent nil" do
      # A typo that read as nil would answer the unbounded payload the caller
      # explicitly asked not to receive — the one failure mode this parameter
      # must not have.
      for bad <- ["abc", "-5", "1.5", "1000x", "1e3", 1000, %{}] do
        assert BodyBound.parse(bad) == :error, "expected :error for #{inspect(bad)}"
      end
    end
  end

  describe "apply_bound/2" do
    test "nil leaves the docs untouched (identity, not a rebuild)" do
      docs = [%{"blocks" => blocks(50, 100), "title" => "t"}]
      assert BodyBound.apply_bound(docs, nil) == docs
    end

    test "blocks are cut to the smallest whole-block prefix reaching the cap" do
      doc = %{"blocks" => blocks(50, 100)}
      [bounded] = BodyBound.apply_bound([doc], 250)

      kept = bounded["blocks"]
      # 100 prose chars per block ⇒ 3 blocks is the smallest prefix reaching 250.
      assert length(kept) == 3
      # It is a PREFIX, in document order — not a sample, not a re-order.
      assert kept == Enum.take(doc["blocks"], 3)
      assert bounded["_bodyTruncated"] == true
    end

    test "a document that already fits is returned whole and unflagged" do
      doc = %{"blocks" => blocks(2, 100)}
      [bounded] = BodyBound.apply_bound([doc], 1000)

      assert bounded["blocks"] == doc["blocks"]
      refute Map.has_key?(bounded, "_bodyTruncated")
    end

    test "bodyChars=0 keeps no blocks at all" do
      [bounded] = BodyBound.apply_bound([%{"blocks" => blocks(5, 100)}], 0)
      assert bounded["blocks"] == []
      assert bounded["_bodyTruncated"] == true
    end

    test "structural keys do not spend the character budget" do
      # `href`/`marks`/`_type` are not prose: a block whose only long values are
      # structural must not exhaust the budget a consumer wanted for TEXT.
      long_href = String.duplicate("x", 5000)

      doc = %{
        "blocks" => [
          %{"_type" => "link", "href" => long_href, "marks" => [long_href], "children" => []},
          para("real prose here")
        ]
      }

      [bounded] = BodyBound.apply_bound([doc], 10)
      # The structural block spent 0 of the budget, so the prose block still
      # had to be kept to reach it.
      assert length(bounded["blocks"]) == 2
    end

    test "a map body carrying its own blocks is bounded in place" do
      doc = %{"body" => %{"blocks" => blocks(50, 100), "style" => "normal"}}
      [bounded] = BodyBound.apply_bound([doc], 250)

      assert length(bounded["body"]["blocks"]) == 3
      # Sibling keys of `blocks` survive — the bound cuts prose, not the object.
      assert bounded["body"]["style"] == "normal"
      assert bounded["_bodyTruncated"] == true
    end

    test "a string body is cut to the cap" do
      doc = %{"body" => String.duplicate("a", 5000)}
      [bounded] = BodyBound.apply_bound([doc], 100)

      assert String.length(bounded["body"]) == 100
      assert bounded["_bodyTruncated"] == true
    end

    test "a list body is bounded like blocks" do
      doc = %{"body" => blocks(50, 100)}
      [bounded] = BodyBound.apply_bound([doc], 250)
      assert length(bounded["body"]) == 3
    end

    test "a doc with neither blocks nor body is untouched and unflagged" do
      doc = %{"title" => "t", "excerpt" => "e"}
      assert BodyBound.apply_bound([doc], 10) == [doc]
    end

    test "multibyte prose is counted in CHARACTERS, not bytes" do
      # 3 bytes per char: a byte-counting bound would keep a third of what was
      # asked for and the label would be a lie.
      doc = %{"blocks" => [para(String.duplicate("あ", 100)), para("tail")]}
      [bounded] = BodyBound.apply_bound([doc], 100)

      assert length(bounded["blocks"]) == 1
      assert bounded["_bodyTruncated"] == true
    end
  end
end
