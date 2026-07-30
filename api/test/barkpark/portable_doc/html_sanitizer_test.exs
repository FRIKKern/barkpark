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

  describe "sanitize/1 neutralises HTML-entity / whitespace scheme-obfuscation" do
    # A browser decodes attribute-value entities and strips tab/newline in the
    # scheme BEFORE URL parsing, so a raw-byte scheme test is not enough. Each
    # vector must leave no decodable `javascript:`/`vbscript:`/`data:text/html`.
    # These FAILED against the first sanitizer (the vacuous-green miss) and are
    # the regression proof for the entity-decode hardening.
    @decoded_exec ~r/(?:javascript|vbscript):|data:text\/html/i

    for {name, payload} <- [
          {"decimal-entity colon", "<a href=\"javascript&#58;alert(1)\">x</a>"},
          {"hex-entity colon", "<a href=\"javascript&#x3a;alert(1)\">x</a>"},
          {"named-entity colon", "<a href=\"javascript&colon;alert(1)\">x</a>"},
          {"entity-encoded scheme letter", "<a href=\"&#106;avascript:alert(1)\">x</a>"},
          {"tab-in-scheme entity", "<a href=\"jav&#9;ascript:alert(1)\">x</a>"},
          {"no-semicolon numeric entity", "<a href=\"javascript&#58alert(1)\">x</a>"},
          {"data:text/html entity colon", "<a href=\"data&#58;text/html,payload\">y</a>"}
        ] do
      test "neutralises #{name}" do
        refute Regex.match?(@decoded_exec, browser_decode(S.sanitize(unquote(payload))))
      end
    end
  end

  # Mirror the browser's entity/whitespace decode of an attribute value so the
  # assertion judges what actually executes, not the stored bytes.
  defp browser_decode(html) do
    html
    |> String.replace(~r/&#x([0-9a-f]+);?/i, fn m ->
      [_, h] = Regex.run(~r/&#x([0-9a-f]+);?/i, m)
      <<String.to_integer(h, 16)::utf8>>
    end)
    |> String.replace(~r/&#([0-9]+);?/, fn m ->
      [_, d] = Regex.run(~r/&#([0-9]+);?/, m)
      <<String.to_integer(d)::utf8>>
    end)
    |> String.replace("&colon;", ":")
    |> String.replace(~r/[\x00-\x20]/, "")
  end

  describe "sanitize/1 preserves legitimate producer HTML" do
    for {name, html} <- [
          {"headings and links",
           "<h1>Title</h1><p>Some <strong>bold</strong> and <a href=\"https://x.com\">link</a>.</p>"},
          {"code and table", "<pre><code>x = 1</code></pre><table><tr><td>a</td></tr></table>"},
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
