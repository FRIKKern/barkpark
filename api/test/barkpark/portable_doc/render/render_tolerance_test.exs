defmodule Barkpark.PortableDoc.Render.RenderToleranceTest do
  # Pure, in-process render — no DB, no side-effects.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  # Papers are schemaless — any raw API/SDK/CLI mutate can persist a malformed
  # block or inline node this engine has no clause for. `render_blocks/2` feeds
  # the Papers save, the body_html cache refresh, the delta frames, the Studio
  # view, and the public reader; a single poisoned node used to 500 all of them
  # with a FunctionClauseError / Protocol.UndefinedError. The React and Go twins
  # already degrade — these tests pin the Elixir twin to the same tolerance.
  #
  # NOTE: the opts shape is `%{style: :article, embeds: %{}}` — a bare `[]` is
  # the WRONG opts shape (it is a keyword list, not the map the palette builder
  # expects) and would mask the real errors behind a BadMapError.
  @opts %{style: :article, embeds: %{}}

  # The 7 malformed-but-plausible shapes proven to crash render_blocks pre-fix,
  # each carried into the pipeline as (or inside) a top-level block map.
  @shapes [
    # 1. typeless inline map inside a paragraph's content
    {"typeless inline map", %{"type" => "paragraph", "content" => [%{"value" => "x"}]}},
    # 2. nil inline node
    {"nil inline node", %{"type" => "paragraph", "content" => [nil]}},
    # 3. boolean inline node
    {"boolean inline node", %{"type" => "paragraph", "content" => [true]}},
    # 4. nested list where an inline node was expected
    {"nested list inline", %{"type" => "paragraph", "content" => [["a"]]}},
    # 5. numeric text value
    {"numeric text value", %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => 123}]}},
    # 6. list block whose `items` is a bare string, not a list
    {"list items not a list", %{"type" => "list", "items" => "oops"}},
    # 7. heading whose `text` is a map, not a string
    {"heading text is a map", %{"type" => "heading", "level" => 2, "text" => %{"foo" => "bar"}}}
  ]

  describe "render_blocks/2 never raises on malformed shapes" do
    for {name, block} <- @shapes do
      test "degrades instead of crashing: #{name}" do
        html = Render.render_blocks([unquote(Macro.escape(block))], @opts)
        assert is_binary(html)
      end
    end

    test "a poisoned sibling does not sink its healthy neighbours" do
      blocks =
        [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "alive"}]}] ++
          Enum.map(@shapes, fn {_name, block} -> block end)

      html = Render.render_blocks(blocks, @opts)
      assert is_binary(html)
      assert html =~ "alive"
    end
  end

  describe "render_blocks/2 preserves recoverable text" do
    test "nested-list [\"a\"] keeps its text" do
      block = %{"type" => "paragraph", "content" => [["a"]]}
      html = Render.render_blocks([block], @opts)
      assert html =~ ">a<"
    end

    test "numeric text value 123 survives as its string" do
      block = %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => 123}]}
      html = Render.render_blocks([block], @opts)
      assert html =~ "123"
    end

    test "list block with a bare-string `items` renders the string" do
      block = %{"type" => "list", "items" => "oops"}
      html = Render.render_blocks([block], @opts)
      assert html =~ "oops"
    end
  end

  describe "render_blocks/2 fuzz — no generated junk raises" do
    test "50 random junk block/inline shapes all degrade without raising" do
      for _ <- 1..50 do
        block = gen_block()
        html = Render.render_blocks([block], @opts)
        assert is_binary(html)
      end
    end
  end

  # ── junk generators ─────────────────────────────────────────────────────────
  # Top-level blocks are always maps (the documented shape render_block/2 guards
  # on); the junk lives in their fields (content / items / text / children) and
  # in inline nodes — the realistic threat model for a schemaless paper.

  defp gen_scalar do
    Enum.random([nil, true, false, 0, 7, 3.14, -1, "str", :atom, %{}, %{"a" => 1}, ["x"], [nil]])
  end

  defp gen_inline do
    Enum.random([
      nil,
      true,
      false,
      42,
      1.5,
      "text",
      :atom,
      %{},
      %{"value" => "x"},
      %{"type" => "text", "value" => gen_scalar()},
      %{"type" => "strong", "children" => [gen_scalar()]},
      ["a"],
      [nil],
      [["nested"]]
    ])
  end

  defp gen_content do
    Enum.random([
      Enum.map(0..Enum.random(0..3), fn _ -> gen_inline() end),
      gen_scalar(),
      "loose string content",
      nil
    ])
  end

  defp gen_block do
    Enum.random([
      %{"type" => "paragraph", "content" => gen_content()},
      %{"type" => "heading", "level" => Enum.random([1, 2, 3, 99, "2", nil]), "text" => gen_scalar()},
      %{"type" => "list", "items" => Enum.random([gen_scalar(), gen_content()])},
      %{"type" => "callout", "content" => gen_content(), "tone" => Enum.random(["info", nil, 5])},
      %{"type" => Enum.random(["future-widget", "text", "list", "unknownblock"]), "content" => gen_content()},
      %{"value" => gen_scalar()},
      %{"type" => "section", "title" => "Sec", "blocks" => [gen_scalar(), %{"nope" => true}, gen_block_leaf()]}
    ])
  end

  # A non-recursive block for section children (avoids unbounded nesting).
  defp gen_block_leaf do
    Enum.random([
      %{"type" => "paragraph", "content" => gen_content()},
      %{"type" => "heading", "text" => gen_scalar()},
      gen_scalar()
    ])
  end
end
