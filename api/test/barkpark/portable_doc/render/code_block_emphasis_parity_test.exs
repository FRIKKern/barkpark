defmodule Barkpark.PortableDoc.Render.CodeBlockEmphasisParityTest do
  @moduledoc """
  The Elixir legs of the code-block LINE-EMPHASIS parity lock
  (pe-bl-code-emphasis) — BOTH of them: the `:article` web leg that emits the
  spans, and the `:email` leg that must not.

  All engines read ONE fixture file —
  `api/test/support/fixtures/code-block-emphasis-parity.json`. The Go TUI leg is
  `internal/pdrender/code_block_emphasis_parity_test.go`; the JS SDK leg is
  `js/packages/react/tests/code-block-emphasis.parity.test.ts`. Each engine
  derives its own rendering from the SAME `line_tones` array, so the three
  surfaces cannot disagree about which line carries which tone — only about how
  a tone LOOKS, which is the whole point of a cross-surface degradation.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Compose
  alias Barkpark.PortableDoc.Render.Util

  @fixture Path.expand("../../../support/fixtures/code-block-emphasis-parity.json", __DIR__)

  @external_resource @fixture

  @doc_json @fixture |> File.read!() |> Jason.decode!()
  @cases Map.fetch!(@doc_json, "cases")
  @tones Map.fetch!(@doc_json, "tones")
  @source Map.fetch!(@doc_json, "source")
  @prefix Map.fetch!(@doc_json, "span_class_prefix")

  test "the shared fixture is the one every engine reads, and it names the closed vocabulary" do
    assert File.exists?(@fixture),
           "the shared code-emphasis fixture is missing: #{@fixture} — " <>
             "internal/pdrender/code_block_emphasis_parity_test.go reads the same path"

    assert @tones == ["comment", "offending", "fixed"]
    assert @prefix == "bp-code-em"
    assert length(@cases) >= 7

    for c <- @cases do
      assert Map.fetch!(c["block"], "value") == @source,
             "every case must share ONE source so the legs compare like for like"

      assert length(c["line_tones"]) == length(String.split(@source, "\n")),
             "case #{c["name"]}: line_tones must carry one entry per source line"
    end
  end

  defp expected_body(line_tones) do
    @source
    |> String.split("\n")
    |> Enum.zip(line_tones)
    |> Enum.map_join("\n", fn
      {line, nil} ->
        Util.escape_html(line)

      {line, tone} ->
        ~s|<span class="bp-code-em bp-code-em--#{tone}">#{Util.escape_html(line)}</span>|
    end)
  end

  for {c, i} <- Enum.with_index(@cases) do
    @case c
    @idx i

    test "#{i}: #{c["name"]} — :article emits exactly the fixture's per-line tones" do
      html = @case["block"] |> Compose.compose_block(:article) |> Map.get("html", "")
      body = expected_body(@case["line_tones"])

      assert String.contains?(html, body),
             "case #{@idx} (#{@case["name"]}): the composed `<pre>` body did not match the " <>
               "fixture's line_tones.\nexpected body:\n#{body}\n\ngot:\n#{html}"
    end

    test "#{i}: #{c["name"]} — :email IGNORES emphasis and emits no span" do
      stripped = Map.delete(@case["block"], "emphasis")

      assert Compose.compose_block(@case["block"], :email) ==
               Compose.compose_block(stripped, :email),
             "case #{@idx} (#{@case["name"]}): the email arm composed differently WITH the " <>
               "`emphasis` field than without it — email must degrade to plain"

      refute @case["block"]
             |> Compose.compose_block(:email)
             |> inspect()
             |> String.contains?(@prefix),
             "case #{@idx} (#{@case["name"]}): the email compose carried a #{@prefix} class"
    end
  end

  test "a block whose ranges ALL drop is byte-identical to a block with no emphasis key" do
    # Fixture cases 0 (no key), 4 (unknown tone) share one value; case 5's
    # malformed ranges all drop but for one live `fixed` range, so it is NOT in
    # this set — it is the control proving the comparison can still fail.
    legacy = Compose.compose_block(Enum.at(@cases, 0)["block"], :article)
    unknown_tone = Compose.compose_block(Enum.at(@cases, 4)["block"], :article)
    live = Compose.compose_block(Enum.at(@cases, 5)["block"], :article)

    assert unknown_tone == legacy,
           "a code block whose only range carries an unknown tone must render like a block " <>
             "with no `emphasis` key at all"

    refute live == legacy,
           "CONTROL: case 5 keeps one well-formed `fixed` range, so it MUST differ from the " <>
             "legacy render — if it does not, this comparison proves nothing"
  end

  test "the tone reaching the class name comes from the closed vocabulary, never the author" do
    hostile = %{
      "type" => "code",
      "value" => @source,
      "emphasis" => [%{"from" => 1, "tone" => ~s|fixed"><script>alert(1)</script>|}]
    }

    html = hostile |> Compose.compose_block(:article) |> Map.get("html", "")

    refute String.contains?(html, "<script>"),
           "an author tone outside the vocabulary must be DROPPED, not interpolated"

    assert html == Compose.compose_block(Enum.at(@cases, 0)["block"], :article)["html"]
  end
end
