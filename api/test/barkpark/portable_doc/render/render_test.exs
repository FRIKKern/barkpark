defmodule Barkpark.PortableDoc.Render.DocumentTest do
  # Pure, in-process render — no DB, no Phoenix boot. Guards the FACADE's
  # document wrapper (`render_html/2` with `doctype: true`), the seam Stage-2
  # wave 2 slice 6 (export self-containment) added: the `:article` document
  # embeds the ONE canonical paper-surface stylesheet and tags <body>, while the
  # `:email` document stays byte-frozen inline.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Stylesheet

  # A minimal tree — one paragraph — so the assertions pin the WRAPPER bytes,
  # not the body. Body content is exercised exhaustively by the ParityFixture
  # rails (email_golden_test / article_inline_allowlist_test); here the body is
  # derived from the SAME render (doctype: false) so an unrelated body change
  # never trips these wrapper freezes.
  @trivial %{"kind" => "PdParagraph", "children" => ["hi"]}

  describe ":email document wrapper (doctype: true) — byte freeze" do
    test "wraps the body in the exact inline-only email envelope" do
      body = Render.render_html(@trivial, %{style: :email, doctype: false})

      # Byte-exact envelope. Email clients strip <style>, so this MUST stay a
      # bare inline document forever — a diff here means the :email path grew a
      # stylesheet/class it must not have. The bg literal (#f9fafb) is frozen
      # too so a palette change is caught.
      expected =
        "<!doctype html><html><head><meta charset=\"utf-8\"></head>" <>
          "<body style=\"background:#f9fafb;margin:0;padding:0;\">" <>
          body <>
          "</body></html>"

      assert Render.render_html(@trivial, %{style: :email}) == expected
    end

    test "the email document carries no <style> block and no bp-paper-surface class" do
      out = Render.render_html(@trivial, %{style: :email})
      refute String.contains?(out, "<style>")
      refute String.contains?(out, "bp-paper-surface")
    end
  end

  describe ":article document wrapper (doctype: true) — self-containment" do
    test "embeds the canonical stylesheet in <head> and tags <body> bp-paper-surface" do
      body = Render.render_html(@trivial, %{style: :article, doctype: false})

      # Byte-exact self-contained envelope: the ONE stylesheet inlined in <head>
      # (CSP-safe, no network fetch) and bp-paper-surface on <body>. The article
      # bg keeps its `var(--paper-bg-deep, …)` inline value as the no-CSS
      # fallback; frozen here too.
      expected =
        "<!doctype html><html><head><meta charset=\"utf-8\"><style>" <>
          Stylesheet.css() <>
          "</style></head>" <>
          "<body class=\"bp-paper-surface\" style=\"background:var(--paper-bg-deep, #f5f2e9);margin:0;padding:0;\">" <>
          body <>
          "</body></html>"

      assert Render.render_html(@trivial, %{style: :article}) == expected
    end

    test "the article document contains the full Stylesheet.css() bytes verbatim" do
      out = Render.render_html(@trivial, %{style: :article})
      assert String.contains?(out, "<style>" <> Stylesheet.css() <> "</style>")
      # sentinel: a paper-surface element rule from the single source is present
      assert String.contains?(out, ".bp-paper-surface h1")
    end

    test "the article document tags <body> with bp-paper-surface" do
      out = Render.render_html(@trivial, %{style: :article})
      assert String.contains?(out, ~s(<body class="bp-paper-surface" style="background:))
    end
  end

  describe "doctype: false stays a bare fragment" do
    test ":article fragment embeds NO stylesheet and NO body tag" do
      frag = Render.render_html(@trivial, %{style: :article, doctype: false})
      refute String.contains?(frag, "<style>")
      refute String.contains?(frag, "<body")
      refute String.contains?(frag, "bp-paper-surface")
    end

    test ":email fragment is unchanged (no document envelope)" do
      frag = Render.render_html(@trivial, %{style: :email, doctype: false})
      refute String.contains?(frag, "<!doctype")
      refute String.contains?(frag, "<body")
    end
  end
end
