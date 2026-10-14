defmodule Barkpark.PortableDoc.Render.StatDotsTest do
  # Pure, in-process render — no DB, no Phoenix boot.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Compose
  alias Barkpark.PortableDoc.Render.DataViz

  # Stat trial dots (pe-bl-stat-tile-dots): `dots: %{"on" => 2, "of" => 10}`
  # on a stat or a stats item. Web draws `of` dots, the first `on` filled, as
  # ONE image to assistive tech; email degrades to "●●○○… 2/10" text.
  #
  #   * drop `dots_html(block)` from DataViz.stat_html/1   → the web tests red.
  #   * drop `dots_email` from DataViz.stat_email_html/2   → the email tests red.
  #
  # JS mirror: js/packages/react/tests/stat-dots.parity.test.ts. TUI mirror:
  # internal/pdrender/stat_test.go. The stat / stats / nb-NO pd-parity goldens
  # carry a dots field, so the three renderers are held to one shape.

  @on ~s|<i class="bp-stat__dot bp-stat__dot--on" aria-hidden="true"></i>|
  @off ~s|<i class="bp-stat__dot" aria-hidden="true"></i>|

  defp count(html, needle), do: length(String.split(html, needle)) - 1

  describe "web" do
    test "draws of dots, the first on filled, labelled once as an image" do
      html =
        DataViz.stat_html(%{
          "value" => "2",
          "label" => "trials",
          "dots" => %{"on" => 2, "of" => 10}
        })

      assert html =~ ~s|<div class="bp-stat__dots" role="img" aria-label="2 of 10">|
      assert count(html, @on) == 2
      assert count(html, @off) == 8
    end

    test "the label is in the render's language" do
      html =
        Render.render_block(
          %{"type" => "stat", "value" => "2", "dots" => %{"on" => 2, "of" => 10}},
          %{style: :article, locale: "nb-NO"}
        )

      assert html =~ ~s|aria-label="2 av 10"|
    end

    test "on is clamped into 0..of, and whole-number strings and floats count" do
      assert count(DataViz.stat_html(%{"value" => "1", "dots" => %{"on" => 99, "of" => 3}}), @on) ==
               3

      assert count(DataViz.stat_html(%{"value" => "1", "dots" => %{"on" => -4, "of" => 3}}), @off) ==
               3

      assert DataViz.stat_html(%{"value" => "1", "dots" => %{"on" => "1", "of" => " 4 "}}) =~
               ~s|aria-label="1 of 4"|

      assert DataViz.stat_html(%{"value" => "1", "dots" => %{"on" => 1.0, "of" => 4.0}}) =~
               ~s|aria-label="1 of 4"|
    end

    test "a missing or malformed field renders nothing, byte-identical to no field" do
      bare = DataViz.stat_html(%{"value" => "1"})

      for dots <- [
            nil,
            "x",
            [],
            %{"on" => 1},
            %{"on" => 1, "of" => 0},
            %{"on" => 1, "of" => 51},
            %{"on" => 1, "of" => 2.5},
            %{"on" => "a", "of" => 3}
          ] do
        assert DataViz.stat_html(%{"value" => "1", "dots" => dots}) == bare,
               "dots #{inspect(dots)} rendered something"
      end
    end
  end

  describe "email" do
    test "degrades the array to glyph text plus on/of, no classes" do
      html =
        DataViz.stat_email_html(%{"value" => "2", "dots" => %{"on" => 2, "of" => 5}}, :evergreen)

      assert html =~ ">●●○○○ 2/5</div>"
      refute html =~ "class="
    end

    test "a stats item carries its dots through the shared stat renderer" do
      block = %{
        "type" => "stats",
        "items" => [%{"value" => "3", "dots" => %{"on" => 3, "of" => 4}}]
      }

      %{"kind" => "_raw", "html" => html} = Compose.compose_block(block, :email)
      assert html =~ ">●●●○ 3/4</div>"
    end

    test "no field, no line" do
      refute DataViz.stat_email_html(%{"value" => "2"}, :evergreen) =~ "●"
    end
  end
end
