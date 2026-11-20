defmodule Barkpark.PortableDoc.Render.CalloutBodyRenderTest do
  @moduledoc """
  A callout's words, as api/assets/paper-editor/src/markdown/callout-words.js
  answers them: the article page and the email show its content, then every block of
  its body slot, in order (task-e70b11497064225b). A legacy callout (content only,
  or a body of one paragraph and no content) renders as before.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  defp text(value), do: [%{"type" => "text", "value" => value}]
  defp para(value), do: %{"type" => "paragraph", "content" => text(value)}

  # The shapes Portable Doc's importer writes under a callout: content, then a body
  # of a paragraph, a list, a code block and a nested callout.
  defp nested do
    %{
      "id" => "c1",
      "type" => "callout",
      "tone" => "info",
      "content" => text("head words"),
      "slots" => %{
        "body" => [
          para("body paragraph"),
          %{"type" => "list", "ordered" => false, "items" => [text("body item")]},
          %{"type" => "code", "lang" => "js", "value" => "body_code()"},
          %{"type" => "callout", "tone" => "warning", "content" => text("inner callout")}
        ]
      }
    }
  end

  @words ["head words", "body paragraph", "body item", "body_code()", "inner callout"]

  defp positions(html), do: Enum.map(@words, &:binary.match(html, &1))

  for style <- [:article, :email] do
    test "#{style}: a callout shows its content, then every body block, in order" do
      html = Render.render_block(nested(), %{style: unquote(style)})
      found = positions(html)

      for {word, at} <- Enum.zip(@words, found) do
        assert at != :nomatch, "#{unquote(style)} shows #{inspect(word)}: #{html}"
      end

      starts = Enum.map(found, fn {start, _} -> start end)
      assert starts == Enum.sort(starts), "#{unquote(style)} shows them in order: #{html}"
    end

    test "#{style}: a body of one paragraph and no content renders as content alone did" do
      legacy = %{
        "id" => "c2",
        "type" => "callout",
        "tone" => "info",
        "content" => text("one words")
      }

      slot = %{
        "id" => "c2",
        "type" => "callout",
        "tone" => "info",
        "slots" => %{"body" => [para("one words")]}
      }

      assert Render.render_block(slot, %{style: unquote(style)}) ==
               Render.render_block(legacy, %{style: unquote(style)})
    end
  end
end
