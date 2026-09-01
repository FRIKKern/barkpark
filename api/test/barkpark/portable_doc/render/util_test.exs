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

  # An author writes a link mark `/<TAB>/evil.example/phish`. The renderer used
  # to see a root-relative path whose first segment happened to be a tab, so it
  # emitted the href verbatim — but the WHATWG URL parser deletes tab/LF/CR from
  # ANYWHERE in a URL before parsing, so the reader's browser resolved it as the
  # protocol-relative `//evil.example/phish` and navigated off-site. Measured
  # against `new URL(raw, base)`: of `\x00`-`\x20`, exactly `\x09`/`\x0A`/`\x0D`
  # collapse that way; every other C0 byte percent-encodes and stays an ordinary
  # path segment. Twins: `js/packages/react/src/inline.tsx` (`safeUrl`),
  # `web/lib/safe-href.ts`, `internal/pdrender/inline.go` (`sanitizeURL`).
  describe "safe_url/1 — URL-parser-stripped control characters" do
    test "blocks a tab between the slashes of a protocol-relative URL" do
      assert Util.safe_url("/\t/evil.example/phish") == "#"
    end

    test "blocks an LF between the slashes of a protocol-relative URL" do
      assert Util.safe_url("/\n/evil.example") == "#"
    end

    test "blocks a CR between the slashes of a protocol-relative URL" do
      assert Util.safe_url("/\r/evil.example") == "#"
    end

    test "blocks the backslash form with an interior control character" do
      assert Util.safe_url("/\t\\evil.example") == "#"
      assert Util.safe_url("/\n\\evil.example") == "#"
    end

    test "blocks repeated control characters between the slashes" do
      assert Util.safe_url("/\t\r\n/evil.example") == "#"
    end

    test "blocks a control character splitting a denied scheme" do
      assert Util.safe_url("java\tscript:alert(1)") == "#"
      assert Util.safe_url("javascript\n:alert(1)") == "#"
    end

    # The guard must not degenerate into "reject everything": these are the
    # subject-present assertions. A legitimate href still survives intact.
    test "still returns a legitimate root-relative path intact" do
      assert Util.safe_url("/blog/post") == "/blog/post"
    end

    test "still returns a legitimate https URL intact" do
      assert Util.safe_url("https://good.example/x") == "https://good.example/x"
    end

    test "still returns legitimate in-document and relative forms intact" do
      assert Util.safe_url("#anchor") == "#anchor"
      assert Util.safe_url("?tab=2") == "?tab=2"
      assert Util.safe_url("./rel") == "./rel"
      assert Util.safe_url("../up") == "../up"
      assert Util.safe_url("mailto:user@example.com") == "mailto:user@example.com"
    end

    # C0 bytes the URL parser does NOT delete stay ordinary path characters, so
    # a leading-only strip is still the right rule for them — `/\x01/x` is a real
    # path segment and must survive, and the pre-existing leading strip must keep
    # catching `\x0Bjavascript:`.
    test "a non-stripped C0 byte stays an ordinary path segment" do
      assert Util.safe_url("/\x01/ok.example") == "/\x01/ok.example"
    end

    test "still strips leading non-tab control bytes before the scheme test" do
      assert Util.safe_url("\x0Bjavascript:alert(1)") == "#"
      assert Util.safe_url("\x00javascript:alert(1)") == "#"
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
