defmodule BarkparkWeb.StudioComponents.DocConflictBannerMoreTest do
  @moduledoc """
  task-66200f2c6a01ab57 (from #28809): the clash banner lists every block
  of theirs, so a whole clash drew a banner taller than the form. It shows
  the first five and folds the rest under an "N more" line, every block
  still in the page.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias BarkparkWeb.StudioComponents.Editor

  defp banner(theirs) do
    render_component(&Editor.doc_conflict_banner/1, conflict: true, theirs: theirs)
    |> LazyHTML.from_fragment()
  end

  defp texts(doc, sel), do: doc |> LazyHTML.query(sel) |> Enum.map(&LazyHTML.text/1)

  test "seven of theirs' blocks: five shown, two folded under a '2 more' line, all in the page" do
    theirs = for i <- 1..7, do: "block #{i}"
    doc = banner(theirs)

    assert texts(doc, ~s([data-test-id="doc-conflict-banner"] > blockquote)) ==
             Enum.take(theirs, 5)

    assert [more] = texts(doc, ~s([data-test-id="doc-conflict-more"] > summary))
    assert String.trim(more) == "2 more"

    assert texts(doc, ~s([data-test-id="doc-conflict-more"] > blockquote)) ==
             ["block 6", "block 7"]

    assert texts(doc, "blockquote") == theirs
  end

  test "five or fewer: no fold" do
    doc = banner(for i <- 1..5, do: "block #{i}")
    assert length(texts(doc, "blockquote")) == 5
    assert texts(doc, ~s([data-test-id="doc-conflict-more"])) == []
  end

  test "the fold line in Norwegian" do
    Gettext.with_locale(BarkparkWeb.Gettext, "nb_NO", fn ->
      doc = banner(for i <- 1..8, do: "block #{i}")
      assert [more] = texts(doc, ~s([data-test-id="doc-conflict-more"] > summary))
      assert String.trim(more) == "3 til"
    end)
  end
end
