defmodule Barkpark.PortableDoc.Render.PaperLinksTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.Compose

  @block %{
    "id" => "related",
    "type" => "paper-links",
    "title" => "Keep exploring",
    "description" => "The useful next stops, chosen for this release.",
    "refs" => [
      %{"slug" => "daily-2026-08-24", "reason" => "See the full day behind this summary."},
      "weekly-2026-w34"
    ]
  }

  test "pure and email rendering degrades to authored, usable Paper links" do
    html = Render.render_block(@block, %{style: :email})

    assert html =~ "Keep exploring"
    assert html =~ "The useful next stops"
    assert html =~ ~s(href="/papers/daily-2026-08-24")
    assert html =~ "See the full day behind this summary."
    assert html =~ ~s(href="/papers/weekly-2026-w34")
    assert html =~ "weekly-2026-w34"
    refute html =~ "Unsupported block"
  end

  test "article rendering prefers injected live metadata and keeps authored reasons" do
    html =
      Render.render_block(@block, %{
        style: :article,
        paper_links: %{
          "daily-2026-08-24" => %{
            title: "Chronicle headlines now name specific subjects",
            description: "This description stays behind the authored reason.",
            event_type: "release",
            rev: 17,
            updated_at: "2026-08-24T18:22:00Z"
          }
        }
      })

    assert html =~ "data-paper-link-card"
    assert html =~ "Chronicle headlines now name specific subjects"
    assert html =~ "See the full day behind this summary."
    assert html =~ "release · rev 17 · 2026-08-24T18:22:00Z"
    assert html =~ "This description stays behind the authored reason."
    assert html =~ "Why it matters:"
  end

  test "all authored and resolved text is escaped" do
    block = %{
      "type" => "paper-links",
      "title" => "<img src=x onerror=alert(1)>",
      "refs" => [%{"slug" => "paper\" onclick=\"alert(2)", "reason" => "<script>x</script>"}]
    }

    html = Render.render_block(block, %{style: :article})

    refute html =~ "<img"
    refute html =~ "<script>"
    refute html =~ "onclick=\"alert(2)\""
    assert html =~ "&lt;img"
    assert html =~ "&lt;script&gt;"
  end

  test "does not repeat a fallback description as its own reason" do
    block = %{
      "type" => "paper-links",
      "refs" => [
        %{
          "slug" => "the-80-column-standard",
          "description" => "A useful principle for terminal Papers.",
          "reason" => "A useful principle for terminal Papers"
        }
      ]
    }

    html = Render.render_block(block, %{style: :article})

    assert html =~ "A useful principle for terminal Papers."
    refute html =~ "Why it matters:"
    assert html =~ "background:var(--paper-accent-soft"
  end

  test "chapter layout keeps authored editorial copy while exposing a live edition" do
    block = %{
      "type" => "paper-links",
      "layout" => "chapters",
      "title" => "August, week by week",
      "description" => "Five distinct chapters.",
      "refs" => [
        %{
          "slug" => "barkpark-changelog-2026-w35",
          "title" => "Papers bring visual proof into the story",
          "description" => "Screenshots now explain the change instead of decorating it.",
          "eyebrow" => "Week 35 · 24 Aug–30 Aug",
          "meta" => "206 verified changes",
          "prefer_authored_copy" => true,
          "featured" => true
        }
      ]
    }

    html =
      Render.render_block(block, %{
        style: :article,
        paper_links: %{
          "barkpark-changelog-2026-w35" => %{
            title: "Generic live title",
            description: "Generic live description",
            rev: 12
          }
        }
      })

    assert html =~ ~s(data-layout="chapters")
    assert html =~ "data-chapter"
    assert html =~ "Papers bring visual proof into the story"
    assert html =~ "Screenshots now explain the change"
    assert html =~ "Week 35 · 24 Aug–30 Aug"
    assert html =~ "Live edition · 206 verified changes"
    assert html =~ "grid-column:1/-1"
    refute html =~ "Generic live title"
    refute html =~ "Generic live description"
    refute html =~ "rev 12"
  end

  test "heading presentation preserves authored whitespace and keeps absent copy reader-only" do
    block = %{
      "type" => "paper-links",
      "title" => "  Authored heading  ",
      "description" => "  Authored description  ",
      "refs" => ["next-paper"]
    }

    html = Render.render_block(block, %{style: :article})

    assert html =~ ">  Authored heading  </h2>"
    assert html =~ ">  Authored description  </p>"

    default_html =
      Render.render_block(%{"type" => "paper-links", "refs" => ["next-paper"]}, %{
        style: :article
      })

    assert default_html =~ ">Explore the work</h2>"
    refute default_html =~ "<p style="
    assert Render.render_block(%{"type" => "paper-links", "refs" => []}, %{style: :article}) == ""
  end

  test "shared presentation keeps the reader's default, chapters, and timeline geometry" do
    default = Compose.paper_links_presentation(%{"refs" => ["next"]}, :article)

    assert default.title == "Explore the work"
    assert default.title_source == ""
    assert default.title_default?

    assert default.section_style ==
             "margin:2.8rem 0 0;padding-top:1.35rem;border-top:1px solid var(--paper-rule, #dde7e2)"

    whitespace =
      Compose.paper_links_presentation(
        %{"title" => "   ", "description" => "\n ", "refs" => ["next"]},
        :article
      )

    assert whitespace.title == "Explore the work"
    assert whitespace.title_source == "   "
    assert whitespace.description == nil
    assert whitespace.description_source == "\n "

    chapters =
      Compose.paper_links_presentation(%{"layout" => "chapters", "refs" => ["next"]}, :article)

    assert chapters.header_style == "margin:0 0 2.15rem"
    assert chapters.title_style =~ "font-size:clamp(1.8rem,4vw,2.65rem)"
    assert chapters.grid_style =~ "minmax(min(100%,25rem),1fr)"

    timeline =
      Compose.paper_links_presentation(%{"layout" => "timeline", "refs" => ["next"]}, :article)

    assert timeline.section_style =~ "border-top:3px double"
    assert timeline.grid_style =~ "minmax(min(100%,13rem),1fr)"

    assert timeline.description_style ==
             "margin:0.45rem 0 0;color:var(--paper-ink-soft, #55635e);line-height:1.6"
  end
end
