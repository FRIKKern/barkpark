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
      page_ids =
        Path.wildcard("lib/barkpark_web/**/*.{ex,heex}")
        |> Enum.flat_map(fn f -> Regex.scan(~r/\bid="([A-Za-z][\w:.-]*)"/, File.read!(f)) end)
        |> Enum.map(fn [_, id] -> id end)
        |> Enum.uniq()

      assert length(page_ids) > 100

      for id <- page_ids do
        out = S.sanitize(~s(<p id="#{id}">x</p>))
        assert ids(out) == [Anchors.prefix() <> id], id
      end
    end

    # The rule holds only while no page element's id is in the body's
    # namespace: the renderer's footnote ids (`fn-`) are the body's own.
    test "no page template or script writes an id in the body's namespaces" do
      hits =
        Path.wildcard("lib/barkpark_web/**/*.{ex,heex}")
        |> Kernel.++(Path.wildcard("assets/js/**/*.{js,ts}"))
        |> Enum.filter(&(File.read!(&1) =~ ~r/id=["{]?["`]?(bp-anchor-|fn-)/))

      assert hits == []
    end
  end

  describe "the ids the renderer writes, and old in-page links" do
    test "a footnote's fn- id is kept as it is, and its link with it" do
      html =
        ~s(<p>a<a href="#fn-fn1">1</a></p><ol><li id="fn-fn1" class="bp-footnote__note">n</li></ol>)

      assert S.sanitize(html) == html
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
