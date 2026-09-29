defmodule BarkparkWeb.Layouts.ReaderUnsupportedBlockGrepTest do
  @moduledoc """
  pbw-backlog-unsupported-grep-trap — the SERVED `/papers/<slug>` page.

  `Barkpark.PortableDoc.Render.Stylesheet.css/0` is inlined into `<style>` in
  `<head>` by `layouts/bulldocs.html.heex`, so whatever that string carries is
  shipped to every reader of every paper. One comment in
  `api/assets/paper-surface/paper-surface.css` explains the `.bp-unknown-block`
  degrade and QUOTES the placeholder copy `render/walk.ex` emits
  (`"Unsupported block: <kind>"`). A smoke gate written as

      curl -s https://…/papers/<slug> | grep -c "Unsupported block"

  therefore matched on EVERY paper — including papers with no unknown block at
  all — and could never reach 0. `Stylesheet.css/0` now strips comments, so the
  prose reaches the page only when the walker actually emitted an unknown block.

  `Barkpark.PortableDoc.Render.StylesheetTest` proves the same pair against a
  `style: :article` standalone document. This file proves it where the gate
  actually looks: the HTTP response of the reader route, layout and all.

  The two arms are deliberately paired. The negative arm alone would stay green
  if unknown blocks stopped rendering entirely; the positive arm alone would
  stay green if the CSS comment came back.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.PortableDoc.Render

  @normal_slug "reader-unsupported-grep-normal"
  @unknown_slug "reader-unsupported-grep-unknown"

  # The body a real render produces for a forward-compat / corrupt Pd kind —
  # built by the walker itself (`doctype: false` = body fragment, no wrapper),
  # not hand-written, so this arm tracks the walker's actual output.
  defp unknown_block_body do
    Render.render_html(
      %{
        "kind" => "PdContainer",
        "children" => [
          %{"kind" => "PdParagraph", "children" => ["Before."]},
          %{"kind" => "PdHologram"},
          %{"kind" => "PdParagraph", "children" => ["After."]}
        ]
      },
      %{doctype: false}
    )
  end

  defp seed(slug, body_html) do
    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          body_html: body_html,
          event_type: "plan-written"
        })
      )

    :ok
  end

  defp count(haystack, needle), do: length(String.split(haystack, needle)) - 1

  test "a normal paper's served page greps 0 for \"Unsupported block\"", %{conn: conn} do
    seed(@normal_slug, ~s(<section id="b1"><p>Nothing unsupported here.</p></section>))

    html = conn |> get("/papers/#{@normal_slug}") |> html_response(200)

    # Controls — without these a 0 says nothing: the page must really be
    # carrying the inlined stylesheet, and that stylesheet must really be
    # carrying the `.bp-unknown-block` rule the old comment sat next to.
    assert html =~ "<style>"
    assert html =~ ".bp-paper-surface .bp-unknown-block"

    assert count(html, "Unsupported block") == 0,
           "the prose is back on a page with no unknown block — the grep trap returned"

    assert count(html, ~s(class="bp-unknown-block")) == 0,
           "no unknown-block MARKUP should exist on a normal paper"
  end

  test "a paper with a real unknown block still serves the class a gate must count",
       %{conn: conn} do
    body = unknown_block_body()

    # Non-vacuity: the fixture body genuinely degraded, so the assertions below
    # are about the served page and not about a body that never had a block.
    assert body =~ ~s(<div class="bp-unknown-block">Unsupported block: PdHologram</div>)

    seed(@unknown_slug, body)

    html = conn |> get("/papers/#{@unknown_slug}") |> html_response(200)

    assert html =~ ".bp-paper-surface .bp-unknown-block", "stylesheet still inlined"

    assert count(html, ~s(class="bp-unknown-block")) == 1,
           "the rendered unknown block is the signal a gate counts"

    assert count(html, "Unsupported block") == 1,
           "the prose must appear exactly once — from the markup, never from CSS"
  end
end
