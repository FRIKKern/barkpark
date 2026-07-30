defmodule BarkparkWeb.Layouts.ReaderFontFaceTest do
  @moduledoc """
  Reader serif self-host guard (unified-aesthetic S9).

  `font.reading` names `"Source Serif 4"` as the paper prose stack's web-safe
  fallback, but the `/papers` reader head (`layouts/bulldocs.html.heex`) shipped
  ZERO `@font-face` — so off-macOS (no Iowan Old Style / Palatino) the stack fell
  through to bare `serif` instead of the intended face. S9 self-hosts the Source
  Serif 4 variable woff2 pair on the reader exactly as `root.html.heex` does for
  the Studio shell.

  This is a needle test: it reads the layout SOURCE and asserts the reader head
  serves the pair from the HAND-AUTHORED region (never inside the generated
  tokens block), and that the Studio shell + tokens.json stay in lockstep with
  no dangling `src` pointing at a deleted static TTF.
  """
  use ExUnit.Case, async: true

  @moduletag :reader_fonts

  @bulldocs Path.expand(
              "../../../lib/barkpark_web/layouts/bulldocs.html.heex",
              __DIR__
            )

  @root Path.expand(
          "../../../lib/barkpark_web/layouts/root.html.heex",
          __DIR__
        )

  @tokens Path.expand("../../../../design/tokens.json", __DIR__)

  @roman "/fonts/SourceSerif4Variable-Roman.woff2"
  @italic "/fonts/SourceSerif4Variable-Italic.woff2"

  @fonts_dir Path.expand("../../../priv/static/fonts", __DIR__)

  test "the /papers reader head self-hosts the Source Serif 4 variable pair" do
    src = File.read!(@bulldocs)

    assert String.contains?(src, "font-family: 'Source Serif 4'"),
           "reader head is missing the Source Serif 4 @font-face — the named " <>
             "fallback resolves to nothing self-hosted off-macOS"

    assert String.contains?(src, @roman),
           "reader head is missing the Roman variable woff2 (#{@roman})"

    assert String.contains?(src, @italic),
           "reader head is missing the Italic variable woff2 (#{@italic})"
  end

  test "the reader @font-face lives in the HAND-AUTHORED region, above the generated marker" do
    src = File.read!(@bulldocs)

    [head | _] = String.split(src, "BEGIN GENERATED", parts: 2)

    assert String.contains?(head, "font-family: 'Source Serif 4'"),
           "the Source Serif 4 @font-face must sit ABOVE the BEGIN GENERATED " <>
             "marker — nothing there fans from tokens.json, so it is hand-authored"
  end

  test "no reader @font-face src points at a deleted static TTF" do
    src = File.read!(@bulldocs)

    refute src =~ ~r{/fonts/SourceSerif4-(Regular|Italic|Bold|BoldItalic)\.ttf},
           "reader head references a static TTF that S9 deleted — dangling src"
  end

  test "the Studio shell serves the same variable pair in lockstep (no dangling TTF src)" do
    src = File.read!(@root)

    assert String.contains?(src, @roman) and String.contains?(src, @italic),
           "root.html.heex must serve the same variable woff2 pair as the reader"

    refute src =~ ~r{/fonts/SourceSerif4-(Regular|Italic|Bold|BoldItalic)\.ttf},
           "root.html.heex still points at a static TTF S9 deleted — dangling src"
  end

  test "the committed font binaries + OFL license exist and the old TTFs are gone" do
    for f <- [
          "SourceSerif4Variable-Roman.woff2",
          "SourceSerif4Variable-Italic.woff2",
          "SourceSerif4-OFL.txt"
        ] do
      assert File.exists?(Path.join(@fonts_dir, f)), "missing committed font asset: #{f}"
    end

    for f <- [
          "SourceSerif4-Regular.ttf",
          "SourceSerif4-Italic.ttf",
          "SourceSerif4-Bold.ttf",
          "SourceSerif4-BoldItalic.ttf"
        ] do
      refute File.exists?(Path.join(@fonts_dir, f)),
             "the old static TTF #{f} should have been removed in the same commit as the woff2 swap"
    end
  end

  test "tokens.json records reading self-host metadata but keeps the stack order untouched" do
    reading = @tokens |> File.read!() |> Jason.decode!() |> get_in(["font", "reading"])

    assert reading["selfHosted"] == true,
           "font.reading.selfHosted should flip true — Source Serif 4 is now self-hosted"

    # The stack ORDER is a future one-line human-gated cutover — S9 must NOT reorder it.
    assert String.starts_with?(reading["stack"], "\"Iowan Old Style\""),
           "font.reading.stack ORDER changed — Iowan Old Style must still be first " <>
             "(the reorder is a separate human-gated cutover, not this slice)"

    assert String.ends_with?(reading["stack"], "\"Source Serif 4\", serif"),
           "Source Serif 4 must stay the LAST-but-serif fallback, not promoted"
  end
end
