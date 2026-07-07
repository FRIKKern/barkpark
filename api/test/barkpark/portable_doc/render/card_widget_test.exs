defmodule Barkpark.PortableDoc.Render.CardWidgetTest do
  @moduledoc """
  STEP 4 (composition-doctrine FINALE) — the card WIDGET reader proof.

  BACKWARD-COMPAT is the #1 gate: the legacy `cards` fleet grid MUST keep rendering
  byte-for-byte (any drift reds). The card WIDGET is ADDITIVE — a section-of-cards
  renders == a legacy cards grid at ITEM granularity, so `Components.card_html/1` is
  byte-exact to ONE legacy `cards` item for every tone + the empty-title/body variants.
  And there is ONE reader producer: `Render.render_block(card, :article)` routes
  through `Components.card_html/1`.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Components

  @article %{style: :article}

  # A card WIDGET equivalent to one legacy `cards` item (title/body/tone).
  defp card(title, body, tone) do
    slots =
      %{"body" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => body}]}]}
      |> maybe_put_title(title)

    %{"id" => "cw-1", "type" => "card", "slots" => slots}
    |> maybe_put_tone(tone)
  end

  defp maybe_put_title(slots, ""), do: slots
  defp maybe_put_title(slots, title),
    do: Map.put(slots, "title", [%{"type" => "heading", "text" => title}])

  defp maybe_put_tone(block, nil), do: block
  defp maybe_put_tone(block, tone), do: Map.put(block, "tone", tone)

  # One legacy `cards` item, sliced out of its `bp-cards` grid wrapper — the exact
  # bytes a card must byte-match.
  defp legacy_item(title, text, tone) do
    grid =
      Components.cards_html(%{
        "type" => "cards",
        "items" => [%{"title" => title, "text" => text, "tone" => tone}]
      })

    grid
    |> String.replace_prefix(~s(<div class="bp-cards">), "")
    |> String.replace_suffix("</div>", "")
  end

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

  describe "the card WIDGET renders == one legacy cards item (item-granular proof)" do
    test "byte-exact for every tone (info|ok|warn|danger) and an UNKNOWN tone" do
      for tone <- ~w(info ok warn danger purple) do
        assert Components.card_html(card("Title", "Body", tone)) ==
                 legacy_item("Title", "Body", tone),
               "card_html drifted from the legacy item for tone #{inspect(tone)}"
      end
    end

    test "byte-exact with an EMPTY title (no bp-card__t)" do
      html = Components.card_html(card("", "Body", "info"))
      assert html == legacy_item("", "Body", "info")
      refute html =~ "bp-card__t"
      assert html =~ "bp-card__d"
    end

    test "byte-exact with an EMPTY body (no bp-card__d)" do
      html = Components.card_html(card("Title", "", "info"))
      assert html == legacy_item("Title", "", "info")
      assert html =~ "bp-card__t"
      refute html =~ "bp-card__d"
    end

    test "a tone-less card gets NO modifier (byte-matches a tone-less legacy item)" do
      html = Components.card_html(card("Title", "Body", nil))
      assert html == legacy_item("Title", "Body", "")
      refute html =~ "bp-card--"
    end

    test "HTML-escapes title AND body (no XSS via slot text)" do
      html = Components.card_html(card("A <b>", "x & y <s>", "info"))
      assert html =~ "A &lt;b&gt;"
      assert html =~ "x &amp; y &lt;s&gt;"
      refute html =~ "<b>"
    end
  end

  describe "the card WIDGET's OPTIONAL media/action slots are additive" do
    test "media PREPENDS a bp-card__media <img>; action APPENDS a bp-card__action link" do
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
      assert html =~ ~s(<div class="bp-card__media"><img src="/pic.png" alt="pic"></div>)
      assert html =~ ~s(<div class="bp-card__action"><a href="/go">Go</a></div>)

      # media before title, action after body (compat byte positions preserved).
      assert :binary.match(html, "bp-card__media") < :binary.match(html, "bp-card__t")
      assert :binary.match(html, "bp-card__d") < :binary.match(html, "bp-card__action")
    end

    test "the title/body byte-window with media+action absent is unchanged (subset is exact)" do
      # Same card minus media/action must be byte-identical to a legacy item.
      block = card("T", "B", "info")
      assert Components.card_html(block) == legacy_item("T", "B", "info")
    end
  end

  describe "ONE reader producer (mirrors parity gate §1)" do
    test "render_block(card, :article) == Components.card_html(card), non-vacuous" do
      block = card("Title", "Body", "info")
      html = Render.render_block(block, @article)
      assert html == Components.card_html(block)
      assert byte_size(html) > 0
      assert html =~ "bp-card"
    end
  end
end
