defmodule Barkpark.PortableDoc.Render.PaperLinksTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

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
end
