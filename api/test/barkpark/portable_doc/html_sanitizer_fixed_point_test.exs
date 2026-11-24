defmodule Barkpark.PortableDoc.HtmlSanitizerFixedPointTest do
  @moduledoc """
  `HtmlSanitizer.sanitize/2` is a fixed point, and its own serialiser writes
  what the parser reads back (#28404 review at bd7e6fd7dc, B5 and B6).

  B5: unwrapping `aside`, `center`, `main` or `marquee` moved an `<li>`, `<dd>`
  or `<dt>` under a `div` where the parser never puts one. Serialised as it
  stood, the browser's parse closed the page's own `div`. B6:
  `LazyHTML.to_html/1` wrote `<s><br></br></s>`, and each save doubled the
  line breaks.

  The corpus is the review's: the 81 hand-picked fragments and 4,000 random
  nestings over kept, unwrapped and void elements, with the review's seed.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Barkpark.PortableDoc.HtmlSanitizer, as: S
  alias Barkpark.PortableDoc.HtmlSanitizer.Elements

  # The reader's box and the /email box, with the page around each.
  defp reader(out) do
    LazyHTML.from_document(
      ~s(<!doctype html><html><body><div id="shell"><main id="m"><div id="wrap">) <>
        ~s(<article id="pb" style="contain: paint">) <>
        out <>
        ~s(</article><section id="after">r</section></div></main><footer id="ft">f</footer></div></body></html>)
    )
  end

  defp email(out) do
    LazyHTML.from_document(
      ~s(<!doctype html><html><body><div id="mail"><div id="box" style="contain: paint">) <>
        out <> ~s(</div><p id="sig">sig</p></div></body></html>)
    )
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  # Every element the body holds sits in the box, or is the page's own.
  defp contained?(out) do
    r = reader(out)
    e = email(out)

    count(r, "body *") == count(r, "#pb *") + 6 and
      count(r, "body > #shell > #m > #wrap > #pb") == 1 and
      count(r, "#wrap > #after") == 1 and count(r, "#shell > #ft") == 1 and
      count(e, "body *") == count(e, "#box *") + 3 and
      count(e, "body > #mail > #box") == 1 and count(e, "#mail > #sig") == 1
  end

  defp stable?(out), do: S.sanitize(out) == out

  describe "B6: a void element is written without an end tag" do
    test "<s>one<br>two</s> keeps exactly one br, save after save" do
      outs = Enum.scan(1..3, ~s(<s>one<br>two</s>), fn _, x -> S.sanitize(x) end)

      for out <- outs do
        assert out == ~s(<s>one<br>two</s>)
        assert count(LazyHTML.from_fragment(out), "br") == 1
      end
    end

    test "every void element under s, at any depth, is written once" do
      for void <- ~w(br wbr hr img input), html = "<s><em><#{void}></em></s>" do
        out = S.sanitize(html)
        refute out =~ "</#{void}>", "#{void}: #{out}"
        assert count(LazyHTML.from_fragment(S.sanitize(out)), void) == 1
      end
    end

    test "a pre that starts with a blank line keeps it over 3 passes" do
      outs = Enum.scan(1..3, "<pre>\n\nx</pre>", fn _, x -> S.sanitize(x) end)
      assert Enum.uniq(outs) == ["<pre>\n\nx</pre>"]

      assert [{"pre", [], ["\nx"]}] =
               List.last(outs) |> LazyHTML.from_fragment() |> LazyHTML.to_tree()
    end
  end

  describe "B5: an unwrap never leaves a tree the parser would not build" do
    for {name, html} <- [
          {"li under aside",
           ~s(<ul><li>a<div><aside><li>b</li></aside></div></li></ul><p id="bp-anchor-esc">x</p>)},
          {"dd under marquee",
           ~s(<dl><dt>a<div><marquee><dd>b</dd></marquee></div></dt></dl><p id="bp-anchor-esc">x</p>)},
          {"dt under main",
           ~s(<dl><dt>a<div><main><dt>b</dt></main></div></dt></dl><p id="bp-anchor-esc">x</p>)},
          {"li under center",
           ~s(<ul><li>a<div><center><li>b</li></center></div></li></ul><p id="bp-anchor-esc">x</p>)},
          {"li under marquee",
           ~s(<ul><li>a<div><marquee><li>b</li></marquee></div>c</li></ul><p id="bp-anchor-esc">x</p>)},
          {"li with no list", ~s(<li><div><aside><li>b</aside></div><p id="bp-anchor-esc">x</p>)}
        ] do
      test "#{name}: stable, and no </div> closes outside the box" do
        out = S.sanitize(unquote(html))
        assert stable?(out), out
        assert contained?(out), out
        assert count(reader(out), "#pb #bp-anchor-esc") == 1
      end
    end

    test "control: one pass of the old kind does escape the box" do
      refute contained?(~s(<ul><li>a<div><li>b</li></div></li></ul><p id="bp-anchor-esc">x</p>))
    end

    test "a body that does not settle is served as its text, and the log names the id only" do
      html = ~s(<ul><li>a<div><aside><li>b &lt;secret&gt;</li></aside></div></li></ul>)

      log =
        capture_log(fn ->
          assert S.sanitize(html, max_passes: 1, id: "paper-7") == "<p>a b &lt;secret&gt;</p>"
        end)

      assert log =~ ~s(id="paper-7")
      refute log =~ "secret"
    end
  end

  describe "the review's corpus" do
    @handpicked [
      # B3 variants
      ~s|<select><meta http-equiv="refresh" content="0;url=https://e.example/"></select>|,
      ~s|<datalist><img src=x onerror=alert(1)></datalist>|,
      ~s|<option><img src=x onerror=alert(1)></option>|,
      ~s|<selectedcontent><img src=x onerror=alert(1)></selectedcontent>|,
      ~s|<table><tr><td><select><meta http-equiv="refresh" content="0;url=https://e.example/"></select></td></tr></table>|,
      ~s|<table><select><meta http-equiv="refresh" content="0;url=https://e.example/"></select></table>|,
      ~s|<svg><foreignObject><select><meta http-equiv="refresh" content="0"></select></foreignObject></svg>|,
      ~s|<math><mtext><select><meta http-equiv="refresh" content="0"></select></mtext></math>|,
      ~s|<p>x<select>|,
      ~s|<p>x</p><select><button><img src=x onerror=alert(1)></button>|,
      # stray end tags that close the reader's own containers
      ~s|<p>a</p></article><p style="color:#ff0000">outside</p>|,
      ~s|<p>a</p></div><p>outside the email box</p>|,
      ~s|<p>a</p></main></article></div><p>outside</p>|,
      ~s|<p>a</p></section><p>after section</p>|,
      ~s|<p>a</p></body></html><p>after body</p>|,
      ~s|<section><p>a</p></section></section><p>x</p>|,
      # differential set
      ~s|<table><tr><td>a</td></tr>stray<p>p</p><a href="https://e.example/">l</a></table>|,
      ~s|<table><caption>c<td>x</td></caption></table>|,
      ~s|<table><tfoot><tr><td>f</td></tr></tfoot><tr><td>b</td></tr></table>|,
      ~s|<table><col><colgroup><col></colgroup><tr><td>x</table>|,
      ~s|<button><button>x</button></button>|,
      ~s|<p>a<p>b<div>c</div>|,
      ~s|<ul><li>a<li>b<ul><li>c</ul></ul>|,
      ~s|<dl><dt>a<dd>b<dt>c</dl>|,
      ~s|<p>a<nav>n</nav>b</p>|,
      ~s|<p>a<header>h</header>b</p>|,
      ~s|<p>a<section>s</section></p>|,
      ~s|<input name="doc[title]" value="pwned"><button type=submit name="x" value="y">b</button><label for="title">l</label><fieldset><legend>l</legend><input type=checkbox checked></fieldset>|,
      ~s|<details open><summary>s</summary><p>d</p></details>|,
      ~s|<video src="https://e.example/v.mp4" autoplay muted loop playsinline poster="https://e.example/p.png"><track kind="captions" src="https://e.example/t.vtt" default></video>|,
      ~s|<img src="https://e.example/a.png" srcset="https://e.example/b.png 2x, javascript:alert(1) 3x" sizes="100vw">|,
      ~s|<a href="https://e.example/"><div><a href="https://f.example/">n</a></div></a>|,
      ~s|<h1><h2>x</h2></h1>|,
      ~s|<pre>\nx</pre>|,
      ~s|<p><hr></p>|,
      ~s|<b><table><tr><td>x</td></tr></table>y</b>|,
      ~s|<figure><figcaption>c</figcaption><table><tr><td>x</td></tr></table></figure>|,
      ~s|<table><tr><td><table><tr><td>x</td></tr></table>|,
      ~s|<summary>x</summary><details>y|,
      ~s|<button><p>a</p><div>b</div></button>|,
      ~s|<label><input><label>x</label></label>|,
      ~s|<a href="https://e.example/"><button>x</button></a>|,
      ~s|<table><input type=hidden name=a value=1><input name=b value=2><tr><td>x</table>|,
      ~s|<table><tr><input type=hidden name="doc[title]" value="pw"></tr></table>|,
      ~s|<p>x<table><tr><td>y</table>z</p>|,
      ~s|<span><div>x</div></span>|,
      ~s|<em><p>x</em>y</p>|,
      ~s|<q><p>x</q></p>|,
      ~s|<time datetime="2020"><time>x</time></time>|,
      ~s|<p>x</p></p></br>|,
      ~s|<video><source src="https://e.example/v.mp4"><img src=x></video>|,
      ~s|<tr><td>orphan</td></tr>|,
      ~s|<td>orphan</td>|,
      ~s|<caption>orphan</caption>|,
      ~s|<col><tbody><tr><td>x|,
      ~s|<header><header>x</header></header>|,
      ~s|<nav><p>x<nav>y</nav></p></nav>|,
      # r5: unwrap builds trees the parser never builds
      ~s|<ul><li>a<div><marquee><li>b</li></marquee></div>c</li></ul><p style="color:#ff0000">after</p>|,
      ~s|<dl><dt>a<div><marquee><dd>b</dd></marquee></div></dt></dl><p style="color:#ff0000">after</p>|,
      ~s|<ul><li>a<div><aside><li>b</li></aside></div></li></ul><p>after</p>|,
      ~s|<ul><li>a<div><center><li>b</li></center></div></li></ul><p>after</p>|,
      ~s|<dl><dt>a<div><main><dt>b</dt></main></div></dt></dl><p>after</p>|,
      ~s|<p>x<marquee><div>y</div></marquee>z</p>|,
      ~s|<a href="https://e.example/1">x<marquee><a href="https://e.example/2">y</a></marquee></a>|,
      ~s|<h1>x<marquee><h2>y</h2></marquee></h1>|,
      ~s|<button>x<marquee><button>y</button></marquee></button>|,
      ~s|<table><tr><td>x<marquee><td>y</td></marquee></td></tr></table>|,
      ~s|<div><div><marquee><li>a<div>b</div></li></marquee></div></div>|,
      ~s|<li><div><aside><li>b</aside></div>|,
      # escaping
      ~s|<p title="a&quot;b&lt;c&gt;d&amp;e</script>]]>">t &lt;img src=x onerror=alert(1)&gt; &amp;lt; ]]&gt; &lt;/script&gt;</p>|,
      ~s|<a href="https://e.example/?a=1&amp;b=2&quot;onmouseover=alert(1)">l</a>|,
      ~s|<p title='"><img src=x onerror=alert(1)>'>q</p>|,
      ~s|<p title="&lt;/p&gt;&lt;img src=x onerror=alert(1)&gt;">q</p>|,
      ~s|<pre>\n\nx</pre>|,
      ~s|<pre>\nx</pre>|,
      ~s|<p>&nbsp;&#160;&#xa0;</p>|,
      ~s|<p>a<!-- c --><![CDATA[ <img src=x onerror=alert(1)> ]]>b</p>|,
      ~s|<marquee><style>p{color:red}</style><p>x</p></marquee>|,
      ~s|<xyz-a><noscript><p title="</noscript><img src=x onerror=alert(1)>"></noscript></xyz-a>|,
      ~s|<frameset><p>x</p>|,
      ~s|<p>\u0000x</p>|
    ]

    test "the 81 hand-picked and 4,000 random fragments: each output is stable and contained" do
      kept = Elements.kept() -- ~w(br wbr hr img input col track)

      unw =
        ~w(marquee aside center address main article menu footer search hgroup dir xyz-a font big nobr)

      voids = ~w(br hr img input col track wbr)
      :rand.seed(:exsss, {1, 2, 3})

      gen = fn gen, depth ->
        if depth == 0 do
          "t"
        else
          Enum.map_join(1..Enum.random(1..3), "", fn _ ->
            case :rand.uniform(10) do
              1 ->
                "</" <> Enum.random(kept ++ unw) <> ">"

              2 ->
                "<" <> Enum.random(voids) <> ">"

              3 ->
                "<" <> Enum.random(kept ++ unw) <> ">" <> gen.(gen, depth - 1)

              4 ->
                t = Enum.random(unw)
                "<#{t}>" <> gen.(gen, depth - 1) <> "</#{t}>"

              _ ->
                t = Enum.random(kept)
                "<#{t}>" <> gen.(gen, depth - 1) <> "</#{t}>"
            end
          end)
        end
      end

      corpus = @handpicked ++ for(_ <- 1..4000, do: gen.(gen, 4))
      assert length(corpus) == 4081

      bad =
        for html <- corpus,
            out = S.sanitize(html),
            not (stable?(out) and contained?(out)),
            do: {html, out}

      assert bad == [],
             "#{length(bad)} unstable or escaping, first: #{inspect(Enum.take(bad, 3))}"
    end
  end
end
