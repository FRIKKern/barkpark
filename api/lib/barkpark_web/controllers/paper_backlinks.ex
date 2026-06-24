defmodule BarkparkWeb.PaperBacklinks do
  @moduledoc """
  Renders the reader's **"Linked mentions"** section — the visible half of the
  backlinks feature. Given the `Barkpark.Content.Backlinks.backlinks_for/3`
  result (papers that link TO the one being read), it emits a tasteful HTML
  block to append AFTER the paper body in the public reader.

  ## Contract

    * **Zero backlinks → `""`.** An empty (or non-list) input renders NOTHING,
      so the controller/template can inline the string unconditionally and the
      section simply vanishes when nothing links here.
    * Each entry is the linking paper's title as an `<a href="/papers/<slug>">`
      plus its context snippet(s). The slug + title come from the backlinks
      result; the href mirrors `Render.Walk.wikilink/3`'s `/papers/<id>` form.
    * A `:fallback`-only context is marked with a muted "~" affordance — the
      match is best-effort (a typed link that merely *names* this paper), so the
      UI signals it as softer than a precise id-pinned link. A paper with ANY
      precise context is treated as a precise (solid) mention.

  ## Styling

  Inline styles only (mirrors `Render.Walk`, which targets email / web / Studio
  alike without an external sheet). It reuses the reader's serif body + warm
  rule colours so it reads as part of the article chrome, but adds NO new heavy
  stylesheet. All user text is HTML-escaped.
  """

  alias Barkpark.PortableDoc.Render.Util

  # Warm parchment palette constants, matched to the `.bp-paper-article` chrome
  # in `layouts/bulldocs.html.heex` (ink / muted / rule / accent). Inline so the
  # section is self-contained.
  @ink "#1a1a1a"
  @muted "#6a6a6a"
  @rule "#e6e2d8"
  @accent "#a23925"

  @doc """
  Render the "Linked mentions" section for a backlinks list. Returns `""` for an
  empty list (or any non-list), so the caller can splice it in unconditionally.
  """
  @spec section_html([Barkpark.Content.Backlinks.backlink()]) :: String.t()
  def section_html(backlinks) when is_list(backlinks) and backlinks != [] do
    items = Enum.map_join(backlinks, "", &entry_html/1)

    ~s(<section class="bp-paper-backlinks" aria-label="Linked mentions" ) <>
      ~s(style="margin-top:3rem;padding-top:1.4rem;border-top:1px solid #{@rule}">) <>
      ~s(<h2 style="font-size:0.82rem;letter-spacing:0.06em;text-transform:uppercase;) <>
      ~s(color:#{@muted};margin:0 0 1rem">Linked mentions</h2>) <>
      ~s(<ul style="list-style:none;margin:0;padding:0">#{items}</ul>) <>
      ~s(</section>)
  end

  def section_html(_), do: ""

  # One linking paper: its title (a link to /papers/<slug>) + its contexts.
  defp entry_html(%{slug: slug, title: title} = entry) do
    contexts = Map.get(entry, :contexts, [])
    href = Util.escape_attr("/papers/" <> to_string(slug))
    title_html = Util.escape_html(title_or_slug(title, slug))

    ~s(<li style="margin:0 0 1rem">) <>
      ~s(<a href="#{href}" style="color:#{@accent};text-decoration:none;font-weight:600">) <>
      title_html <> ~s(</a>) <>
      contexts_html(contexts) <>
      ~s(</li>)
  end

  defp entry_html(_), do: ""

  # Render the snippet(s) under the title. A precise match shows the snippet
  # plainly; a fallback-only match prefixes a muted "~" to flag the softer link.
  defp contexts_html([]), do: ""

  defp contexts_html(contexts) do
    rows =
      contexts
      |> Enum.map(&context_row/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("")

    if rows == "", do: "", else: ~s(<div style="margin-top:0.3rem">#{rows}</div>)
  end

  defp context_row(%{text: text} = ctx) when is_binary(text) do
    case String.trim(text) do
      "" ->
        ""

      trimmed ->
        marker =
          if Map.get(ctx, :match) == :fallback do
            # Muted "~" affordance flags a best-effort (typed, un-pinned) link.
            # `~s{...}` (brace-delimited) because the title text carries literal
            # parens — a paren-delimited `~s(...)` would close early on them.
            ~s{<span title="best-effort match (typed link, no pinned id)" style="color:#{@muted}">~ </span>}
          else
            ""
          end

        ~s(<p style="margin:0.15rem 0 0;color:#{@ink};font-size:0.95rem;line-height:1.5">) <>
          marker <> Util.escape_html(trimmed) <> ~s(</p>)
    end
  end

  defp context_row(_), do: ""

  defp title_or_slug(title, slug) do
    case title do
      t when is_binary(t) and t != "" -> t
      _ -> to_string(slug)
    end
  end
end
