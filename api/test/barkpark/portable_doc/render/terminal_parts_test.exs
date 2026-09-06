defmodule Barkpark.PortableDoc.Render.TerminalPartsTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Compose

  test "canonical frame keeps escaped chrome and body byte-identical" do
    block = %{
      "type" => "terminal",
      "title" => "<Shell>",
      "footer" => "A & B",
      "live" => "live",
      "children" => []
    }

    expected =
      ~s|<div class="bp-term"><div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title">&lt;Shell&gt;</span><span class="bp-term__live">live</span></div><div class="bp-term__body"></div><div class="bp-term__foot">A &amp; B</div></div>|

    assert Compose.compose_block(block, :article) == %{"kind" => "_raw", "html" => expected}
  end

  test "shared frame fragments preserve existing scalar and live semantics" do
    for title <- [nil, "", "  ", "<script>", false, 42, 1.5, [], %{}],
        footer <- [nil, "", "  ", "&", true, 3.5, [], %{}],
        live <- [nil, false, true, "true", "live", "false", 1] do
      block = %{
        "type" => "terminal",
        "title" => title,
        "footer" => footer,
        "live" => live,
        "children" => []
      }

      original = block
      parts = Compose.terminal_article_parts(block)

      html =
        ~s|<div class="bp-term">#{parts.bar_html}<div class="bp-term__body"></div>#{parts.footer_html}</div>|

      assert Compose.compose_block(block, :article) == %{"kind" => "_raw", "html" => html}
      assert String.contains?(parts.bar_html, "bp-term__live") == live in [true, "true", "live"]
      assert block == original
    end
  end
end
