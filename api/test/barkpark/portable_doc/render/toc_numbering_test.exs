defmodule Barkpark.PortableDoc.Render.TocNumberingTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Stylesheet

  @items [
    %{"text" => "Start", "level" => 2, "anchor" => "start"},
    %{"text" => "Details", "level" => 3, "anchor" => "details"}
  ]

  test "numbered=false emits a semantic bulleted list without authored number prefixes" do
    block = %{"type" => "toc", "items" => @items, "depth" => 2, "numbered" => false}

    for style <- [:article, :email] do
      html = Render.render_block(block, %{style: style})

      assert html =~ ~s(<ul class="bp-toc__list bp-toc__list--bulleted">)
      refute html =~ "1. Start"
      refute html =~ "1.1. Details"
      assert html =~ ">Start</a>"
      assert html =~ ">Details</a>"
    end
  end

  test "numbered=true keeps hierarchical labels and suppresses native ordered markers" do
    block = %{"type" => "toc", "items" => @items, "depth" => 2, "numbered" => true}

    article = Render.render_block(block, %{style: :article})
    email = Render.render_block(block, %{style: :email})

    assert article =~ ~s(<ol class="bp-toc__list">)
    assert article =~ ">1. Start</a>"
    assert article =~ ">1.1. Details</a>"

    assert Stylesheet.css() =~
             ".bp-toc__list { margin: 0; padding-left: 1.3rem; list-style: none; }"

    # The surface sets markers directly on `ol li`/`ul li`; a parent-only
    # override cannot beat that declaration through inheritance.
    assert Stylesheet.css() =~
             ".bp-paper-surface .bp-toc__item { margin: 3px 0; list-style: none; }"

    assert Stylesheet.css() =~
             ".bp-paper-surface .bp-toc__list--bulleted > .bp-toc__item { list-style: disc; }"

    assert email =~ ~s(<ol class="bp-toc__list" style="list-style:none;">)
    assert email =~ ">1. Start</a>"
    assert email =~ ">1.1. Details</a>"
  end
end
