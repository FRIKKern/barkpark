defmodule Barkpark.PortableDoc.Render.CardWidgetTest do
  @moduledoc """
  The card WIDGET reader proof — MODEL B (au-w5-card-slot-parity).

  The card's slots hold ARBITRARY element children, recursed through the ONE shared
  compose→walk bridge (`Compose.render_children/2`, the same terminal/columns use):
  an `image` media child fast-paths to a real `<img>`, an `action` child to a button
  link, a `heading`/`paragraph` title/body child to a semantic `<h_>`/`<p>` — no
  card-specific `bp-card__t/__d/__media/__action` chrome. Slots render in the order
  `media, title, body, action`; the legacy `tone` accent (info|ok|warn|danger) is
  KEPT; an all-empty card renders as a blank `bp-card` container.

  The legacy `cards` FLEET grid (`cards_html/1`) is UNTOUCHED and stays byte-frozen
  (it is a distinct emitter from the slots-native `card` widget). ONE reader producer:
  `Render.render_block(card, :article)` routes through `Components.card_html/1`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Components

  @article %{style: :article}

  # A card WIDGET with an OPTIONAL title heading + OPTIONAL body paragraph + tone.
  # An empty title/body means the SLOT is absent (not a present-but-empty element).
  defp card(title, body, tone) do
    slots =
      %{}
      |> maybe_put_title(title)
      |> maybe_put_body(body)

    %{"id" => "cw-1", "type" => "card", "slots" => slots}
    |> maybe_put_tone(tone)
  end

  defp maybe_put_title(slots, ""), do: slots

  defp maybe_put_title(slots, title),
    do: Map.put(slots, "title", [%{"type" => "heading", "text" => title}])

  defp maybe_put_body(slots, ""), do: slots

  defp maybe_put_body(slots, body),
    do:
      Map.put(slots, "body", [
        %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => body}]}
      ])

  defp maybe_put_tone(block, nil), do: block
  defp maybe_put_tone(block, tone), do: Map.put(block, "tone", tone)

  describe "backward-compat: the legacy `cards` fleet grid is byte-frozen" do
    test "a pinned two-item cards block renders to the EXACT expected string" do
      cards = %{
        "id" => "c1",
        "type" => "cards",
        "items" => [
          %{"title" => "Alpha", "text" => "first", "tone" => "info"},
          %{"title" => "Beta", "text" => "second", "tone" => "warn"}
        ]
      }

      expected =
        ~s(<div class="bp-cards">) <>
          ~s(<div class="bp-card bp-card--info"><div class="bp-card__t">Alpha</div><div class="bp-card__d">first</div></div>) <>
          ~s(<div class="bp-card bp-card--warn"><div class="bp-card__t">Beta</div><div class="bp-card__d">second</div></div>) <>
          ~s(</div>)

      assert Components.cards_html(cards) == expected

      # And the reader routes through that ONE producer (compose_block(cards) is
      # unchanged — the parity gate pins this; here we re-freeze the bytes).
      assert Render.render_block(cards, @article) == expected
    end
  end

  describe "the card WIDGET (model B): tone accent + semantic title/body" do
    test "tone info|ok|warn|danger → the bp-card--<tone> modifier is kept" do
      for tone <- ~w(info ok warn danger) do
        html = Components.card_html(card("Title", "Body", tone))
        assert html =~ ~s(<div class="bp-card bp-card--#{tone}">), "tone #{tone} modifier missing"
      end
    end

    test "an UNKNOWN tone (not in the allowlist) gets NO modifier" do
      html = Components.card_html(card("Title", "Body", "purple"))
      refute html =~ "bp-card--"
      assert html =~ ~s(<div class="bp-card">)
    end

    test "a tone-less card gets NO modifier" do
      html = Components.card_html(card("Title", "Body", nil))
      refute html =~ "bp-card--"
    end

    test "title recurses to a semantic <h_>, body to a <p> (no flatten wrappers)" do
      html = Components.card_html(card("Card title", "Card body text.", "info"))
      assert html =~ "<h2>Card title</h2>"
      assert html =~ "<p>Card body text.</p>"
      # Model B DROPPED the legacy flatten wrappers.
      refute html =~ "bp-card__t"
      refute html =~ "bp-card__d"
    end

    test "an EMPTY title omits the heading; an EMPTY body omits the paragraph" do
      no_title = Components.card_html(card("", "Body", "info"))
      refute no_title =~ "<h2>"
      assert no_title =~ "<p>Body</p>"

      no_body = Components.card_html(card("Title", "", "info"))
      assert no_body =~ "<h2>Title</h2>"
      refute no_body =~ "<p>"
    end

    test "an ALL-EMPTY card renders as a blank bp-card container (no stray chrome)" do
      blank = Components.card_html(%{"type" => "card", "slots" => %{}})
      assert blank == ~s(<div class="bp-card"></div>)

      # tone is still honoured on an otherwise-empty card.
      toned = Components.card_html(%{"type" => "card", "tone" => "warn", "slots" => %{}})
      assert toned == ~s(<div class="bp-card bp-card--warn"></div>)
    end

    test "HTML-escapes title AND body text (no XSS via slot text)" do
      html = Components.card_html(card("A <b>", "x & y <s>", "info"))
      assert html =~ "A &lt;b&gt;"
      assert html =~ "x &amp; y &lt;s&gt;"
      refute html =~ "<b>"
    end
  end

  describe "the card WIDGET's media/action slots recurse as elements (model B)" do
    test "an image media child fast-paths to <img>; an action child to a button link" do
      block = %{
        "id" => "cw-2",
        "type" => "card",
        "tone" => "info",
        "slots" => %{
          "title" => [%{"type" => "heading", "text" => "T"}],
          "body" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "B"}]}],
          "media" => [%{"type" => "image", "src" => "/pic.png", "alt" => "pic"}],
          "action" => [%{"type" => "action", "href" => "/go", "label" => "Go"}]
        }
      }

      html = Components.card_html(block)
      assert html =~ ~s(<img src="/pic.png" alt="pic")
      assert html =~ ~s(<a href="/go" class="bp-button">Go</a>)

      # Slot ORDER: media, title, body, action.
      assert :binary.match(html, "/pic.png") < :binary.match(html, "<h2>T</h2>")
      assert :binary.match(html, "<h2>T</h2>") < :binary.match(html, "<p>B</p>")
      assert :binary.match(html, "<p>B</p>") < :binary.match(html, "bp-button")
    end
  end

  describe "back-compat: persisted typed slots render; typeless media normalizes" do
    test "a persisted card with typed image + action slots renders the image and the button" do
      block = %{
        "type" => "card",
        "slots" => %{
          "media" => [%{"type" => "image", "src" => "/a.png", "alt" => "a"}],
          "action" => [%{"type" => "action", "href" => "/b", "label" => "B"}]
        }
      }

      html = Components.card_html(block)
      assert html =~ ~s(<img src="/a.png" alt="a")
      assert html =~ ~s(<a href="/b" class="bp-button">B</a>)
    end

    test "a media element WITHOUT a type key normalizes to an image (fast-path, not degrade)" do
      block = %{"type" => "card", "slots" => %{"media" => [%{"src" => "/x.png", "alt" => "z"}]}}
      html = Components.card_html(block)
      assert html =~ ~s(<img src="/x.png" alt="z")
      refute html =~ "Unsupported block"
      refute html =~ "bp-unknown-block"
    end
  end

  describe "ONE reader producer (mirrors parity gate §1)" do
    test "article parts reconstruct the exact canonical reader bytes" do
      block = %{
        "type" => "card",
        "tone" => "info",
        "slots" => %{
          "media" => [%{"src" => "/cover.png", "alt" => "Cover"}],
          "title" => [%{"type" => "heading", "level" => 3, "text" => "Title"}],
          "body" => [
            %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "Body"}]}
          ],
          "action" => [%{"type" => "action", "href" => "/go", "label" => "Go"}]
        }
      }

      parts = Components.card_article_parts(block)

      assert ~s|<div class="#{parts.class}">#{parts.media_html}#{parts.title_html}#{parts.body_html}#{parts.action_html}</div>| ==
               Components.card_html(block)

      assert parts.class == "bp-card bp-card--info"
      assert parts.media_html =~ ~s(<img src="/cover.png" alt="Cover")
      assert parts.title_html == "<h3>Title</h3>"
      assert parts.body_html == "<p>Body</p>"
      assert parts.action_html == ~s(<a href="/go" class="bp-button">Go</a>)
    end

    test "render_block(card, :article) == Components.card_html(card), non-vacuous" do
      block = card("Title", "Body", "info")
      html = Render.render_block(block, @article)
      assert html == Components.card_html(block)
      assert byte_size(html) > 0
      assert html =~ "bp-card"
    end
  end
end
