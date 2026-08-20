defmodule Barkpark.Search.HighlighterMultibyteTest do
  @moduledoc """
  Adversarial multibyte regression coverage for the app-level highlighter.

  `highlighter_test.exs` had ZERO CJK/emoji/multibyte cases; this file banks the
  verify-round proof that `highlight_documents` (⇒ private `highlight_text`),
  `snippet_documents` (⇒ private `snippet_text`) and `clamp_brief_highlights`
  stay UTF-8-safe and mark-balanced under codepoint-hostile input: 4000+ CJK
  codepoints, emoji, ZWJ grapheme clusters, multibyte match strings,
  adjacent/overlapping matches and an entity-adjacent boundary.

  ## Why the `String.valid?` assertions are LOAD-BEARING

  They are not cosmetic. They pin a specific implementation invariant: the
  clamp tokenizer regex `~r/<mark>|<\\/mark>|&amp;|&lt;|&gt;|&quot;|&#39;|./us`
  in `Highlighter.clamp_marked/1` carries the unicode (**u**) flag. With `u`,
  the trailing `.` matches one whole *codepoint*, so every token is complete
  UTF-8. DROP the `u` (e.g. `~r/...|./s`) and `.` matches one *byte* — a
  4-byte emoji or 3-byte CJK codepoint is bisected into invalid UTF-8, and
  `String.valid?(output)` goes false. The same reliance holds for the
  `snippet_text`/`highlight_text` alternation regexes compiled with the `u`
  flag (`"iu"` / return-`:index` codepoint offsets). So a regression that
  strips the unicode flag is caught HERE and only here — these assertions are
  the tripwire, not decoration.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.CallerContext
  alias Barkpark.Search.Highlighter

  # Highlighter only reads named struct fields (same stand-in the sibling suite
  # uses). An admin caller keeps every field so `content.*` visibility filtering
  # never removes the field under test.
  defmodule FakeDoc do
    defstruct [:doc_id, :title, :content, :type]
  end

  @admin %CallerContext{principal_type: :api_token, is_admin: true}

  @replacement_char "�"

  # A CJK block long enough to blow well past the 160-char snippet window and
  # the 60-char lead — proves the bounded paths never re-inflate to full field.
  # 4 codepoints * 1200 = 4800 codepoints of lead before any match.
  @cjk_lead String.duplicate("中文测试", 1200)
  @cjk_tail String.duplicate("日本語表示", 400)

  describe "highlight_documents / snippet_documents / clamp_brief_highlights over multibyte fields" do
    # {label, field_text, needle}. The needle is placed BEYOND the 60-grapheme
    # snippet lead so the bounded paths must clamp (left ellipsis) — the
    # re-inflation guard is exercised, not bypassed.
    for {label, field, needle} <- [
          {"CJK padding beyond the snippet lead", @cjk_lead <> "検索キーワード" <> @cjk_tail, "検索キーワード"},
          {"emoji padding around an ascii match",
           String.duplicate("🎉🚀✨🔥", 200) <> "needle" <> String.duplicate("🌟💫", 200), "needle"},
          {"ZWJ family grapheme cluster padding",
           String.duplicate("👨‍👩‍👧‍👦 ", 120) <> "match" <> String.duplicate(" 👩‍❤️‍👨", 120), "match"},
          {"a multibyte match string wrapping a whole CJK word", @cjk_lead <> "全文検索" <> @cjk_tail,
           "全文検索"},
          {"adjacent repeated matches (abcabc)",
           String.duplicate("世界", 100) <> "abcabc" <> String.duplicate("世界", 100), "abc"},
          {"an entity-adjacent boundary with CJK",
           String.duplicate("あ", 100) <> "A&B <x> 検索 " <> String.duplicate("あ", 100), "検索"}
        ] do
      test "safe under: #{label}" do
        field = unquote(field)
        needle = unquote(needle)
        field_len = String.length(field)

        doc = %FakeDoc{doc_id: "d1", title: field, content: %{}, type: "post"}
        parsed = %{terms: [needle], phrases: [], prefixes: []}

        # highlight_text (via highlight_documents): marks the ENTIRE field.
        highlights =
          Highlighter.highlight_documents(
            [doc],
            parsed,
            %{"highlight_fields" => ["title"]},
            @admin
          )

        marked = highlights["d1"]["title"]
        assert is_binary(marked)
        assert_safe(marked)

        # clamp_brief_highlights: bounds the marked field to a window. Must stay
        # valid + mark-balanced AND must NOT re-inflate to the full field length.
        clamped = Highlighter.clamp_brief_highlights(highlights["d1"])["title"]
        assert_safe(clamped)

        assert String.length(clamped) < field_len,
               "clamp re-inflated to full field length (#{String.length(clamped)} >= #{field_len})"

        # snippet_text (via snippet_documents): raw bounded window, no markup.
        snippet =
          Highlighter.snippet_documents([doc], parsed, %{"snippet_fields" => ["title"]}, @admin)[
            "d1"
          ]

        assert is_binary(snippet)
        assert_safe(snippet)

        assert String.length(snippet) < field_len,
               "snippet re-inflated to full field length (#{String.length(snippet)} >= #{field_len})"

        # The needle sits past the lead, so the left side was cut.
        assert String.starts_with?(snippet, "…")
      end
    end

    test "overlapping longest-first needle pair stays mark-balanced" do
      # "abcd" with needles {"abc","bcd"} — longest-first alternation resolves to
      # ONE non-overlapping match; the split must not emit a nested/unbalanced mark.
      field = String.duplicate("世界", 100) <> "abcdabcd" <> String.duplicate("世界", 100)
      doc = %FakeDoc{doc_id: "d1", title: field, content: %{}, type: "post"}
      parsed = %{terms: ["abc", "bcd"], phrases: [], prefixes: []}

      marked =
        Highlighter.highlight_documents([doc], parsed, %{"highlight_fields" => ["title"]}, @admin)[
          "d1"
        ]["title"]

      assert_safe(marked)

      clamped = Highlighter.clamp_brief_highlights(%{"title" => marked})["title"]
      assert_safe(clamped)
    end
  end

  # Every safety invariant in one place: valid UTF-8, no replacement char, and a
  # <mark> depth that never goes negative and ends at zero.
  defp assert_safe(output) do
    assert String.valid?(output), "output is not valid UTF-8"

    refute String.contains?(output, @replacement_char),
           "output contains a U+FFFD replacement char"

    {min_depth, final_depth} = mark_depth(output)
    assert min_depth >= 0, "<mark> depth went negative (#{min_depth}) — a stray </mark>"
    assert final_depth == 0, "<mark> depth did not return to 0 (ended at #{final_depth})"
  end

  # Walk the <mark>/</mark> tags left to right, tracking running depth. Returns
  # {minimum depth seen, final depth}.
  defp mark_depth(str) do
    ~r/<mark>|<\/mark>/
    |> Regex.scan(str)
    |> List.flatten()
    |> Enum.reduce({0, 0}, fn
      "<mark>", {depth, min_d} ->
        d2 = depth + 1
        {d2, min(min_d, d2)}

      "</mark>", {depth, min_d} ->
        d2 = depth - 1
        {d2, min(min_d, d2)}
    end)
    |> then(fn {final, min_d} -> {min_d, final} end)
  end
end
