defmodule Barkpark.Papers.TextDiffTest do
  @moduledoc """
  P6.U3 (barkpark-q3sf) — pure line-level LCS differ, an Elixir port of
  the vendored `lib/text-diff.js`. No DB: this exercises `diff_lines/2` golden
  cases (identical / pure-add / pure-remove / mixed) and the escaping +
  per-op classes of `format_diff_html/1`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Papers.TextDiff

  describe "diff_lines/2" do
    test "identical text → all context (\"=\")" do
      text = "alpha\nbeta\ngamma"
      chunks = TextDiff.diff_lines(text, text)

      assert chunks == [
               %{op: "=", text: "alpha"},
               %{op: "=", text: "beta"},
               %{op: "=", text: "gamma"}
             ]
    end

    test "pure addition → all added (\"+\")" do
      chunks = TextDiff.diff_lines("", "one\ntwo")

      assert chunks == [
               %{op: "+", text: "one"},
               %{op: "+", text: "two"}
             ]
    end

    test "pure removal → all removed (\"-\")" do
      chunks = TextDiff.diff_lines("one\ntwo", "")

      assert chunks == [
               %{op: "-", text: "one"},
               %{op: "-", text: "two"}
             ]
    end

    test "a mixed edit keeps shared context, marks the changed line" do
      old = "keep1\nold-middle\nkeep2"
      new = "keep1\nnew-middle\nkeep2"
      chunks = TextDiff.diff_lines(old, new)

      # The two unchanged lines survive as context; the middle line is a
      # remove-then-add pair (LCS of {keep1, keep2} on both sides).
      assert %{op: "=", text: "keep1"} in chunks
      assert %{op: "-", text: "old-middle"} in chunks
      assert %{op: "+", text: "new-middle"} in chunks
      assert %{op: "=", text: "keep2"} in chunks

      # Ordering: keep1 first, keep2 last, the change in the middle.
      ops = Enum.map(chunks, & &1.op)
      assert List.first(ops) == "="
      assert List.last(ops) == "="
    end

    test "an inserted line in the middle is a single added chunk" do
      chunks = TextDiff.diff_lines("a\nc", "a\nb\nc")

      assert chunks == [
               %{op: "=", text: "a"},
               %{op: "+", text: "b"},
               %{op: "=", text: "c"}
             ]
    end

    test "splits on newline and drops a single trailing empty line" do
      # "a\nb\n" → two lines (the trailing empty is dropped), matching the JS
      # splitLines() semantics — so a trailing newline does not create a 3rd,
      # empty line that would diff as changed.
      assert TextDiff.diff_lines("a\nb\n", "a\nb") == [
               %{op: "=", text: "a"},
               %{op: "=", text: "b"}
             ]
    end

    test "nil / empty inputs are safe" do
      assert TextDiff.diff_lines(nil, nil) == []
      assert TextDiff.diff_lines("", "") == []
      assert TextDiff.diff_lines(nil, "x") == [%{op: "+", text: "x"}]
      assert TextDiff.diff_lines("x", nil) == [%{op: "-", text: "x"}]
    end
  end

  describe "format_diff_html/1" do
    test "wraps in <pre class=\"bp-diff\"> with one span per line, prefixed" do
      html =
        [
          %{op: "=", text: "ctx"},
          %{op: "+", text: "add"},
          %{op: "-", text: "del"}
        ]
        |> TextDiff.format_diff_html()

      assert String.starts_with?(html, ~s(<pre class="bp-diff">))
      assert String.ends_with?(html, "</pre>")

      # All three op classes are emitted.
      assert html =~ ~s(<span class="bp-diff-line bp-diff-ctx">)
      assert html =~ ~s(<span class="bp-diff-line bp-diff-add">)
      assert html =~ ~s(<span class="bp-diff-line bp-diff-del">)

      # Prefix markers ride the escaped line text.
      assert html =~ ">  ctx</span>"
      assert html =~ ">+ add</span>"
      assert html =~ ">- del</span>"
    end

    test "HTML-escapes < and & in the payload (no raw markup, no script)" do
      html =
        [%{op: "+", text: ~s|<script>alert(1)</script> & "x"|}]
        |> TextDiff.format_diff_html()

      # The dangerous chars are escaped; no live <script> tag survives.
      assert html =~ "&lt;script&gt;"
      assert html =~ "&amp;"
      assert html =~ "&quot;"
      refute html =~ "<script>"
    end

    test "an empty chunk list yields an empty <pre>" do
      assert TextDiff.format_diff_html([]) == ~s(<pre class="bp-diff"></pre>)
    end
  end
end
