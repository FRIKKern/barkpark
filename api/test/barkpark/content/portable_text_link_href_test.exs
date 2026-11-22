defmodule Barkpark.Content.PortableTextLinkHrefTest do
  @moduledoc """
  task-e1584dc1f1516991: a link's `javascript:` address was live in the rich
  text editor's first paint, and after a push (`PortableText.to_html/1`): the
  same HTML. Only the reader's allowlist (`LinkHref`) is drawn as a link; a
  refused address is drawn as the link's words, and its stored def rides
  back unchanged. An address the editor posts is linked only when allowed.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.LinkHref
  alias Barkpark.Content.PortableText

  @refused [
    "javascript:alert(1)",
    "JavaScript:alert(1)",
    "  javascript:alert(1)",
    "\tjavascript:alert(1)",
    "jav\tascript:alert(1)",
    "java\nscript:alert(1)",
    "\u0001javascript:alert(1)",
    "jav&#x09;ascript:alert(1)",
    "&#106;avascript:alert(1)",
    "javascript&colon;alert(1)",
    "vbscript:msgbox(1)",
    "VBScript:msgbox(1)",
    "data:text/html,<script>alert(1)</script>",
    " DATA:text/html;base64,PHNjcmlwdD4=",
    "//evil.example/x",
    "/\\evil.example/x"
  ]

  @allowed [
    "https://example.com/a?b=1#c",
    "http://example.com",
    "mailto:a@example.com",
    "tel:+4712345678",
    "/docs/a",
    "./a",
    "../a",
    "?q=1",
    "#",
    "#part",
    "#internal:doc-1"
  ]

  defp link_block(def) do
    [
      %{
        "_type" => "block",
        "_key" => "b1",
        "style" => "normal",
        "markDefs" => [Map.put(def, "_key", "m1")],
        "children" => [
          %{"_type" => "span", "_key" => "s1", "text" => "go", "marks" => ["m1"]}
        ]
      }
    ]
  end

  defp lower_decoded(html),
    do: html |> String.downcase() |> String.replace(~r/&amp;|&#x?[0-9a-f]+;|[\s\x00-\x1f]/, "")

  for href <- @refused do
    @href href

    test "a link to #{inspect(href)} is drawn as its words, no address" do
      for def <- [
            %{"_type" => "link", "href" => @href},
            %{"_type" => "linkAnnotation", "url" => @href},
            %{"_type" => "linkAnnotation", "linkType" => "dam", "damFileUrl" => @href}
          ] do
        html = PortableText.to_html(link_block(def))
        refute html =~ "href", "#{inspect(def)} drew #{html}"
        refute lower_decoded(html) =~ ~r/javascript|vbscript|data:/
        assert html =~ ~s(<span data-pt-def="m1">go</span>)
      end
    end

    test "the editor posting a link to #{inspect(href)} stores the words, unlinked" do
      html = ~s(<p>x <a href="#{Plug.HTML.html_escape(@href)}">go</a></p>)
      [block] = PortableText.from_html(html, [])
      assert block["markDefs"] == []
      assert Enum.all?(block["children"], &(&1["marks"] == []))
      assert Enum.map_join(block["children"], & &1["text"]) == "x go"
    end
  end

  test "entity-encoded forms the editor posts are read as a browser reads them, and refused" do
    for raw <- ["jav&#x09;ascript:alert(1)", "&#106;avascript:alert(1)", "jav&#10;ascript:x"] do
      [block] = PortableText.from_html(~s(<p><a href="#{raw}">go</a></p>), [])
      assert block["markDefs"] == [], raw
    end
  end

  for href <- @allowed do
    @href href

    test "a link to #{inspect(href)} is drawn and read back as before" do
      blocks = link_block(%{"_type" => "link", "href" => @href})
      html = PortableText.to_html(blocks)
      assert html =~ ~s(href="#{Plug.HTML.html_escape(@href)}")
      assert PortableText.from_html(html, blocks) == blocks
    end
  end

  test "a stored refused link survives an edit of other words in its block unchanged" do
    blocks = link_block(%{"_type" => "link", "href" => "javascript:alert(1)"})
    html = PortableText.to_html(blocks) |> String.replace("<p>", "<p>new ")
    [block] = PortableText.from_html(html, blocks)
    assert block["markDefs"] == hd(blocks)["markDefs"]
    assert Enum.any?(block["children"], &(&1["marks"] == ["m1"] and &1["text"] == "go"))
  end

  test "LinkHref is the reader's allowlist" do
    for h <- @allowed, do: assert(LinkHref.allowed?(h), h)
    for h <- @refused, do: refute(LinkHref.allowed?(h), h)
    refute LinkHref.allowed?(nil)
    refute LinkHref.allowed?("bare-word")
  end
end
