defmodule BarkparkCloud.Web.WrapVocabularyHeaderTest do
  @moduledoc """
  THE WRAP-VOCABULARY HEADER IN `cloud/priv/static/app.css` SAYS ITS COUNTS ARE
  DERIVED. THIS IS THE THING THAT DERIVES THEM.

  That block ends with `EVERY COUNT ABOVE IS DERIVED, WITH ITS COUNTING RULE`
  and then hand-types eight integers. Nothing re-ran the rule. Three of the four
  headline figures had drifted by the time anyone checked, and the drifted
  `min-width` declaration total coincidentally re-landed as the *escape* count,
  so the paragraph was presenting two irreconcilable numbers as a pair — the
  exact failure it exists to forbid. A paragraph cannot be the mechanism for its
  own accuracy.

  WHAT IS PINNED, AND WHY A PIN IS THE HONEST ANSWER HERE. The counts cannot be
  generated into a comment without a build step nobody would run, so instead
  every integer in the prose is PARSED BACK OUT and compared to a fresh
  derivation. Neither side of the comparison is hardcoded in this file: the
  derivation reads the stylesheet, and the expectation reads the paragraph. A
  wrap added tomorrow reds here without anyone editing this test, and so does a
  number edited here without the wrap.

  THE COUNTING RULE, IMPLEMENTED TWICE ON PURPOSE. The block's stated rule is
  "comments STRIPPED, then declarations counted". Two independent readings of
  that sentence are implemented below and required to AGREE before either is
  compared to the prose:

    · RULE A — occurrences of `prop:` in comment-stripped source, minus the
      `@media (min-width: …)` preludes, which are not declarations. This is the
      block's own subtraction, spelled out in its own words.
    · RULE B — matches anchored at a declaration POSITION (`{`, `;`, or line
      start). A media prelude never matches, because `(` precedes the property,
      so the subtraction is structural rather than arithmetic.

  If the two disagree, the file has grown a shape neither reading covers and
  this test reds on the disagreement itself rather than quietly picking one.

  WHY THE RAW LINE GREPS ARE NOT PINNED. They count the paragraph that quotes
  them, so they move whenever any comment in the file is edited. The block no
  longer states them; a `refute` below keeps them from creeping back in as a
  bare tuple of integers.

  IT CANNOT GO VACUOUS. Every subject is located or the test FAILS by name:
  a missing sentinel, an unparseable sentence, a stated figure it cannot find.
  There is no `skip` path and no default value. `mutation_reds_the_check/0`
  drives the same comparator over a falsified copy of the stylesheet and
  requires it to report a mismatch, so a green here is a green with a subject.

  Pure file reading — no DB, no router, no browser.
  """
  use ExUnit.Case, async: true

  @css_path Path.expand("../../priv/static/app.css", __DIR__)
  @sentinel "EVERY COUNT ABOVE IS DERIVED"

  @words %{
    "one" => 1,
    "two" => 2,
    "three" => 3,
    "four" => 4,
    "five" => 5,
    "six" => 6,
    "seven" => 7,
    "eight" => 8,
    "nine" => 9,
    "ten" => 10,
    "eleven" => 11,
    "twelve" => 12
  }

  # ── derivation ────────────────────────────────────────────────────────────

  @doc false
  def strip_comments(css), do: Regex.replace(~r|/\*.*?\*/|s, css, " ")

  defp n(s, re), do: Regex.scan(re, s) |> length()

  @doc false
  def derive(css) do
    st = strip_comments(css)

    a_word_break = n(st, ~r/word-break\s*:/)
    a_overflow_wrap = n(st, ~r/overflow-wrap\s*:/)
    mw_occurrences = n(st, ~r/min-width/)
    mw_preludes = n(st, ~r/@media[^{]*min-width/)
    a_mw_decls = mw_occurrences - mw_preludes

    b_word_break = n(st, ~r/(?:^|[;{])\s*word-break\s*:/m)
    b_overflow_wrap = n(st, ~r/(?:^|[;{])\s*overflow-wrap\s*:/m)
    b_mw_decls = n(st, ~r/(?:^|[;{])\s*min-width\s*:/m)

    %{
      word_break: a_word_break,
      word_break_rule_b: b_word_break,
      word_break_break_word: n(st, ~r/word-break\s*:\s*break-word/),
      word_break_break_all: n(st, ~r/word-break\s*:\s*break-all/),
      overflow_wrap: a_overflow_wrap,
      overflow_wrap_rule_b: b_overflow_wrap,
      mw_occurrences: mw_occurrences,
      mw_preludes: mw_preludes,
      mw_declarations: a_mw_decls,
      mw_declarations_rule_b: b_mw_decls,
      mw_zero: n(st, ~r/(?:^|[;{])\s*min-width\s*:\s*0\s*(?:;|\})/m)
    }
  end

  # ── reading the prose back out ────────────────────────────────────────────

  # The block wraps across lines, so every figure is matched against a
  # whitespace-normalised copy: `\s+` -> " " keeps the sentences intact while
  # making the regexes independent of where the comment happens to wrap.
  @doc false
  def block(css) do
    case Regex.run(~r|/\*[^*]*THE WRAP RULE.*?\*/|s, css) do
      [b] -> {:ok, b}
      _ -> {:error, "could not locate the THE WRAP RULE comment block in app.css"}
    end
  end

  defp flat(text), do: Regex.replace(~r/\s+/, text, " ")

  defp num(nil), do: nil

  defp num(raw) do
    case Integer.parse(raw) do
      {i, ""} -> i
      _ -> Map.get(@words, String.downcase(raw))
    end
  end

  defp pick(flat_text, key, re, groups) do
    case Regex.run(re, flat_text) do
      nil ->
        {:error,
         "the wrap header no longer states #{key} in a form this test can read " <>
           "(pattern: #{inspect(re.source)}). A sentence this test cannot parse is a RED, " <>
           "not a skip — restate the figure or update this pattern deliberately."}

      [_ | caps] ->
        vals = Enum.zip(groups, Enum.map(caps, &num/1))

        case Enum.find(vals, fn {_k, v} -> is_nil(v) end) do
          {k, _} -> {:error, "stated #{k} is not an integer this test can read"}
          nil -> {:ok, vals}
        end
    end
  end

  @doc false
  def stated(css) do
    with {:ok, b} <- block(css) do
      unless String.contains?(b, @sentinel) do
        throw({:missing_sentinel, @sentinel})
      end

      f = flat(b)

      specs = [
        {~r/(\d+) `word-break` \((\d+) break-word, (\d+) break-all\)/,
         [:word_break, :word_break_break_word, :word_break_break_all]},
        {~r/(\d+) `min-width` \((\d+) occurrences less the (\w+) that are/,
         [:mw_declarations, :mw_occurrences, :mw_preludes]},
        {~r/and (\d+) `overflow-wrap`\./, [:overflow_wrap]},
        {~r/(\d+) of this file's (\d+) `min-width` declarations are this escape/,
         [:mw_zero, :mw_declarations]},
        {~r/the (\w+) that exist are a POPULATION/, [:word_break_break_word]},
        {~r/breaking mid-token IS the reading aid — (\w+) sites/, [:word_break_break_all]}
      ]

      Enum.reduce_while(specs, {:ok, []}, fn {re, groups}, {:ok, acc} ->
        case pick(f, Enum.join(groups, "/"), re, groups) do
          {:ok, vals} -> {:cont, {:ok, acc ++ vals}}
          {:error, why} -> {:halt, {:error, why}}
        end
      end)
    end
  catch
    {:missing_sentinel, s} ->
      {:error, "the wrap header no longer carries the sentinel #{inspect(s)}"}
  end

  @doc """
  The comparator. Returns `[]` when every stated figure matches the derivation,
  or a list of human-readable mismatches. Raises nothing: a located-but-wrong
  figure and an unlocatable figure are both reported, never swallowed.
  """
  def check(css) do
    derived = derive(css)

    case stated(css) do
      {:error, why} ->
        [why]

      {:ok, pairs} ->
        Enum.flat_map(pairs, fn {key, said} ->
          got = Map.fetch!(derived, key)

          if said == got,
            do: [],
            else: ["#{key}: the header states #{said}, the file derives #{got}"]
        end)
    end
  end

  @doc """
  Non-vacuity, proven in-process: falsify one stated integer in a COPY of the
  stylesheet and require `check/1` to report it.
  """
  def mutation_reds_the_check(css) do
    mutated =
      Regex.replace(
        ~r/and (\d+)(\s+)`overflow-wrap`\./,
        css,
        fn _, d, gap -> "and #{String.to_integer(d) + 1}#{gap}`overflow-wrap`." end,
        global: false
      )

    {css != mutated, check(mutated)}
  end

  # ── the assertions ────────────────────────────────────────────────────────

  setup_all do
    assert File.exists?(@css_path), "app.css is missing at #{@css_path}"
    {:ok, css: File.read!(@css_path)}
  end

  test "the two readings of the block's own counting rule agree", %{css: css} do
    d = derive(css)

    assert d.word_break == d.word_break_rule_b,
           "word-break: occurrence rule says #{d.word_break}, declaration-position rule says #{d.word_break_rule_b}"

    assert d.overflow_wrap == d.overflow_wrap_rule_b,
           "overflow-wrap: occurrence rule says #{d.overflow_wrap}, declaration-position rule says #{d.overflow_wrap_rule_b}"

    assert d.mw_declarations == d.mw_declarations_rule_b,
           "min-width: occurrences-minus-preludes says #{d.mw_declarations}, " <>
             "declaration-position rule says #{d.mw_declarations_rule_b}"
  end

  test "the header block and its sentinel are still there", %{css: css} do
    assert {:ok, b} = block(css)
    assert String.contains?(b, @sentinel)
  end

  test "every figure the header states is found, and is an integer", %{css: css} do
    assert {:ok, pairs} = stated(css)
    assert length(pairs) >= 8, "expected at least 8 stated figures, parsed #{length(pairs)}"
    assert Enum.all?(pairs, fn {_k, v} -> is_integer(v) end)
  end

  test "every stated count equals a fresh derivation from this same file", %{css: css} do
    assert check(css) == [],
           """
           The wrap-vocabulary header in cloud/priv/static/app.css is out of date.

           #{Enum.map_join(check(css), "\n", &("  · " <> &1))}

           Re-derive (comments stripped, then declarations counted) and edit the
           prose to match. Do NOT edit this test to match the prose.
           """
  end

  test "the escape count never exceeds the declaration count", %{css: css} do
    d = derive(css)
    assert d.mw_zero <= d.mw_declarations
  end

  test "the header does not quote raw line-grep integers", %{css: css} do
    {:ok, b} = block(css)

    refute Regex.match?(~r/raw line greps are higher \(\s*\d+/, b),
           "raw line greps count this very paragraph and drift on any comment edit; " <>
             "they are deliberately unquoted."
  end

  test "a falsified stated integer reds the comparator", %{css: css} do
    {mutated?, problems} = mutation_reds_the_check(css)

    assert mutated?, "the mutation did not change the source — the arm would be vacuous"

    assert Enum.any?(problems, &String.starts_with?(&1, "overflow_wrap:")),
           "falsifying the stated overflow-wrap count did not red the comparator: #{inspect(problems)}"
  end

  test "a deleted header reds the comparator rather than passing it", %{css: css} do
    beheaded = Regex.replace(~r|/\*[^*]*THE WRAP RULE.*?\*/|s, css, "", global: false)
    refute beheaded == css
    assert [why] = check(beheaded)

    assert why =~ ~r/could not locate|no longer carries the sentinel/,
           "deleting the ruling block must red by name, got: #{why}"
  end

  test "a reworded figure reds rather than going quiet", %{css: css} do
    reworded =
      Regex.replace(~r/and (\d+)(\s+)`overflow-wrap`\./, css, "and some `overflow-wrap`.",
        global: false
      )

    refute reworded == css
    assert [why] = check(reworded)
    assert why =~ "no longer states"
  end
end
