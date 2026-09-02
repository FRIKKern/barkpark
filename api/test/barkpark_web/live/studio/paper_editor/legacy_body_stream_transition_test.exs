defmodule BarkparkWeb.Studio.PaperEditor.LegacyBodyStreamTransitionTest do
  @moduledoc """
  spd-w18 — THE LEGACY-HTML ARM MUST NOT SHARE THE STREAMED ARM'S CONTAINER ID.

  The paper pane's `cond` (`studio_live/components.ex`) had two arms rendering
  the SAME node id: the block arm renders
  `<article id="paper-body-<slug>" phx-update="stream">`, and the legacy-HTML
  arm (the final `true` clause) rendered that same id WITHOUT `phx-update`.

  A stream container never removes children it did not insert (`dom_patch.js`
  deletes only `[data-phx-stream-ref]` rows on a reset). So when a legacy
  `body_html` paper GAINS a block list while its pane is open, LiveView saw one
  node keep its id while GAINING `phx-update="stream"`, and the pre-transition
  opaque body SURVIVED inside the new stream container, stacked above the
  streamed blocks. `LiveViewTest` refuses that transition outright ("setting
  phx-update to stream requires setting an ID on each child") — which is how
  the same class was caught one arm over (spd-w19, the never-blank notice arm,
  now `paper-body-unrenderable-<slug>`).

  The fix is the same shape: the legacy arm owns `paper-body-legacy-<slug>`, so
  the transition is a node REPLACEMENT — which is what it is. The streamed
  arm's id is untouched, so every existing pin on `paper-body-<slug>` still
  names the same node.

  The canvas flag is pinned OFF by `BarkparkWeb.PaperEditorTestHelpers`' setup
  (which owns the `on_exit` restore) because the streamed arm is only what
  renders on the opt-out path — with the canvas ON a block-backed paper opens
  straight into the editor and never reaches the streamed container at all.
  """
  use BarkparkWeb.ConnCase, async: false
  use BarkparkWeb.PaperEditorTestHelpers

  @legacy_slug "2026-06-24-legacy-body-transition"

  # The opaque authored bytes, carrying their own element so the pre-transition
  # state is asserted on an ELEMENT and not on a substring a comment could
  # satisfy.
  @legacy_marker "Legacy opaque body, authored before blocks existed."

  setup do
    {:ok, _} =
      Barkpark.Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @legacy_slug,
          dataset: @dataset,
          body_html: ~s(<p data-test-id="legacy-opaque-body">#{@legacy_marker}</p>)
        })
      )

    :ok
  end

  defp open_legacy(conn),
    do: live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@legacy_slug}"))

  defp query(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)

  defp article_ids(html) do
    html
    |> query("article")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> List.first()))
  end

  # THE CONVERSION, in the two real steps an html→blocks ingest takes on the
  # PUBLISHED row (no `drafts.` detour, so the pane's slug — and therefore the
  # container id keyed on it — never changes):
  #
  #   1. `upsert_paper/1` replaces the opaque body with a block list. It
  #      broadcasts `{:paper_updated, …}` only, and that handler pins
  #      `paper_block_mode` false — so the pane absorbs the write WITHOUT
  #      leaving the legacy arm. The legacy <article> is still the live node.
  #   2. the next block op on the now-block-backed paper broadcasts
  #      `{:paper_block, …}`; `Handlers.Lifecycle.paper_block/2` sees a pane
  #      that is not yet in block mode and calls `Shared.refetch_paper/1`,
  #      which flips `paper_block_mode` true and fills the stream. THAT is the
  #      render crossing from the legacy arm to the streamed one.
  #
  # Both broadcasts carry `sender` = this test process, so neither is skipped
  # by the self-write guards — this is a SECOND producer, exactly as ingest is.
  defp convert_to_blocks! do
    {:ok, _} =
      Barkpark.Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @legacy_slug,
          dataset: @dataset,
          blocks: [
            %{
              "id" => "p-converted",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Converted block body."}]
            }
          ]
        })
      )
  end

  defp append_block! do
    {:ok, _} =
      Barkpark.Content.apply_paper_block_op(
        @legacy_slug,
        %{
          "op" => "append-block",
          "block" => %{
            "id" => "p-appended",
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "Appended after the conversion."}]
          }
        },
        @dataset
      )
  end

  test "the legacy-HTML arm renders under its OWN container id, never the streamed arm's",
       %{conn: conn} do
    {:ok, _view, html} = open_legacy(conn)

    body = query(html, ~s([data-test-id="legacy-opaque-body"]))

    assert Enum.count(body) == 1,
           "the seeded body_html never rendered — this fixture does not reach the legacy arm, " <>
             "so everything below would be vacuous"

    assert LazyHTML.text(body) =~ @legacy_marker

    ids = article_ids(html)

    # The positive half: the legacy arm has an id of its own, and it is the one
    # holding the raw body.
    assert "paper-body-legacy-#{@legacy_slug}" in ids

    assert html
           |> query(~s(article[id="paper-body-legacy-#{@legacy_slug}"]))
           |> LazyHTML.text() =~ @legacy_marker

    # The refute it exists for: that id is NOT the streamed arm's. Its partner
    # assert stands two lines above, so a vacuated refute cannot go false-green.
    refute "paper-body-#{@legacy_slug}" in ids,
           "the legacy arm is rendering under the STREAMED arm's container id — " <>
             "one node id, two arms, which is the defect"
  end

  test "a legacy body_html paper that GAINS a block list drops its raw body — the streamed container never inherits it",
       %{conn: conn} do
    {:ok, view, html} = open_legacy(conn)

    assert Enum.count(query(html, ~s([data-test-id="legacy-opaque-body"]))) == 1
    pid_before = view.pid

    convert_to_blocks!()
    append_block!()

    # On the shared-id render this line never returns: LiveViewTest merges the
    # streamed <article> onto the legacy node of the same id, the opaque body
    # survives as an id-less child, and `phx-update="stream"` raises
    # ArgumentError. With the arms on distinct ids the swap is a replacement.
    after_html = render(view)

    # Same process throughout — one live pane, not a remount.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
    assert Enum.count(query(after_html, "#paper-sentinel")) == 1

    ids = article_ids(after_html)

    # The pane crossed to the streamed arm, and the legacy container is gone
    # from the document (not merely emptied).
    assert "paper-body-#{@legacy_slug}" in ids
    refute "paper-body-legacy-#{@legacy_slug}" in ids

    streamed = query(after_html, ~s(article[id="paper-body-#{@legacy_slug}"]))

    assert Enum.count(streamed) == 1
    assert streamed |> LazyHTML.attribute("phx-update") |> List.first() == "stream"

    # THE ASSERTION. Every child of the stream container is a row the stream
    # inserted; the pre-transition raw body — an id-less, block-id-less child —
    # is ABSENT. The paired row count keeps it non-vacuous: an EMPTY container
    # would satisfy a bare "no survivors" check.
    survivors =
      query(after_html, ~s|article[id="paper-body-#{@legacy_slug}"] > *:not([data-block-id])|)

    assert Enum.count(survivors) == 0,
           "the pre-transition body SURVIVED inside the stream container it never belonged to"

    rows = query(after_html, ~s|article[id="paper-body-#{@legacy_slug}"] > [data-block-id]|)

    assert Enum.count(rows) == 2
    assert LazyHTML.text(rows) =~ "Converted block body."
    assert LazyHTML.text(rows) =~ "Appended after the conversion."

    # And the opaque legacy bytes are nowhere in the pane any more.
    assert Enum.count(query(after_html, ~s([data-test-id="legacy-opaque-body"]))) == 0
    refute after_html =~ @legacy_marker
  end
end
