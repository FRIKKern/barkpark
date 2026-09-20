defmodule Barkpark.PortableDoc.Render.TerminalPartsTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Compose

  # The LITERAL chrome each scalar title must produce, written out by hand — NOT
  # derived from `terminal_article_parts/1`. The 504-case loop below reconstructs
  # the frame FROM the function under test (both sides of that `==` move together),
  # so these tables are what actually holds the scalar-coercion axis: corrupting
  # the non-binary title branch reds `bar_html`, corrupting the non-binary footer
  # branch reds `footer_html`, and the two are separate assertions on purpose.
  # Same posture as card_widget_test.exs — make the reconstruct equality, THEN pin
  # every part absolutely.
  @title_bar %{
    nil =>
      ~s|<div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title"></span>|,
    "" =>
      ~s|<div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title"></span>|,
    "  " =>
      ~s|<div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title">  </span>|,
    "<script>" =>
      ~s|<div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title">&lt;script&gt;</span>|,
    false =>
      ~s|<div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title">false</span>|,
    42 =>
      ~s|<div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title">42</span>|,
    1.5 =>
      ~s|<div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title">1.5</span>|,
    [] =>
      ~s|<div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title"></span>|,
    %{} =>
      ~s|<div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title"></span>|
  }

  @footer_html %{
    nil => "",
    "" => "",
    "  " => ~s|<div class="bp-term__foot">  </div>|,
    "&" => ~s|<div class="bp-term__foot">&amp;</div>|,
    true => ~s|<div class="bp-term__foot">true</div>|,
    3.5 => ~s|<div class="bp-term__foot">3.5</div>|,
    [] => "",
    %{} => ""
  }

  @live_span ~s|<span class="bp-term__live">live</span>|

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

      # The two pins below are what makes this loop able to FAIL on the
      # scalar axis. They are independent: the title arm reds the first,
      # the footer arm reds the second.
      live_on = live in [true, "true", "live"]

      assert parts.bar_html ==
               Map.fetch!(@title_bar, title) <> if(live_on, do: @live_span, else: "") <> "</div>"

      assert parts.footer_html == Map.fetch!(@footer_html, footer)

      assert String.contains?(parts.bar_html, "bp-term__live") == live_on
      assert block == original
    end
  end

  test "a NUMERIC and a BOOLEAN title/footer render pinned literal bytes" do
    # Criterion: the expected side is written out, never produced by
    # terminal_article_parts/1. One numeric input and one boolean input per field.
    numeric = %{
      "type" => "terminal",
      "title" => 42,
      "footer" => 3.5,
      "live" => nil,
      "children" => []
    }

    assert Compose.compose_block(numeric, :article) == %{
             "kind" => "_raw",
             "html" =>
               ~s|<div class="bp-term"><div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title">42</span></div><div class="bp-term__body"></div><div class="bp-term__foot">3.5</div></div>|
           }

    boolean = %{
      "type" => "terminal",
      "title" => false,
      "footer" => true,
      "live" => nil,
      "children" => []
    }

    assert Compose.compose_block(boolean, :article) == %{
             "kind" => "_raw",
             "html" =>
               ~s|<div class="bp-term"><div class="bp-term__bar"><span class="bp-term__dots"><i></i><i></i><i></i></span><span class="bp-term__title">false</span></div><div class="bp-term__body"></div><div class="bp-term__foot">true</div></div>|
           }
  end
end
