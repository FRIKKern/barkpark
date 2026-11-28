defmodule Barkpark.Content.PortableTextParseMemoTest do
  @moduledoc """
  task-6a5c3e075299d4bc. A save parses each distinct posted rich text once
  (`PortableText.ParseMemo`). Inside the memo every read gives what a fresh
  parse gives: for every body kind, for duplicate and pasted blocks, and
  never another field's or another save's parse of the same HTML.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.PortableText
  alias Barkpark.Content.PortableText.ParseMemo

  defp span(k, t, marks \\ []),
    do: %{"_type" => "span", "_key" => k, "text" => t, "marks" => marks}

  defp para(k, children, extra \\ %{}),
    do:
      Map.merge(
        %{
          "_type" => "block",
          "_key" => k,
          "style" => "normal",
          "markDefs" => [],
          "children" => children
        },
        extra
      )

  defp item(k, t, list \\ "bullet", level \\ 1),
    do: para(k, [span(k <> "s", t)], %{"listItem" => list, "level" => level})

  defp linked(k, t, href) do
    para(k, [span(k <> "s", t, ["d" <> k])], %{
      "markDefs" => [%{"_type" => "link", "_key" => "d" <> k, "href" => href}]
    })
  end

  defp chip(k), do: %{"_type" => "chip", "_key" => k, "v" => "a&b<\"c'>"}

  # Stored bodies of every kind the editor draws.
  defp bodies do
    [
      plain: [para("p1", [span("s1", "one")]), para("p2", [span("s2", "two")])],
      marks: [para("m1", [span("a", "bold ", ["strong"]), span("b", "and em", ["em"])])],
      link: [linked("l1", "a link", "https://example.com/?a=1&b=2")],
      lists: [item("i1", "first"), item("i2", "nested", "bullet", 2), item("i3", "num", "number")],
      heading: [
        para("h1", [span("hs", "Title")], %{"style" => "h2"}),
        para("h2", [span("x", "body")])
      ],
      inline: [para("o1", [span("os", "before "), chip("c1"), span("ot", " after")])],
      custom: [
        para("c0", [span("cs", "text")]),
        %{"_type" => "mediaModule", "_key" => "mm", "src" => "x"}
      ],
      entities: [para("e1", [span("es", "a & b < c > d \" e ' f g")])],
      empty: [para("z1", [span("zs", "")]), para("z2", [span("zt", "x")])],
      duplicate: [para("d1", [span("ds", "same")]), para("d2", [span("dt", "same")])]
    ]
  end

  # Posts of each body: as drawn, typed in, a block pasted above, moved,
  # removed, and a new block.
  defp posts(stored) do
    html = PortableText.to_html(stored)
    blocks = Enum.map(stored, &PortableText.to_html([&1]))

    [
      html,
      html <> "<p>new A</p>",
      String.replace(html, "</p>", " A</p>", global: false),
      hd(blocks) <> html,
      Enum.join(Enum.reverse(blocks)),
      Enum.join(tl(blocks)),
      ""
    ]
  end

  defp field(annotations),
    do: %{
      "name" => "rt",
      "type" => "richText",
      "blocks" => %{
        "annotations" =>
          Enum.map(annotations, &%{"name" => &1, "fields" => [%{"name" => "href"}]})
      }
    }

  defp optss do
    [
      [],
      [field: %{"name" => "rt", "type" => "richText"}],
      [field: field(["link"])],
      [field: field(["linkAnnotation"])],
      [defs: %{"dn" => %{"_type" => "link", "_key" => "dn", "href" => "https://n.example"}}],
      [objects: %{"cn" => %{"_type" => "chip", "_key" => "cn", "v" => 2}}]
    ]
  end

  defp cases do
    for {kind, stored} <- bodies(),
        html <- posts(stored),
        base <- [stored, [], [para("other", [span("os", "other")])]],
        opts <- optss(),
        do: {kind, html, base, opts}
  end

  test "inside the memo each read is what a fresh parse gives, in any order" do
    cases = cases()
    fresh = Enum.map(cases, fn {_k, h, b, o} -> PortableText.from_html(h, b, o) end)

    memo =
      ParseMemo.around(fn ->
        forward = Enum.map(cases, fn {_k, h, b, o} -> PortableText.from_html(h, b, o) end)

        backward =
          cases
          |> Enum.reverse()
          |> Enum.map(fn {_k, h, b, o} -> PortableText.from_html(h, b, o) end)

        {forward, Enum.reverse(backward)}
      end)

    bad =
      for {{kind, html, _b, opts}, want, got} <- Enum.zip([cases, fresh, elem(memo, 0)]),
          got != want,
          do: {kind, html, opts}

    assert bad == [], "the memo gave another parse: #{inspect(Enum.take(bad, 3))}"
    assert elem(memo, 1) == fresh
  end

  test "one HTML in fields of other annotations: each its own link type" do
    html = ~s(<p><a href="https://example.com">x</a></p>)
    open = %{"name" => "rt", "type" => "richText"}

    types =
      ParseMemo.around(fn ->
        for f <- [field(["linkAnnotation"]), open, field(["link"]), field(["linkAnnotation"])] do
          [%{"markDefs" => [%{"_type" => type}]}] = PortableText.from_html(html, [], field: f)
          type
        end
      end)

    assert types == ["linkAnnotation", "link", "link", "linkAnnotation"]
  end

  test "one HTML against two stored values: each keeps its own keys" do
    html = "<p>same</p>"

    keys =
      ParseMemo.around(fn ->
        for k <- ["k1", "k2", "k1"] do
          [%{"_key" => key}] = PortableText.from_html(html, [para(k, [span("s" <> k, "same")])])
          key
        end
      end)

    assert keys == ["k1", "k2", "k1"]
  end

  test "nothing outlives a save: the next save parses again" do
    me = self()
    parse = fn -> send(me, :parsed) && [:blocks] end

    assert ParseMemo.around(fn ->
             {ParseMemo.parsed(:in, parse), ParseMemo.parsed(:in, parse)}
           end) ==
             {[:blocks], [:blocks]}

    assert_received :parsed
    refute_received :parsed

    ParseMemo.around(fn -> ParseMemo.parsed(:in, parse) end)
    assert_received :parsed

    # Outside a save no read is kept.
    ParseMemo.parsed(:in, parse)
    ParseMemo.parsed(:in, parse)
    assert_received :parsed
    assert_received :parsed
  end

  test "a nested save shares the outer one; a raise ends it" do
    me = self()
    parse = fn -> send(me, :parsed) && [:blocks] end

    ParseMemo.around(fn ->
      ParseMemo.parsed(:in, parse)
      ParseMemo.around(fn -> ParseMemo.parsed(:in, parse) end)
      ParseMemo.parsed(:in, parse)
    end)

    assert_received :parsed
    refute_received :parsed

    assert_raise RuntimeError, fn ->
      ParseMemo.around(fn ->
        ParseMemo.parsed(:in, parse)
        raise "boom"
      end)
    end

    assert_received :parsed
    ParseMemo.around(fn -> ParseMemo.parsed(:in, parse) end)
    assert_received :parsed
  end
end
