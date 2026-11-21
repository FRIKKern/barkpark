defmodule Barkpark.PortableDoc.Render.CalloutBodyRenderTest do
  @moduledoc """
  A callout's words, as api/assets/paper-editor/src/markdown/callout-words.js
  answers them: the article page and the email show its content (or its text when it
  has no content), then every block of its body slot, in order, each body block drawn
  by the same function that draws a top-level block (task-e70b11497064225b). A callout
  with no body renders byte-identical to main.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp para(value), do: %{"type" => "paragraph", "content" => text(value)}

  # A body of every shape the reader draws as a block: a paragraph, a list, code, a
  # quote with its cite, a table and a callout holding its own body.
  defp body do
    [
      para("body paragraph"),
      %{"type" => "list", "ordered" => false, "items" => [text("body item")]},
      %{"type" => "code", "lang" => "js", "value" => "body_code()"},
      %{"type" => "blockquote", "content" => text("body quote"), "cite" => "Quote Author"},
      %{
        "type" => "table",
        "head" => [text("Head cell")],
        "rows" => [[text("Row cell")]]
      },
      %{
        "type" => "callout",
        "tone" => "warning",
        "title" => "Inner title",
        "content" => text("inner callout"),
        "slots" => %{"body" => [para("inner body")]}
      }
    ]
  end

  defp nested do
    %{
      "id" => "c1",
      "type" => "callout",
      "tone" => "info",
      "content" => text("head words"),
      "slots" => %{"body" => body()}
    }
  end

  @words [
    "head words",
    "body paragraph",
    "body item",
    "body_code()",
    "body quote",
    "Quote Author",
    "Head cell",
    "Row cell",
    "Inner title",
    "inner callout",
    "inner body"
  ]

  defp count(html, word), do: length(:binary.matches(html, word))

  # What main 9818122b23 rendered for callouts with no body, captured by rendering
  # each block on main's compose.ex, slots.ex and render.ex: these keep their bytes.
  @main_bytes [
    {"content only", :article,
     %{
       "content" => [%{"type" => "text", "value" => "Content words"}],
       "id" => "b1",
       "tone" => "info",
       "type" => "callout"
     }, "<div class=\"bp-callout bp-callout--info\"><span>Content words</span></div>"},
    {"content only", :email,
     %{
       "content" => [%{"type" => "text", "value" => "Content words"}],
       "id" => "b1",
       "tone" => "info",
       "type" => "callout"
     },
     "<div style=\"border:1px solid #e2e6e5;border-radius:12px;padding:18px 22px 20px;color:#15211d;margin:20px 0\"><span>Content words</span></div>"},
    {"content with a title and a mark", :article,
     %{
       "content" => [
         %{"type" => "text", "value" => "Be "},
         %{"children" => [%{"type" => "text", "value" => "careful"}], "type" => "strong"}
       ],
       "id" => "b2",
       "title" => "Heads up",
       "tone" => "warning",
       "type" => "callout"
     },
     "<div class=\"bp-callout bp-callout--warning\"><strong>Heads up</strong> <span>Be <span style=\"font-weight:bold\">careful</span></span></div>"},
    {"content with a title and a mark", :email,
     %{
       "content" => [
         %{"type" => "text", "value" => "Be "},
         %{"children" => [%{"type" => "text", "value" => "careful"}], "type" => "strong"}
       ],
       "id" => "b2",
       "title" => "Heads up",
       "tone" => "warning",
       "type" => "callout"
     },
     "<div style=\"border:1px solid #e2e6e5;border-radius:12px;padding:18px 22px 20px;color:#15211d;margin:20px 0\"><div style=\"font-size:11px;font-weight:600;letter-spacing:0.09em;text-transform:uppercase;color:#55635e;margin:0 0 6px\"><span style=\"color:#8a6420\">&#9679;</span>&nbsp; Heads up</div><span>Be <span style=\"font-weight:bold\">careful</span></span></div>"},
    {"text only", :article,
     %{"id" => "b3", "text" => "Text words", "tone" => "note", "type" => "callout"},
     "<div class=\"bp-callout bp-callout--info\"><span>Text words</span></div>"},
    {"text only", :email,
     %{"id" => "b3", "text" => "Text words", "tone" => "note", "type" => "callout"},
     "<div style=\"border:1px solid #e2e6e5;border-radius:12px;padding:18px 22px 20px;color:#15211d;margin:20px 0\"><span>Text words</span></div>"},
    {"empty content, text shows", :article,
     %{
       "content" => [],
       "id" => "b4",
       "text" => "Text words",
       "tone" => "danger",
       "type" => "callout"
     }, "<div class=\"bp-callout bp-callout--danger\"><span>Text words</span></div>"},
    {"empty content, text shows", :email,
     %{
       "content" => [],
       "id" => "b4",
       "text" => "Text words",
       "tone" => "danger",
       "type" => "callout"
     },
     "<div style=\"border:1px solid #e2e6e5;border-radius:12px;padding:18px 22px 20px;color:#15211d;margin:20px 0\"><span>Text words</span></div>"},
    {"collapsible", :article,
     %{
       "collapsed" => true,
       "collapsible" => true,
       "content" => [%{"type" => "text", "value" => "Folded words"}],
       "id" => "b5",
       "title" => "Fold",
       "tone" => "info",
       "type" => "callout"
     },
     "<details class=\"bp-callout bp-callout--info\"><summary class=\"bp-callout__summary\">Fold</summary><div class=\"bp-callout__body\"><span>Folded words</span></div></details>"},
    {"collapsible", :email,
     %{
       "collapsed" => true,
       "collapsible" => true,
       "content" => [%{"type" => "text", "value" => "Folded words"}],
       "id" => "b5",
       "title" => "Fold",
       "tone" => "info",
       "type" => "callout"
     },
     "<div style=\"border:1px solid #e2e6e5;border-radius:12px;padding:18px 22px 20px;color:#15211d;margin:20px 0\"><div style=\"font-size:11px;font-weight:600;letter-spacing:0.09em;text-transform:uppercase;color:#55635e;margin:0 0 6px\"><span style=\"color:#2d5e8f\">&#9679;</span>&nbsp; Fold</div><span>Folded words</span></div>"},
    {"nothing", :article, %{"id" => "b6", "tone" => "info", "type" => "callout"},
     "<div class=\"bp-callout bp-callout--info\"><span></span></div>"},
    {"nothing", :email, %{"id" => "b6", "tone" => "info", "type" => "callout"},
     "<div style=\"border:1px solid #e2e6e5;border-radius:12px;padding:18px 22px 20px;color:#15211d;margin:20px 0\"><span></span></div>"}
  ]

  for {name, style, block, html} <- @main_bytes do
    test "#{style}: a callout with no body keeps main's bytes: #{name}" do
      assert Render.render_block(unquote(Macro.escape(block)), %{style: unquote(style)}) ==
               unquote(html)
    end
  end

  for style <- [:article, :email] do
    test "#{style}: a callout shows its content, then every body block, in order" do
      html = Render.render_block(nested(), %{style: unquote(style)})
      found = Enum.map(@words, &:binary.match(html, &1))

      for {word, at} <- Enum.zip(@words, found) do
        assert at != :nomatch, "#{unquote(style)} shows #{inspect(word)}: #{html}"
      end

      starts = Enum.map(found, fn {start, _} -> start end)
      assert starts == Enum.sort(starts), "#{unquote(style)} shows them in order: #{html}"

      for word <- @words do
        assert count(html, word) == 1, "#{unquote(style)} shows #{inspect(word)} once: #{html}"
      end
    end

    test "#{style}: each body block is drawn as the same block at the top level" do
      html = Render.render_block(nested(), %{style: unquote(style)})

      for block <- body() do
        alone = Render.render_block(block, %{style: unquote(style)})

        assert String.contains?(html, alone),
               "#{unquote(style)} draws the #{block["type"]} as it does at the top level: #{alone} in #{html}"
      end
    end

    test "#{style}: a callout with a body and no content shows each body word once, as a block" do
      only_body = %{
        "id" => "c2",
        "type" => "callout",
        "tone" => "info",
        "slots" => %{"body" => [para("one words"), para("two words")]}
      }

      html = Render.render_block(only_body, %{style: unquote(style)})
      assert count(html, "one words") == 1, html
      assert count(html, "two words") == 1, html
      {one, _} = :binary.match(html, "one words")
      {two, _} = :binary.match(html, "two words")
      assert one < two, html

      for words <- ["one words", "two words"] do
        assert String.contains?(html, Render.render_block(para(words), %{style: unquote(style)})),
               "#{unquote(style)} draws #{inspect(words)} as a paragraph block: #{html}"
      end
    end

    test "#{style}: a callout with content only shows its words once" do
      own = %{"id" => "c3", "type" => "callout", "tone" => "note", "content" => text("own words")}
      assert count(Render.render_block(own, %{style: unquote(style)}), "own words") == 1
    end
  end
end
