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

  describe "tone_palette/1" do
    test "returns correct colours for success" do
      assert Util.tone_palette("success") == %{bg: "#ecfdf5", fg: "#047857"}
    end

    test "returns correct colours for warning" do
      assert Util.tone_palette("warning") == %{bg: "#fffbeb", fg: "#92400e"}
    end

    test "returns correct colours for danger" do
      assert Util.tone_palette("danger") == %{bg: "#fef2f2", fg: "#b91c1c"}
    end

    test "returns correct colours for info" do
      assert Util.tone_palette("info") == %{bg: "#eff6ff", fg: "#1d4ed8"}
    end

    test "returns correct colours for neutral" do
      assert Util.tone_palette("neutral") == %{bg: "#f3f4f6", fg: "#374151"}
    end

    test "falls back to info palette for unknown tones" do
      assert Util.tone_palette("unknown") == %{bg: "#eff6ff", fg: "#1d4ed8"}
    end

    test "falls back to info palette for nil" do
      assert Util.tone_palette(nil) == %{bg: "#eff6ff", fg: "#1d4ed8"}
    end
  end
end
