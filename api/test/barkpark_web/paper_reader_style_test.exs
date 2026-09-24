defmodule BarkparkWeb.PaperReaderStyleTest do
  @moduledoc """
  The web reader chrome predicate (onb-residue-onb16): article for the two
  article markers AND for no style at all; legacy only for an explicit
  non-article marker. Shared by BulldocsLive and the `/s/:token` fallback.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.PaperReaderStyle

  defp paper(content), do: %{content: content}

  test "no style is the article default" do
    assert PaperReaderStyle.article?(paper(%{}))
    assert PaperReaderStyle.article?(paper(%{"style" => nil}))
    assert PaperReaderStyle.article?(paper(%{"style" => ""}))
    assert PaperReaderStyle.article?(paper(nil))
  end

  test "explicit article markers keep the article chrome" do
    assert PaperReaderStyle.article?(paper(%{"style" => "article"}))
    assert PaperReaderStyle.article?(paper(%{"style" => "article-wide"}))
  end

  test "an explicit non-article marker keeps the legacy chrome" do
    refute PaperReaderStyle.article?(paper(%{"style" => "email"}))
    refute PaperReaderStyle.article?(paper(%{"style" => "legacy"}))
  end

  test "no paper is not an article" do
    refute PaperReaderStyle.article?(nil)
  end

  test "only article-wide opens the wide shell" do
    assert PaperReaderStyle.wide?(paper(%{"style" => "article-wide"}))
    refute PaperReaderStyle.wide?(paper(%{"style" => "article"}))
    refute PaperReaderStyle.wide?(paper(%{}))
    refute PaperReaderStyle.wide?(nil)
  end
end
