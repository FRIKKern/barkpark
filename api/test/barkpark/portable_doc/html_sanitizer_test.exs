defmodule Barkpark.PortableDoc.HtmlSanitizerTest do
  @moduledoc """
  Unit proof for the strict body_html scrubber (the STORE-time layer of the
  stored-XSS fix). Pure — no DB/app boot — so it runs under `--no-start`.

  Each attack vector must be neutralised (no executable script/handler/scheme
  survives); every legitimate producer construct must pass through untouched so
  the scrub cannot damage real Markdown/pdrender-rendered papers.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.HtmlSanitizer, as: S

  @exec ~r/<script|<style|<iframe|<svg|<object|<embed|<form|<meta|<noscript|<template|on[a-z]+\s*=|javascript:|vbscript:/i

  describe "sanitize/1 neutralises XSS vectors" do
    for {name, payload} <- [
          {"inline script", "<p>hi</p><script>alert(document.cookie)</script>"},
          {"img onerror", "<img src=x onerror=\"steal()\">"},
          {"uppercase SCRIPT", "<SCRIPT>alert(1)</SCRIPT>"},
          {"tag-splitting", "<scr<script>ipt>alert(1)</script>"},
          {"svg onload", "<svg onload=alert(1)></svg>"},
          {"iframe javascript:", "<iframe src=\"javascript:alert(1)\"></iframe>"},
          {"anchor javascript:", "<a href=\"javascript:alert(1)\">x</a>"},
          {"anchor mixed-case scheme", "<a href=\"JaVaScRiPt:alert(1)\">x</a>"},
          {"bare onclick", "<div onclick=alert(1)>x</div>"},
          {"style url(javascript:)", "<style>a{background:url(javascript:alert(1))}</style>"},
          {"onmouseover attr", "<p ONMOUSEOVER=\"alert(1)\">hover</p>"},
          {"data:text/html anchor", "<a href=\"data:text/html,x\">x</a>"},
          {"object data", "<object data=\"javascript:alert(1)\"></object>"},
          {"form action", "<form action=\"javascript:alert(1)\"><input></form>"},
          {"embed", "<embed src=\"evil.swf\">"},
          {"meta refresh", "<meta http-equiv=\"refresh\" content=\"0\">"},
          {"IE conditional comment", "<!--[if IE]><script>alert(1)</script><![endif]-->"},
          {"noscript wrapper", "<noscript><script>alert(1)</script></noscript>"},
          {"template wrapper", "<template><img src=x onerror=alert(1)></template>"},
          {"vbscript href", "<a href=\"vbscript:msgbox(1)\">x</a>"}
        ] do
      test "neutralises #{name}" do
        refute Regex.match?(@exec, S.sanitize(unquote(payload)))
      end
    end
  end

  describe "sanitize/1 preserves legitimate producer HTML" do
    for {name, html} <- [
          {"headings and links",
           "<h1>Title</h1><p>Some <strong>bold</strong> and <a href=\"https://x.com\">link</a>.</p>"},
          {"code and table",
           "<pre><code>x = 1</code></pre><table><tr><td>a</td></tr></table>"},
          {"remote image", "<img src=\"https://cdn/x.png\" alt=\"pic\">"},
          {"list", "<ul><li>one</li><li>two</li></ul>"},
          {"inline data:image", "<img src=\"data:image/png;base64,AAAA\" alt=\"i\">"}
        ] do
      test "keeps #{name} byte-identical" do
        assert S.sanitize(unquote(html)) == unquote(html)
      end
    end
  end

  describe "sanitize/1 passthrough for non-binary" do
    test "nil and non-strings are returned unchanged" do
      assert S.sanitize(nil) == nil
      assert S.sanitize(%{"a" => 1}) == %{"a" => 1}
    end
  end
end
