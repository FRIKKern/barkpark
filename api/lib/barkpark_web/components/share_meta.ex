defmodule BarkparkWeb.ShareMeta do
  @moduledoc """
  ONE shared emission helper for a document's social-share `<head>` block —
  the outward face of the preview contract (epic `preview-contract`, wave 2).

  Given a document's preview manifest (`content["preview"]`, the OpenGraph-shaped
  map pc-w1 computes at WRITE TIME), `head/1` renders the whole share head:

    * `og:*` tags (Open Graph, `property=`) — title, type, canonical url,
      description, and the full 5-field image object (url/width/height/alt/type)
      + `og:site_name`. `article:*` extensions (published_time/author/tag/section)
      for paper/post.
    * `twitter:*` tags (`name=`) — `summary_large_image` + title/description/image.
    * a JSON-LD `Article` (`<script type="application/ld+json">`) for paper/post.

  ## Contract (charter decisions)

    * **D3 — absolutize at emission.** Manifest `url`/`image.url` are stored
      RELATIVE; every emitted absolute URL is prefixed with
      `BarkparkWeb.Endpoint.url()` (scheme://host, NO internal port — the #1190
      fix). Already-absolute srcs pass through untouched. There is exactly ONE
      canonical `og:url`.
    * **D5 — branded default at emission.** A nil `image` emits the static
      `/images/og-default.jpg` card, so every document unfurls branded, never
      blank. Default geometry is 1200×630 (the `og` rendition preset).
    * **D7 — image object carries 5 fields** `{url,width,height,alt,type}`; a
      nil `alt` falls back to the title.
    * **D8 — type stays raw; emitters map.** `paper`/`post` → `og:type=article`
      (+ JSON-LD Article + `article:*`); everything else → `website`.
    * **D12 — nil-safe.** `head/1` must never crash on a nil/partial manifest —
      the shared `:bulldocs` layout also roots non-LiveView renders that may not
      assign `:preview`; a nil manifest renders site-default meta.

  ## Placement

  Emitted immediately after `<title>`, BEFORE the multi-KB inline style blob:
  Slack (and most unfurlers) read only the first 32 KB of the response.

  ## Manifest computation

  `manifest/4` is the single seam readers call to obtain a manifest for a doc:
  the write-time `content["preview"]` when present, else the pc-w1 read-time
  projection (`Barkpark.Preview.project/3`, called via `apply/3` so this module
  carries no compile-time dependency on pc-w1 and auto-activates the moment it
  merges — integration order pc-w1 → pc-w2), else a degraded-but-valid core
  manifest (title + type + url) so legacy/no-block docs still unfurl as a
  branded default card. Same-function-same-bytes drift-freedom is D6.
  """

  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  @site_name "Barkpark"
  @default_image "/images/og-default.jpg"
  @default_width 1200
  @default_height 630
  @default_image_type "image/jpeg"

  @doc """
  Render the full social-share `<head>` block from a preview manifest.

  Assigns:

    * `:preview` — the manifest map (`content["preview"]` or the read-time
      projection), or `nil` for site-default meta.
    * `:page_title` — the document title, used as the og/twitter title fallback
      when the manifest carries none.
  """
  attr :preview, :map, default: nil
  attr :page_title, :string, default: nil

  def head(assigns) do
    assigns = assign(assigns, :m, build_meta(assigns[:preview], assigns[:page_title]))

    ~H"""
    <meta property="og:site_name" content={@m.site_name} />
    <meta property="og:title" content={@m.title} />
    <meta property="og:type" content={@m.og_type} />
    <meta property="og:url" content={@m.url} />
    <meta :if={@m.description} property="og:description" content={@m.description} />
    <meta property="og:image" content={@m.image_url} />
    <meta property="og:image:width" content={@m.image_width} />
    <meta property="og:image:height" content={@m.image_height} />
    <meta property="og:image:alt" content={@m.image_alt} />
    <meta property="og:image:type" content={@m.image_type} />
    <meta :if={@m.published_time} property="article:published_time" content={@m.published_time} />
    <meta :for={author <- @m.authors} property="article:author" content={author} />
    <meta :for={tag <- @m.tags} property="article:tag" content={tag} />
    <meta :if={@m.section} property="article:section" content={@m.section} />
    <meta name="twitter:card" content={@m.twitter_card} />
    <meta name="twitter:title" content={@m.title} />
    <meta :if={@m.description} name="twitter:description" content={@m.description} />
    <meta name="twitter:image" content={@m.image_url} />
    <%!-- JSON-LD body uses <%= %> (not {…}): HEEx does not run curly
          interpolation inside <script>/<style> bodies. --%>
    <script :if={@m.json_ld} type="application/ld+json"><%= raw(@m.json_ld) %></script>
    """
  end

  # ── manifest computation (the reader seam) ──────────────────────────────────

  @doc """
  Compute the preview manifest for a document's `content` map.

  Resolution order (D1/D6):

    1. `content["preview"]` — the write-time manifest (best; never drifts).
    2. `Barkpark.Preview.project/3` — the pc-w1 read-time projection (legacy /
       no-`content["preview"]` docs), the SAME pure function the write path
       stamps with, so the bytes match. Called via `apply/3`, guarded on the
       module being loaded, so there is no compile-time coupling and the path
       lights up automatically once pc-w1 merges.
    3. a degraded core manifest (`title`/`type`/`url` + any excerpt) — always
       valid, so a classic no-block doc still unfurls as a branded default card.

  `url` is the RELATIVE canonical path (`/papers/:slug`); `head/1` absolutizes it.
  """
  def manifest(content, url, doc_type, fallback_title \\ nil)

  def manifest(content, url, doc_type, fallback_title) when is_map(content) do
    stamped = content["preview"]

    if is_map(stamped) do
      stamped
    else
      read_time_manifest(content, url, doc_type, fallback_title) ||
        degraded_manifest(content, url, doc_type, fallback_title)
    end
  end

  def manifest(_content, url, doc_type, fallback_title),
    do: degraded_manifest(%{}, url, doc_type, fallback_title)

  defp read_time_manifest(content, url, doc_type, fallback_title) do
    if Code.ensure_loaded?(Barkpark.Preview) and
         function_exported?(Barkpark.Preview, :project, 3) do
      blocks = Map.get(content, "blocks") || []

      # apply/3 (not a literal call) keeps this module free of a compile-time
      # dependency on the pc-w1 module — integration order pc-w1 → pc-w2.
      # `:title` is the ROW title — Preview.project's LAST title fallback, so a
      # classic doc whose title lives on the row (not in content) still unfurls
      # under its real name instead of the site default.
      opts = %{url: url, doc_type: doc_type, title: fallback_title}

      case apply(Barkpark.Preview, :project, [content, blocks, opts]) do
        # project/3 returns the manifest itself (D1); tolerate a wrapped
        # {"preview" => manifest} shape too, defensively.
        %{"preview" => %{} = m} -> m
        %{} = m -> m
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp degraded_manifest(content, url, doc_type, fallback_title) do
    %{
      "title" => clean(content["title"]) || clean(fallback_title) || @site_name,
      "type" => doc_type,
      "url" => url,
      "description" => clean(content["excerpt"]) || clean(content["description"]),
      "image" => nil
    }
  end

  # ── emission (pure) ─────────────────────────────────────────────────────────

  defp build_meta(preview, page_title) do
    m = normalize(preview, page_title)

    title = clean(m["title"]) || clean(page_title) || @site_name
    og_type = og_type(m["type"])
    article? = og_type == "article"
    url = absolutize(m["url"])
    description = clean(m["description"])

    {image_url, iw, ih, ialt, itype} = image_fields(m["image"], title)

    ext = extensions(m)
    authors = if article?, do: names(ext["authors"] || ext["author"]), else: []
    tags = if article?, do: strings(ext["tags"]), else: []
    published_time = if article?, do: clean(ext["published_time"]), else: nil
    section = if article?, do: clean(ext["section"]), else: nil

    json_ld =
      if article?,
        do: json_ld(title, url, image_url, description, published_time, authors),
        else: nil

    %{
      site_name: @site_name,
      title: title,
      og_type: og_type,
      url: url,
      description: description,
      image_url: image_url,
      image_width: to_string(iw),
      image_height: to_string(ih),
      image_alt: ialt,
      image_type: itype,
      twitter_card: "summary_large_image",
      published_time: published_time,
      authors: authors,
      tags: tags,
      section: section,
      json_ld: json_ld
    }
  end

  # A nil manifest → site-default meta seeded from the page title (D12).
  defp normalize(m, _page_title) when is_map(m), do: m

  defp normalize(_nil, page_title) do
    %{
      "title" => page_title,
      "type" => "website",
      "url" => nil,
      "description" => nil,
      "image" => nil
    }
  end

  # D8 — paper/post → article, everything else → website.
  defp og_type(t) when t in ["paper", "post", "article"], do: "article"
  defp og_type(_), do: "website"

  # D3 — absolutize a stored-relative URL against the public host (no internal
  # port). Already-absolute and protocol-relative srcs pass through; a nil url
  # falls back to the site root.
  defp absolutize(nil), do: BarkparkWeb.Endpoint.url()
  defp absolutize("http://" <> _ = u), do: u
  defp absolutize("https://" <> _ = u), do: u
  defp absolutize("//" <> _ = u), do: u
  defp absolutize("/" <> _ = path), do: BarkparkWeb.Endpoint.url() <> path
  defp absolutize(other) when is_binary(other), do: BarkparkWeb.Endpoint.url() <> "/" <> other
  defp absolutize(_), do: BarkparkWeb.Endpoint.url()

  # D5/D7 — the 5-field image object; a nil/blank image emits the branded
  # default card at 1200×630. A nil alt falls back to the title.
  defp image_fields(image, title) when is_map(image) do
    url = clean(image["url"])

    if url do
      {absolutize(url), image["width"] || @default_width, image["height"] || @default_height,
       clean(image["alt"]) || title, clean(image["type"]) || @default_image_type}
    else
      default_image(title)
    end
  end

  defp image_fields(_image, title), do: default_image(title)

  defp default_image(title),
    do: {absolutize(@default_image), @default_width, @default_height, title, @default_image_type}

  # Extensions (D9) may ride under an "extensions" sub-map or flat on the
  # manifest — read defensively from either.
  defp extensions(m) do
    case m["extensions"] do
      %{} = e -> e
      _ -> m
    end
  end

  defp names(nil), do: []
  defp names(list) when is_list(list), do: list |> Enum.map(&name/1) |> Enum.reject(&is_nil/1)
  defp names(one), do: names([one])

  defp name(%{} = a), do: clean(a["name"] || a["title"])
  defp name(s) when is_binary(s), do: clean(s)
  defp name(_), do: nil

  defp strings(nil), do: []

  defp strings(list) when is_list(list),
    do: list |> Enum.map(&tag_name/1) |> Enum.reject(&is_nil/1)

  defp strings(one) when is_binary(one), do: strings([one])
  defp strings(_), do: []

  # Dual-shape tag element (authoring-excellence D18): a weighted label
  # `%{"tag" => name, "strength" => _}` reads as its tag name; any OTHER map is
  # dropped (interpolating a Map into the `content={tag}` HEEx attr raises
  # Protocol.UndefinedError — the /papers/:slug crash this guards). Scalars and
  # strings clean exactly as before, so this module no longer depends on the
  # upstream Preview projection having already flattened the manifest's tags.
  # Mirrors `Barkpark.Preview.element_name/1`, but drops (nil) rather than "" —
  # ShareMeta rejects nils, so a bad map leaves NO empty article:tag behind.
  defp tag_name(%{"tag" => name}) when is_binary(name), do: clean(name)
  defp tag_name(%{}), do: nil
  defp tag_name(other), do: clean(other)

  # JSON-LD Article — `escape: :html_safe` escapes `<`, `>`, `&` (and the line
  # separators) to \\u escapes, so a title containing `</script>` cannot break
  # out of the inline script tag.
  defp json_ld(title, url, image_url, description, published_time, authors) do
    %{
      "@context" => "https://schema.org",
      "@type" => "Article",
      "headline" => title,
      "url" => url,
      "image" => image_url
    }
    |> put_present("description", description)
    |> put_present("datePublished", published_time)
    |> put_authors(authors)
    |> Jason.encode!(escape: :html_safe)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_authors(map, []), do: map

  defp put_authors(map, authors),
    do: Map.put(map, "author", Enum.map(authors, &%{"@type" => "Person", "name" => &1}))

  defp clean(nil), do: nil

  defp clean(s) when is_binary(s) do
    case String.trim(s) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean(other), do: other
end
