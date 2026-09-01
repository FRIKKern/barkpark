defmodule Barkpark.PortableDoc.Render.UtilTest do
  # Pure helpers — no DB needed.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.Util

  describe "escape_html/1" do
    test "escapes all five HTML-significant characters" do
      assert Util.escape_html("a & b < c > d \" e '") ==
               "a &amp; b &lt; c &gt; d &quot; e &#39;"
    end

    test "does not double-escape ampersands already present" do
      # & must be replaced first, so '&amp;' does not become '&amp;amp;'
      assert Util.escape_html("&amp;") == "&amp;amp;"
    end

    test "returns empty string unchanged" do
      assert Util.escape_html("") == ""
    end

    test "passes through plain text with no special chars" do
      assert Util.escape_html("hello world") == "hello world"
    end

    test "fail-soft: non-binary leaf (nil) escapes to empty string" do
      assert Util.escape_html(nil) == ""
    end
  end

  describe "escape_attr/1" do
    test "delegates to escape_html — same output" do
      input = ~s(foo < bar & "baz")
      assert Util.escape_attr(input) == Util.escape_html(input)
    end

    test "fail-soft: non-binary leaf (nil) escapes to empty string" do
      assert Util.escape_attr(nil) == ""
    end
  end

  describe "safe_url/1" do
    test "allows https URLs" do
      assert Util.safe_url("https://example.com") == "https://example.com"
    end

    test "allows http URLs" do
      assert Util.safe_url("http://example.com/path") == "http://example.com/path"
    end

    test "allows mailto URLs" do
      assert Util.safe_url("mailto:user@example.com") == "mailto:user@example.com"
    end

    test "allows tel URLs" do
      assert Util.safe_url("tel:+4700000000") == "tel:+4700000000"
    end

    test "allows relative (root) paths starting with /" do
      assert Util.safe_url("/docs/page") == "/docs/page"
    end

    test "allows in-document anchor links" do
      assert Util.safe_url("#conclusion") == "#conclusion"
    end

    test "allows bare query links" do
      assert Util.safe_url("?tab=2") == "?tab=2"
    end

    test "allows ./ relative links" do
      assert Util.safe_url("./other") == "./other"
    end

    test "allows ../ relative links" do
      assert Util.safe_url("../up") == "../up"
    end

    test "blocks bare relative words (stricter-JS-sibling parity) and returns #" do
      assert Util.safe_url("other-page") == "#"
    end

    test "blocks protocol-relative //host and returns #" do
      assert Util.safe_url("//evil.com") == "#"
    end

    test "blocks browser-normalized /\\host and returns #" do
      assert Util.safe_url("/\\evil.com") == "#"
    end

    test "still allows plain relative paths (regression)" do
      assert Util.safe_url("/docs/x") == "/docs/x"
    end

    test "blocks javascript: scheme and returns #" do
      assert Util.safe_url("javascript:alert(1)") == "#"
    end

    test "blocks javascript: with leading whitespace (tab-evasion)" do
      assert Util.safe_url("\tjavascript:alert(1)") == "#"
    end

    test "blocks unknown schemes" do
      assert Util.safe_url("ftp://example.com") == "#"
    end

    test "HTML-escapes special chars in allowed URLs" do
      assert Util.safe_url("https://example.com?a=1&b=2") ==
               "https://example.com?a=1&amp;b=2"
    end

    test "fail-soft: JSON null href (nil) degrades to #" do
      assert Util.safe_url(nil) == "#"
    end

    test "fail-soft: numeric href degrades to #" do
      assert Util.safe_url(42) == "#"
    end

    test "fail-soft: list href degrades to #" do
      assert Util.safe_url([]) == "#"
    end
  end

  # ── the tab / newline control-byte parity trio, third and last third ───────
  #
  # `safe_url/1` stripped ASCII control characters LEADING-ONLY, then tested
  # position 1 for the protocol-relative `//` or `/\` form. The WHATWG URL
  # parser deletes ASCII tab / LF / CR from ANYWHERE in a URL before it parses,
  # so `/<TAB>/evil.example/phish` was returned as an ordinary root-relative
  # path and a browser resolved it to https://evil.example/phish.
  #
  # The other two thirds landed in #14455 (`web/lib/safe-href.ts` `safeHref`
  # and `js/packages/react/src/inline.tsx` `safeUrl`), which routed this copy
  # out as a known-vulnerable sibling. `internal/pdrender/inline.go`
  # `sanitizeURL` is the REFERENCE — it already stripped control runes across
  # the whole string — so this table encodes MEASURED Go verdicts, not a
  # reading of the Go source.
  #
  # SENTINEL MAPPING, stated because the two functions refuse differently:
  # Go returns "" to drop, Elixir returns "#". Parity is over the DECISION
  # (emit vs refuse) and over the CLEANED string, never over the sentinel.
  describe "safe_url/1 control-byte parity with the Go twin (sanitizeURL)" do
    # The subject must EXIST and must still be a real guard before any parity
    # claim is made about it — a table that passes because the function
    # degraded to a constant would prove nothing. Booleans are bound rather
    # than match-asserted: ExUnit discards the message on `assert %S{} = x`.
    test "subject presence: safe_url/1 is exported and still refuses a known-bad scheme" do
      loaded? = Code.ensure_loaded?(Util)

      assert loaded?,
             "Barkpark.PortableDoc.Render.Util did not load — every case below would " <>
               "assert properties of an absent subject"

      exported? = function_exported?(Util, :safe_url, 1)

      assert exported?,
             "Util.safe_url/1 is not exported — the table below would test nothing"

      refuses_javascript? = Util.safe_url("javascript:alert(1)") == "#"

      assert refuses_javascript?,
             "safe_url/1 no longer refuses `javascript:` — the guard has degraded to a " <>
               "pass-through, so every parity case below would pass vacuously"

      allows_plain? = Util.safe_url("/docs/page") == "/docs/page"

      assert allows_plain?,
             "safe_url/1 no longer emits a plain root-relative path — it has degraded to " <>
               "refusing everything, so every REFUSE case below would pass vacuously"
    end

    # Go verdict "" (drop) => Elixir "#". Every one of these was returned
    # UNCHANGED by safe_url/1 before the fix, i.e. emitted as a live href.
    @embedded_protocol_relative [
      {"tab", "/\t/evil.example/phish"},
      {"newline", "/\n/evil.example/phish"},
      {"CR", "/\r/evil.example/phish"},
      {"CRLF", "/\r\n/evil.example/phish"},
      {"tab + backslash form", "/\t\\evil.example/phish"},
      {"newline + backslash form", "/\n\\evil.example/phish"},
      {"CR + backslash form", "/\r\\evil.example/phish"},
      {"doubled tabs before a real //", "/\t\t//evil.example/phish"},
      {"tab between the two slashes", "/\t/evil.example"},
      {"NUL", "/\0/evil.example/phish"},
      {"DEL (0x7F)", "/\x7F/evil.example/phish"},
      {"vertical tab", "/\v/evil.example/phish"},
      {"form feed", "/\f/evil.example/phish"}
    ]

    for {label, raw} <- @embedded_protocol_relative do
      test "an embedded #{label} cannot smuggle a protocol-relative host past safe_url/1" do
        raw = unquote(raw)
        out = Util.safe_url(raw)

        assert out == "#",
               "safe_url(#{inspect(raw)}) returned #{inspect(out)} instead of \"#\". " <>
                 "A browser deletes the control byte and resolves that to an OFF-SITE " <>
                 "navigation. The Go twin sanitizeURL/1 drops this input (measured)."
      end
    end

    # Go verdict "" (drop) — a control byte must not split a dangerous scheme
    # into something the allowlist regex fails to recognise as dangerous.
    @embedded_scheme [
      {"tab", "jav\tascript:alert(1)"},
      {"newline", "jav\nascript:alert(1)"},
      {"CRLF", "java\r\nscript:alert(1)"},
      {"leading tab", "\tjavascript:alert(1)"},
      {"NUL", "jav\0ascript:alert(1)"},
      {"DEL", "jav\x7Fascript:alert(1)"}
    ]

    for {label, raw} <- @embedded_scheme do
      test "an embedded #{label} cannot smuggle a dangerous scheme past safe_url/1" do
        raw = unquote(raw)
        out = Util.safe_url(raw)

        assert out == "#",
               "safe_url(#{inspect(raw)}) returned #{inspect(out)} — the byte the browser " <>
                 "deletes reassembles this into `javascript:`. Go drops it (measured)."
      end
    end

    # Go CLEANS and returns. The emitted string must carry no byte the browser
    # would delete, so the value that was CHECKED is the value that RESOLVES.
    @cleaned_through [
      {"/d/po\tst/x", "/d/post/x"},
      {"/d/po\nst/x", "/d/post/x"},
      {"/d/po\rst/x", "/d/post/x"},
      {"/d/po\r\nst/x", "/d/post/x"},
      {"https://example.com/a\nb", "https://example.com/ab"},
      {"#an\rchor", "#anchor"},
      {"?ta\tb=2", "?tab=2"},
      {"./ot\ther", "./other"},
      {"../u\np", "../up"},
      {"mailto:us\ter@example.com", "mailto:user@example.com"}
    ]

    for {raw, expected} <- @cleaned_through do
      test "safe_url/1 emits the CLEANED string for #{inspect(raw)} — checked == resolved" do
        raw = unquote(raw)
        expected = unquote(expected)
        out = Util.safe_url(raw)

        assert out == expected,
               "safe_url(#{inspect(raw)}) returned #{inspect(out)}, expected " <>
                 "#{inspect(expected)} — the Go twin returns the cleaned string (measured), " <>
                 "so a browser and this renderer must agree on what the link points at"

        refute String.match?(out, ~r/[\x00-\x1F\x7F]/),
               "safe_url(#{inspect(raw)}) returned #{inspect(out)}, which still carries a " <>
                 "byte the browser deletes — the checked string is not the resolved one"
      end
    end

    test "empty and whitespace-only inputs refuse, before and after the control strip" do
      for raw <- ["", "   ", "\t", "\n", "\r", "\r\n", "\t\n\r", " \t \n ", "\0", "\x7F"] do
        out = Util.safe_url(raw)

        assert out == "#",
               "safe_url(#{inspect(raw)}) returned #{inspect(out)} — an input that is empty " <>
                 "once the control bytes are removed must refuse, not emit"
      end
    end

    test "the strip does not widen the allowlist — combinations still refuse" do
      for raw <- [
            "f\ttp://example.com",
            "\tftp://example.com",
            "da\nta:text/html;base64,PHN2Zz4=",
            "vb\rscript:msgbox(1)",
            "ot\ther-page",
            "//evil.example",
            "/\\evil.example"
          ] do
        out = Util.safe_url(raw)

        assert out == "#",
               "safe_url(#{inspect(raw)}) returned #{inspect(out)} — removing control bytes " <>
                 "must never turn a refused form into an allowed one"
      end
    end

    test "legitimate URLs are byte-unaffected by the control-byte strip" do
      # The Go moduledoc's own claim: "well-formed allowed URLs are
      # byte-unaffected". Regression fence for the whole permitted set.
      for raw <- [
            "https://example.com",
            "http://example.com/path",
            "mailto:user@example.com",
            "tel:+4700000000",
            "/docs/page",
            "#conclusion",
            "?tab=2",
            "./other",
            "../up"
          ] do
        assert Util.safe_url(raw) == raw,
               "safe_url(#{inspect(raw)}) changed a well-formed allowed URL — the control " <>
                 "strip must be a no-op on inputs that carry no control bytes"
      end
    end

    test "fail-soft clauses are unchanged by the control strip" do
      assert Util.safe_url(nil) == "#"
      assert Util.safe_url(42) == "#"
      assert Util.safe_url([]) == "#"
    end
  end

  describe "tone_palette/1" do
    test "returns correct colours for success" do
      assert Util.tone_palette("success") == %{bg: "#e7f2ec", fg: "#1e6b52"}
    end

    test "returns correct colours for warning" do
      assert Util.tone_palette("warning") == %{bg: "#f7f0df", fg: "#8a6420"}
    end

    test "returns correct colours for danger" do
      assert Util.tone_palette("danger") == %{bg: "#f7e9e6", fg: "#a63a2e"}
    end

    test "returns correct colours for info" do
      assert Util.tone_palette("info") == %{bg: "#e9eff7", fg: "#2d5e8f"}
    end

    test "returns correct colours for neutral" do
      assert Util.tone_palette("neutral") == %{bg: "#edf0ee", fg: "#4a544f"}
    end

    test "falls back to info palette for unknown tones" do
      assert Util.tone_palette("unknown") == %{bg: "#e9eff7", fg: "#2d5e8f"}
    end

    test "falls back to info palette for nil" do
      assert Util.tone_palette(nil) == %{bg: "#e9eff7", fg: "#2d5e8f"}
    end
  end
end
