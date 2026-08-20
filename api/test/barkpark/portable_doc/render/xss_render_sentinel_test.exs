defmodule Barkpark.PortableDoc.Render.XssRenderSentinelTest do
  @moduledoc """
  Permanent XSS output-encoding sentinel for the PortableDoc render tree
  (Class C of the api-read-path-security-sweep completeness critic,
  wave Paper `api-read-path-security-sweep-critic-2026-08-18`).

  Class C was proven CLEAN this wave: the whole render tree escapes at walk
  EMIT time through the single owner
  `Barkpark.PortableDoc.Render.Util.{escape_html,escape_attr,safe_url}`, and
  the #12274 fail-closed method-class slug is present. This test LOCKS that
  posture with one non-vacuous regression sentinel driven through the PUBLIC
  entrypoint `Barkpark.PortableDoc.Render.render_block/2` — no production
  change; the class is already clean. It mirrors the verifier's `xss_sentinel_v7`
  probe: a combined script + attribute/quote-breakout payload
  (`hi\"><script>alert(1)</script>`) fed through heading, paragraph, and
  callout blocks must emit the entity-escaped `&lt;script&gt;`, never a live
  `<script>` tag, and never break out of an attribute value.

  ## Make-it-fail proof (recorded RED/GREEN)

  Neutering the single owner `Util.escape_html/1` to the identity function —

      def escape_html(s) when is_binary(s), do: s

  — reds all three tests with a live `<script>` tag in the output (observed):

      3) test render_block/2 escapes a combined XSS payload in a paragraph
         expected entity-escaped &lt;script&gt; in output,
           got: <p>hi"><script>alert(1)</script></p>
         …
      3 tests, 3 failures

  Restoring the real five-character `escape_html/1` greens it (3 tests, 0
  failures). The escape owner is therefore load-bearing on this path, and this
  sentinel is non-vacuous.
  """
  # Pure, in-process render — no DB, no Phoenix boot.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  # A combined attribute-quote-breakout + script-injection payload: the leading
  # `"` + `>` would break out of an attribute value and close a tag, and the
  # `<script>…</script>` would execute, if any leaf reached markup unescaped.
  @payload ~s|hi"><script>alert(1)</script>|

  # The entity form a correct escaper must emit for the script tag.
  @escaped_open "&lt;script&gt;"
  @escaped_close "&lt;/script&gt;"

  # A live script tag must NEVER appear in rendered output.
  defp assert_no_xss(html) do
    assert html =~ @escaped_open,
           "expected entity-escaped &lt;script&gt; in output, got: #{html}"

    assert html =~ @escaped_close,
           "expected entity-escaped &lt;/script&gt; in output, got: #{html}"

    refute html =~ "<script>",
           "raw <script> tag leaked into output: #{html}"

    refute html =~ "</script>",
           "raw </script> tag leaked into output: #{html}"

    # No attribute-quote breakout: the payload's own raw quote (`hi"`) — which
    # would terminate an attribute value if the leaf reached an attribute
    # unescaped — must be entity-escaped, never survive verbatim. (A generic
    # `"><` check is wrong here: legitimate markup like `class="x"><strong>`
    # contains that sequence structurally.)
    assert html =~ "hi&quot;",
           "expected the payload quote escaped to `hi&quot;`, got: #{html}"

    refute html =~ ~s|hi"|,
           "attribute-quote breakout: raw `hi\"` survived into output: #{html}"
  end

  test "render_block/2 escapes a combined XSS payload in a heading" do
    block = %{"id" => "h", "type" => "heading", "level" => 1, "text" => @payload}
    assert_no_xss(Render.render_block(block, %{style: :article}))
  end

  test "render_block/2 escapes a combined XSS payload in a paragraph" do
    block = %{
      "id" => "p",
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => @payload}]
    }

    assert_no_xss(Render.render_block(block, %{style: :article}))
  end

  test "render_block/2 escapes a combined XSS payload in a callout title and body" do
    block = %{
      "id" => "c",
      "type" => "callout",
      "tone" => "warning",
      "title" => @payload,
      "content" => [%{"type" => "text", "value" => @payload}]
    }

    assert_no_xss(Render.render_block(block, %{style: :article}))
  end
end
