defmodule Barkpark.PortableDoc.HtmlSanitizerAnchorsTest do
  # task-52d612bdb8ff6cb3: a stored id or name in a legacy body could take a
  # page element's place (`getElementById` returns the first match; an id, or
  # an img's name, is also a `window` / `document` property).
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.HtmlSanitizer, as: S
  alias Barkpark.PortableDoc.HtmlSanitizer.Anchors

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp ids(html), do: html |> doc() |> LazyHTML.query("[id]") |> LazyHTML.attribute("id")
  defp names(html), do: html |> doc() |> LazyHTML.query("[name]") |> LazyHTML.attribute("name")
  defp hrefs(html), do: html |> doc() |> LazyHTML.query("a[href]") |> LazyHTML.attribute("href")

  # The reader's own page around the body, as `bulldocs_live` draws it.
  defp reader(body),
    do: LazyHTML.from_document(~s(<main><article id="paper-body">#{body}</article></main>))

  describe "a stored id never takes a page element's place" do
    test "paper-body, editor-form and desk-panes come out without that id" do
      for id <- ~w(paper-body editor-form desk-panes) do
        out = S.sanitize(~s(<div id="#{id}">x</div>))
        refute id in ids(out), out
        assert S.sanitize(out) == out
      end

      page = reader(S.sanitize(~s(<div id="paper-body">x</div>)))
      assert page |> LazyHTML.query("#paper-body") |> Enum.count() == 1
      assert page |> LazyHTML.query("#paper-body") |> LazyHTML.tag() == ["article"]
    end

    # A predicate over every page: each literal id the web layer's templates
    # and modules write, stored in a body, comes out as another id.
    test "no id a page template writes survives in a stored body" do
      page_ids = page_ids()
      assert length(page_ids) > 100

      for id <- page_ids do
        out = S.sanitize(~s(<p id="#{id}">x</p>))
        assert ids(out) == [Anchors.prefix() <> id], id
      end
    end

    # The rule holds only while no page or editor element's id is in the
    # body's namespace. The scan reads every place a page id is written:
    # templates and modules, the static scripts, and the editor's source,
    # where an id is set from JS (`li.id = `fn-${n.id}``, task-9c0ae5a9351d89cf).
    test "no page template, script or editor source writes an id in the body's namespace" do
      sources = page_sources()
      assert hits(sources, Anchors.prefix()) == []

      # Control: the same patterns find the editor canvas's footnote ids,
      # which are set from JS (`li.id = `fn-${n.id}``), not written in markup.
      assert "assets/paper-editor/src/canvas/island-node.js" in hits(sources, "fn-")
    end

    test "a footnote id the editor canvas writes, stored in a body, comes out as another id" do
      canvas = File.read!("assets/paper-editor/src/canvas/island-node.js")
      assert canvas =~ "li.id = `fn-${n.id}`"

      out =
        S.sanitize(
          ~s(<ol class="bp-footnote"><li id="fn-fn1" class="bp-footnote__note">n</li></ol>)
        )

      assert ids(out) == ["bp-anchor-fn-fn1"]
    end
  end

  defp page_ids do
    Path.wildcard("lib/barkpark_web/**/*.{ex,heex}")
    |> Enum.flat_map(fn f -> Regex.scan(~r/\bid="([A-Za-z][\w:.-]*)"/, File.read!(f)) end)
    |> Enum.map(fn [_, id] -> id end)
    |> Enum.uniq()
  end

  # An id written with `prefix`: in markup (`id="…"`, `id={"…"}`), from JS
  # (`.id = "…"`, `setAttribute("id", "…")`), or as a keyword (`id: "…"`).
  defp hits(sources, prefix) do
    p = Regex.escape(prefix)

    re =
      ~r/(\bid=["{]?["'`]?|\.id\s*=\s*["'`]|setAttribute\(\s*["']id["']\s*,\s*["'`]|\bid:\s*["'`])#{p}/

    Enum.filter(sources, &(File.read!(&1) =~ re))
  end

  defp page_sources do
    Path.wildcard("lib/barkpark_web/**/*.{ex,heex}") ++
      Path.wildcard("assets/js/**/*.{js,ts}") ++
      (Path.wildcard("assets/paper-editor/src/**/*.{js,mjs,ts}")
       |> Enum.reject(&(&1 =~ ~r/test\./))) ++
      (Path.wildcard("priv/static/assets/*.js") -- ["priv/static/assets/bp-paper-anchor.js"])
  end

  describe "the ids the renderer writes, and old in-page links" do
    test "a footnote's fn- id moves, and a link to it moves with it" do
      out =
        S.sanitize(
          ~s(<p>a<a href="#fn-fn1">1</a></p><ol><li id="fn-fn1" class="bp-footnote__note">n</li></ol>)
        )

      assert ids(out) == ["bp-anchor-fn-fn1"]
      assert hrefs(out) == ["#bp-anchor-fn-fn1"]
      assert S.sanitize(out) == out
    end

    test "a heading anchor keeps an id, and an old #anchor link still lands on it" do
      out = S.sanitize(~s(<p><a href="#intro">Intro</a></p><h2 id="intro">Intro</h2>))
      assert ids(out) == ["bp-anchor-intro"]
      assert hrefs(out) == ["#bp-anchor-intro"]
      assert reader(out) |> LazyHTML.query("h2#bp-anchor-intro") |> Enum.count() == 1
      assert S.sanitize(out) == out
    end

    test "an old a name anchor moves with its links; a link to no stored id is left" do
      out = S.sanitize(~s(<a name="old"></a><a href="#old">go</a> <a href="#elsewhere">x</a>))
      assert names(out) == ["bp-anchor-old"]
      assert hrefs(out) == ["#bp-anchor-old", "#elsewhere"]
      assert S.sanitize(out) == out
    end

    test "an id already in the namespace is not moved twice" do
      html = ~s(<h2 id="bp-anchor-intro">I</h2><a href="#bp-anchor-intro">i</a>)
      assert S.sanitize(html) == html
    end
  end

  describe "a same-page link follows a moved id" do
    @body ~s(<h2 id="intro">I</h2><h2 id="a b">S</h2>)

    defp linked(href, opts \\ []),
      do: (@body <> ~s(<a href="#{href}">x</a>)) |> S.sanitize(opts) |> hrefs()

    test "a query, ASCII whitespace at either end, or a percent-encoded fragment" do
      assert linked("?x=1#intro") == ["?x=1#bp-anchor-intro"]
      assert linked("  #intro\t") == ["#bp-anchor-intro"]
      assert linked("#a%20b") == ["#bp-anchor-a%20b"]
    end

    test "the Paper's own path, plain or scoped, with or without a query" do
      for opts <- [[id: "doc-1"], [id: "drafts.doc-1"]] do
        assert linked("/papers/doc-1#intro", opts) == ["/papers/doc-1#bp-anchor-intro"]

        assert linked("/w/ws/p/pr/papers/doc-1?y#intro", opts) == [
                 "/w/ws/p/pr/papers/doc-1?y#bp-anchor-intro"
               ]
      end
    end

    test "another page, another host, or another case is left as written" do
      opts = [id: "doc-1"]
      assert linked("/papers/doc-12#intro", opts) == ["/papers/doc-12#intro"]
      assert linked("/papers/other#intro", opts) == ["/papers/other#intro"]

      assert linked("https://e.example/papers/doc-1#intro", opts) == [
               "https://e.example/papers/doc-1#intro"
             ]

      assert linked("/papers/doc-1#intro") == ["/papers/doc-1#intro"]
      assert linked("#INTRO") == ["#INTRO"]
      assert linked("#%E0%A4%A") == ["#%E0%A4%A"]
    end

    test "a protocol-relative or backslash host is another host" do
      opts = [id: "doc-1"]

      # A browser reads `/\host` as `//host` and drops a tab or newline inside a URL.
      for href <- [
            "//e.example/papers/doc-1#intro",
            "/\\e.example/papers/doc-1#intro",
            " //e.example/papers/doc-1?y#intro",
            "/\t/e.example/papers/doc-1#intro",
            "/\n\\e.example/papers/doc-1#intro"
          ] do
        assert linked(href, opts) == [href], "#{inspect(href)} was treated as this Paper"
      end
    end

    test "each is a fixed point" do
      for href <- ["?x#intro", " #intro", "#a%20b", "/papers/doc-1#intro"] do
        out = S.sanitize(@body <> ~s(<a href="#{href}">x</a>), id: "doc-1")
        assert S.sanitize(out, id: "doc-1") == out
      end
    end
  end

  describe "an id reference never names a page element" do
    defp attr_of(html, sel, name),
      do: html |> doc() |> LazyHTML.query(sel) |> LazyHTML.attribute(name)

    test "a stored label for=editor-form does not point at editor-form" do
      out = S.sanitize(~s(<label for="editor-form">L</label>))
      assert attr_of(out, "label", "for") == ["bp-anchor-editor-form"]
    end

    test "headers and every aria id reference move token by token" do
      out =
        S.sanitize(
          ~s(<table><tr><th id="h1">H</th><td headers="h1  paper-body">c</td></tr></table>) <>
            ~s(<p aria-labelledby="paper-body x" aria-describedby="d" aria-controls="desk-panes" ) <>
            ~s(aria-owns="o" aria-activedescendant="a" aria-details="t" aria-errormessage="e" aria-flowto="f g">p</p>)
        )

      assert attr_of(out, "td", "headers") == ["bp-anchor-h1 bp-anchor-paper-body"]

      for {name, want} <- [
            {"aria-labelledby", "bp-anchor-paper-body bp-anchor-x"},
            {"aria-describedby", "bp-anchor-d"},
            {"aria-controls", "bp-anchor-desk-panes"},
            {"aria-owns", "bp-anchor-o"},
            {"aria-activedescendant", "bp-anchor-a"},
            {"aria-details", "bp-anchor-t"},
            {"aria-errormessage", "bp-anchor-e"},
            {"aria-flowto", "bp-anchor-f bp-anchor-g"}
          ] do
        assert attr_of(out, "p", name) == [want], name
      end

      assert S.sanitize(out) == out
    end

    test "a body's own label still names its own control" do
      out = S.sanitize(~s(<label for="q">Q</label><input id="q" name="q1">))
      assert attr_of(out, "label", "for") == attr_of(out, "input", "id")
    end

    test "every literal page id, named by a stored for, is not named" do
      for id <- page_ids() do
        out = S.sanitize(~s(<label for="#{id}">x</label>))
        assert attr_of(out, "label", "for") == [Anchors.prefix() <> id], id
      end
    end

    test "an aria attribute that is not an id reference is left as written" do
      out = S.sanitize(~s(<p aria-label="paper-body" aria-hidden="true">p</p>))
      assert attr_of(out, "p", "aria-label") == ["paper-body"]
    end
  end

  describe "name" do
    test "an img's or form's name is dropped; a questionnaire field's is kept" do
      out = S.sanitize(~s(<p><img name="querySelector" src="x"><input name="q1" value="a"></p>))
      assert names(out) == ["q1"]
    end

    test "an empty id is dropped" do
      assert S.sanitize(~s(<p id="">x</p>)) == "<p>x</p>"
    end
  end
end
