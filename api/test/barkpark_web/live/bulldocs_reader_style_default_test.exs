defmodule BarkparkWeb.BulldocsReaderStyleDefaultTest do
  @moduledoc """
  onb-residue-onb16-body-html-render-default — a published paper with NO
  `content["style"]` reads as an ARTICLE on the web reader.

  Before this row the block HTML was already `:article` (#16037 for the stored
  `body_html`, task-c46967eb3dc49e77 for the live reader's per-block render),
  but the reader CHROME still keyed on `style in ["article", "article-wide"]`:
  a style-less paper got

      <main data-paper-palette="legacy" class="bp-paper-shell">

  i.e. the dark legacy page with NO `.bp-paper-surface` sink, so the classed
  `:article` block markup (`bp-*` classes, `var(--paper-*)` tokens) landed
  outside the one stylesheet scope written to paint it.

  Three arms:

    1. The web default — style-less → article chrome (the change).
    2. Explicit styles stay byte-identical — `article`, `article-wide`, and an
       explicit non-article marker (`email`) render the same `<main>` open tag
       and the same `#paper-body` bytes as before this row (goldens captured on
       the pre-change base).
    3. The email delivery path is byte-identical — `GET /papers/:slug/email`
       for the style-less and the article paper matches the pre-change golden.

  Regenerate goldens ONLY on a tree whose reader/email output is meant to move:
  `REGEN_READER_STYLE_GOLDENS=1 mix test <this file>`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  @golden_dir Path.expand("../../support/fixtures/reader_style_default", __DIR__)

  @blocks [
    %{"id" => "rsd-h", "type" => "heading", "level" => 2, "text" => "A plain section"},
    %{
      "id" => "rsd-p",
      "type" => "paragraph",
      "content" => [%{"type" => "text", "value" => "Style-less prose on the web reader."}]
    },
    %{
      "id" => "rsd-c",
      "type" => "callout",
      "tone" => "success",
      "content" => [%{"type" => "text", "value" => "The gate is green."}]
    },
    %{
      "id" => "rsd-l",
      "type" => "list",
      "items" => [
        [%{"type" => "text", "value" => "First bullet"}],
        [%{"type" => "text", "value" => "Second bullet"}]
      ]
    }
  ]

  # `style: nil` omits the key entirely (the style-less population: upsert
  # with no style and no title-role block never stamps one). A non-article
  # explicit marker cannot pass `upsert_paper/1` (`Labels.paper_style/2`
  # normalizes it away), so it is written onto the stored row directly — the
  # shape a raw documents write or an older producer leaves behind.
  defp paper!(slug, style) do
    attrs = %{slug: slug, title: "Reader style #{slug}", blocks: @blocks}

    attrs =
      if style in ["article", "article-wide"], do: Map.put(attrs, :style, style), else: attrs

    {:ok, paper} = Content.upsert_paper(Barkpark.LabelFixtures.paper_attrs(attrs))

    paper =
      if is_binary(style) and style not in ["article", "article-wide"] do
        paper
        |> Document.changeset(%{"content" => Map.put(paper.content, "style", style)})
        |> Repo.update!()
      else
        paper
      end

    assert Map.get(paper.content, "style") == style
    paper
  end

  defp main_open_tag(html) do
    [tag] = Regex.run(~r/<main\b[^>]*class="bp-paper-shell[^"]*"[^>]*>/, html)
    tag
  end

  defp reader(conn, slug) do
    {:ok, view, html} = live(conn, "/papers/#{slug}")
    {main_open_tag(html), view |> element("#paper-body") |> render() |> strip_rev()}
  end

  # `data-rev` is the stored row's revision id — minted per upsert, so it is
  # the one byte range that differs run to run for the same content.
  defp strip_rev(html), do: String.replace(html, ~r/ data-rev="[^"]*"/, "")

  defp golden(name, actual) do
    path = Path.join(@golden_dir, name)

    if System.get_env("REGEN_READER_STYLE_GOLDENS") == "1" do
      File.mkdir_p!(@golden_dir)
      File.write!(path, actual)
    end

    assert actual == File.read!(path), "#{name} moved (golden: #{path})"
  end

  describe "web reader default" do
    test "a style-less published paper renders with the article chrome", %{conn: conn} do
      paper!("rsd-styleless", nil)
      {main, body} = reader(conn, "rsd-styleless")

      assert main ==
               ~s(<main data-paper-palette="article" class="bp-paper-shell bp-paper-surface bp-paper-article">)

      assert body =~ "Style-less prose on the web reader."
    end

    test "the style-less body bytes equal the explicit-article body bytes", %{conn: conn} do
      paper!("rsd-parity-a", nil)
      paper!("rsd-parity-b", "article")

      {_, styleless} = reader(conn, "rsd-parity-a")
      {_, article} = reader(conn, "rsd-parity-b")

      assert styleless == article
    end
  end

  describe "explicit styles are byte-identical to before" do
    for style <- ["article", "article-wide", "email"] do
      @style style
      test "style=#{style} keeps its <main> tag and #paper-body bytes", %{conn: conn} do
        slug = "rsd-explicit-#{@style}"
        paper!(slug, @style)
        {main, body} = reader(conn, slug)

        golden("reader-#{@style}.main.html", main)
        golden("reader-#{@style}.body.html", body)
      end
    end
  end

  describe "email delivery is byte-identical to before" do
    for style <- [nil, "article"] do
      @style style
      test "GET /papers/:slug/email for style=#{inspect(@style)}", %{conn: _conn} do
        slug = "rsd-email-#{@style || "none"}"
        paper!(slug, @style)

        html = build_conn() |> get("/papers/#{slug}/email") |> response(200)

        golden("email-#{@style || "none"}.html", html)
      end
    end
  end
end
