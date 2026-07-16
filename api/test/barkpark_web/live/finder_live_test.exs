defmodule BarkparkWeb.FinderLiveTest do
  @moduledoc """
  The public /finder (search-template W3, the Phoenix framework leg): mounts
  anonymously on the reader layout, carries the graph hook contract the
  Canvas2D renderer ingests, and a search event round-trips into the same
  engine the search channel serves — pure LiveView, zero client search code.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  # Papers are the proven public corpus fixture (same helper the reader tests
  # use) — searchable, published, no bespoke schema needed in the test env.
  defp seed_doc(title) do
    slug = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          title: title,
          body_html: "<p>about #{title}</p>",
          event_type: "plan-written"
        })
      )

    slug
  end

  test "mounts anonymously with the graph hook contract", %{conn: conn} do
    {:ok, view, html} = live(conn, "/finder")

    assert html =~ "Search everything."
    # The hook div carries the renderer's full wire contract (shell renders
    # instantly; the corpus arrives via start_async and patches data-*).
    assert html =~ ~s(phx-hook="FinderGraph")
    assert html =~ "data-nodes="
    assert html =~ "data-edges="

    # The async corpus lands and the attrs update in place (generous timeout —
    # the derivation walks every schema in the test dataset; the default 100ms
    # flakes on a busy CI runner).
    html = render_async(view, 5_000)
    assert html =~ "data-rev="
  end

  test "a search event returns hits from the engine", %{conn: conn} do
    seed_doc("Finder Sentinel Alpha")

    {:ok, view, _html} = live(conn, "/finder")

    html =
      view
      |> element("form")
      |> render_change(%{"q" => "finder sentinel"})

    # The contract: the engine round-trip surfaces the seeded paper as a hit
    # LINKING INTO the native PortableDoc reader. (The displayed title is
    # whatever the fixture stored — the slug here — so assert the semantics,
    # not the fixture's cosmetics.)
    assert html =~ ~s(href="/papers/finder-sentinel-alpha")
    assert html =~ "1 hits"
  end

  test "an empty query clears hits instead of erroring", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/finder")

    html =
      view
      |> element("form")
      |> render_change(%{"q" => "   "})

    assert html =~ "type to search"
  end
end
