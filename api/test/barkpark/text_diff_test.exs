defmodule Barkpark.TextDiffTest do
  @moduledoc """
  W7c step 3 (w7-11 / paper-158) — rail wrapper around
  `Barkpark.Papers.TextDiff`. The underlying LCS port is exhaustively
  tested in `Barkpark.Papers.TextDiffTest`; these tests assert the
  rail-shaped translation (op `=` → `" "`, html shape, etc.) and a few
  smoke cases.
  """
  use ExUnit.Case, async: true

  alias Barkpark.TextDiff

  describe "hunks/2" do
    test "all-equal text yields all-context hunks with op=\" \"" do
      result = TextDiff.hunks("a\nb\nc", "a\nb\nc")

      assert result == [
               %{op: " ", text: "a"},
               %{op: " ", text: "b"},
               %{op: " ", text: "c"}
             ]
    end

    test "pure addition emits only `+` rows" do
      result = TextDiff.hunks("", "x\ny")

      assert result == [
               %{op: "+", text: "x"},
               %{op: "+", text: "y"}
             ]
    end

    test "a changed middle line shows `-` then `+` around context" do
      result = TextDiff.hunks("a\nb\nc", "a\nbb\nc")
      ops = Enum.map(result, & &1.op)
      assert "-" in ops
      assert "+" in ops
      assert " " in ops
    end

    test "nil inputs are safe (empty list)" do
      assert TextDiff.hunks(nil, nil) == []
      assert TextDiff.hunks(nil, "") == []
    end
  end

  describe "format_diff_html/1" do
    test "emits a <pre class=\"diff\"> block with per-line div spans" do
      hunks = [
        %{op: " ", text: "keep"},
        %{op: "+", text: "new"},
        %{op: "-", text: "<script>alert(1)</script>"}
      ]

      html = TextDiff.format_diff_html(hunks)
      assert String.starts_with?(html, "<pre class=\"diff\">")
      assert String.ends_with?(html, "</pre>")
      assert String.contains?(html, "diff-context")
      assert String.contains?(html, "diff-added")
      assert String.contains?(html, "diff-removed")

      # HTML-escaping defense: untrusted <script> is rendered escaped, never raw.
      assert String.contains?(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
      refute String.contains?(html, "<script>alert(1)</script>")
    end
  end
end
