defmodule BarkparkWeb.ShareMetaTest do
  @moduledoc """
  The preview-contract emission layer (pc-w2): `BarkparkWeb.ShareMeta.head/1`
  turns a preview manifest into the og/twitter/JSON-LD `<head>` block, and
  `manifest/4` resolves a document's manifest (write-time → read-time → degraded
  core). Pure — no DB, no LiveView; the reader wiring is proven in the
  bulldocs / sheets reader suites.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.ShareMeta

  defp head(assigns), do: render_component(&ShareMeta.head/1, assigns)

  defp count(html, needle),
    do: html |> String.split(needle) |> length() |> Kernel.-(1)

  # A rich paper manifest as pc-w1 would stamp it (relative url + image.url).
  defp paper_manifest do
    %{
      "title" => "Preview Contract",
      "type" => "paper",
      "url" => "/papers/preview-contract",
      "description" => "One preview manifest per document, emitted outward.",
      "image" => %{
        "url" => "/media/renditions/og/abc.jpg",
        "width" => 1200,
        "height" => 630,
        "alt" => "The preview contract card",
        "type" => "image/jpeg"
      },
      "published_time" => "2026-07-09T10:00:00Z",
      "authors" => ["Kalle", %{"name" => "Fable"}],
      "tags" => ["opengraph", "branding"],
      "section" => "Engineering"
    }
  end

  describe "core og tags" do
    test "emits the full og block with property= from a paper manifest" do
      html = head(preview: paper_manifest())
      base = BarkparkWeb.Endpoint.url()

      assert html =~ ~s(<meta property="og:site_name" content="Barkpark")
      assert html =~ ~s(<meta property="og:title" content="Preview Contract")
      assert html =~ ~s(<meta property="og:type" content="article")

      # D3 — the relative url is absolutized against the public host, exactly once.
      assert html =~ ~s(<meta property="og:url" content="#{base}/papers/preview-contract")
      assert count(html, ~s(property="og:url")) == 1

      assert html =~
               ~s(<meta property="og:description" content="One preview manifest per document, emitted outward.")
    end

    test "image object carries all 5 fields, absolutized (D7)" do
      html = head(preview: paper_manifest())
      base = BarkparkWeb.Endpoint.url()

      assert html =~ ~s(<meta property="og:image" content="#{base}/media/renditions/og/abc.jpg")
      assert html =~ ~s(<meta property="og:image:width" content="1200")
      assert html =~ ~s(<meta property="og:image:height" content="630")
      assert html =~ ~s(<meta property="og:image:alt" content="The preview contract card")
      assert html =~ ~s(<meta property="og:image:type" content="image/jpeg")
    end

    test "an already-absolute image url passes through untouched" do
      manifest = put_in(paper_manifest()["image"]["url"], "https://cdn.example.com/x.png")
      html = head(preview: manifest)

      assert html =~ ~s(<meta property="og:image" content="https://cdn.example.com/x.png")
    end
  end

  describe "twitter tags" do
    test "emits summary_large_image + title/description/image with name=" do
      html = head(preview: paper_manifest())
      base = BarkparkWeb.Endpoint.url()

      assert html =~ ~s(<meta name="twitter:card" content="summary_large_image")
      assert html =~ ~s(<meta name="twitter:title" content="Preview Contract")

      assert html =~
               ~s(<meta name="twitter:description" content="One preview manifest per document, emitted outward.")

      assert html =~ ~s(<meta name="twitter:image" content="#{base}/media/renditions/og/abc.jpg")
    end

    test "twitter uses name=, never property=" do
      html = head(preview: paper_manifest())
      refute html =~ ~s(property="twitter:)
      refute html =~ ~s(name="og:)
    end
  end

  describe "article extensions + JSON-LD (paper/post only)" do
    test "emits article:* extensions for a paper" do
      html = head(preview: paper_manifest())

      assert html =~ ~s(<meta property="article:published_time" content="2026-07-09T10:00:00Z")
      assert html =~ ~s(<meta property="article:author" content="Kalle")
      assert html =~ ~s(<meta property="article:author" content="Fable")
      assert html =~ ~s(<meta property="article:tag" content="opengraph")
      assert html =~ ~s(<meta property="article:tag" content="branding")
      assert html =~ ~s(<meta property="article:section" content="Engineering")
    end

    test "emits a JSON-LD Article for a paper" do
      html = head(preview: paper_manifest())

      assert html =~ ~s(<script type="application/ld+json">)
      assert html =~ ~s("@type":"Article")
      assert html =~ ~s("headline":"Preview Contract")
      # Jason's html_safe escaping renders `/` as `\/` (so `</script>` can't
      # break out); the url is still the absolutized canonical path.
      assert html =~ ~s("url":"http:\\/\\/) or html =~ ~s("url":"https:\\/\\/)
      assert html =~ "preview-contract"
      assert html =~ ~s("datePublished":"2026-07-09T10:00:00Z")
      assert html =~ ~s("@type":"Person")
    end

    test "reads extensions from a nested \"extensions\" sub-map too" do
      manifest =
        %{
          "title" => "Nested",
          "type" => "paper",
          "url" => "/papers/nested",
          "extensions" => %{"tags" => ["nested-tag"], "section" => "Docs"}
        }

      html = head(preview: manifest)
      assert html =~ ~s(<meta property="article:tag" content="nested-tag")
      assert html =~ ~s(<meta property="article:section" content="Docs")
    end
  end

  describe "weighted-tag manifest self-defense (D18)" do
    # A blockless paper whose caller-supplied content["preview"] is persisted
    # verbatim can carry raw weighted-tag objects `%{"tag"=>_, "strength"=>_}`
    # in `tags`. Before this guard, `head/1` interpolated the Map into the
    # `content={tag}` attr and raised Protocol.UndefinedError, crashing
    # /papers/:slug. ShareMeta now flattens the object to its tag name itself.
    test "renders a raw weighted-tag manifest as flat article:tag, no crash" do
      manifest = %{
        "title" => "Weighted",
        "type" => "paper",
        "url" => "/papers/weighted",
        "tags" => [%{"tag" => "elixir", "strength" => 90}, "flat"]
      }

      html = head(preview: manifest)

      # The weighted object flattens to its tag name; the flat string is kept.
      assert html =~ ~s(<meta property="article:tag" content="elixir")
      assert html =~ ~s(<meta property="article:tag" content="flat")
      assert count(html, ~s(property="article:tag")) == 2
      # The numeric strength never leaks into the emitted head.
      refute html =~ "strength"
      refute html =~ ~s(content="90")
    end

    test "drops a malformed tag map (no string tag), leaving no empty article:tag" do
      manifest = %{
        "title" => "Malformed",
        "type" => "paper",
        "url" => "/papers/malformed",
        "tags" => [%{"strength" => 50}, %{"tag" => "kept", "strength" => 40}]
      }

      html = head(preview: manifest)

      # Only the well-formed weighted object survives; the tag-less map is
      # dropped (nil → rejected) rather than rendered as an empty content="".
      assert html =~ ~s(<meta property="article:tag" content="kept")
      assert count(html, ~s(property="article:tag")) == 1
      refute html =~ ~s(<meta property="article:tag" content=""/>)
    end
  end

  describe "type mapping (D8) — non-article" do
    test "a sheet maps to og:type=website, no JSON-LD, no article:* tags" do
      manifest = %{"title" => "Q3 Budget", "type" => "sheet", "url" => "/sheets/q3-budget"}
      html = head(preview: manifest)

      assert html =~ ~s(<meta property="og:type" content="website")
      refute html =~ "application/ld+json"
      refute html =~ ~s(property="article:)
    end
  end

  describe "branded default card (D5) + nil-safety (D12)" do
    test "a nil image emits the branded default card at 1200x630" do
      manifest = %{"title" => "No Image", "type" => "paper", "url" => "/papers/no-image"}
      html = head(preview: manifest)
      base = BarkparkWeb.Endpoint.url()

      assert html =~ ~s(<meta property="og:image" content="#{base}/images/og-default.jpg")
      assert html =~ ~s(<meta property="og:image:width" content="1200")
      assert html =~ ~s(<meta property="og:image:height" content="630")
      # A nil alt falls back to the title.
      assert html =~ ~s(<meta property="og:image:alt" content="No Image")
    end

    test "a nil manifest renders site-default meta seeded from the page title" do
      html = head(preview: nil, page_title: "Some Doc")
      base = BarkparkWeb.Endpoint.url()

      assert html =~ ~s(<meta property="og:title" content="Some Doc")
      assert html =~ ~s(<meta property="og:type" content="website")
      # og:url falls back to the site root when the manifest carries none.
      assert html =~ ~s(<meta property="og:url" content="#{base}")
      assert html =~ ~s(<meta property="og:image" content="#{base}/images/og-default.jpg")
      refute html =~ "application/ld+json"
      refute html =~ ~s(property="og:description")
    end

    test "a fully absent manifest AND title falls back to the Barkpark site name" do
      html = head([])
      assert html =~ ~s(<meta property="og:title" content="Barkpark")
    end
  end

  describe "JSON-LD injection safety" do
    test "a title containing </script> cannot break out of the script tag" do
      manifest = %{
        "title" => "Evil </script><script>alert(1)</script>",
        "type" => "paper",
        "url" => "/papers/evil"
      }

      html = head(preview: manifest)

      # The raw closing tag never appears inside the JSON-LD payload — Jason's
      # html_safe escaping turns `<`/`>` into \\u escapes.
      refute html =~ "</script><script>alert(1)"
      assert html =~ ~s(<script type="application/ld+json">)
      # exactly one opening + one closing script tag (the JSON-LD block).
      assert count(html, "<script") == 1
      assert count(html, "</script>") == 1
    end
  end

  describe "manifest/4 resolution" do
    test "prefers the write-time content[\"preview\"] manifest" do
      content = %{"preview" => %{"title" => "Stamped", "type" => "paper", "url" => "/papers/x"}}
      assert %{"title" => "Stamped"} = ShareMeta.manifest(content, "/papers/x", "paper")
    end

    test "ignores a legacy scalar preview instead of crashing the Paper reader" do
      content = %{
        "title" => "Survey wave",
        "description" => "Reader-visible evidence",
        "preview" => "legacy preview prose"
      }

      manifest = ShareMeta.manifest(content, "/papers/survey-wave", "paper")

      assert is_map(manifest)
      assert manifest["title"] == "Survey wave"
      assert manifest["url"] == "/papers/survey-wave"
    end

    test "falls back to a degraded core manifest when no preview + no projector" do
      # Barkpark.Preview is unmerged (pc-w1) → read-time returns nil → degraded.
      content = %{"title" => "Legacy Paper", "excerpt" => "A short lead."}
      m = ShareMeta.manifest(content, "/papers/legacy", "paper")

      assert m["title"] == "Legacy Paper"
      assert m["type"] == "paper"
      assert m["url"] == "/papers/legacy"
      assert m["description"] == "A short lead."
      assert m["image"] == nil
    end

    test "uses the fallback title when content has none" do
      m = ShareMeta.manifest(%{}, "/sheets/s1", "sheet", "Sheet One")
      assert m["title"] == "Sheet One"
      assert m["type"] == "sheet"
    end

    test "a non-map content still yields a valid degraded manifest" do
      m = ShareMeta.manifest(nil, "/papers/none", "paper", "Fallback")
      assert m["title"] == "Fallback"
      assert m["url"] == "/papers/none"
    end
  end
end
