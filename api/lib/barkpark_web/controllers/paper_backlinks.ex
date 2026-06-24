defmodule BarkparkWeb.PaperBacklinks do
  @moduledoc """
  Renders the reader's **"Linked mentions"** section — the visible half of the
  backlinks feature. Given the `Barkpark.Content.Graph.reverse_referencers/2`
  result (papers that reference TO the one being read), it emits a tasteful HTML
  block to append AFTER the paper body in the public reader.

  ## Engine-backed (not a scan)

  This section is powered by the SAME indexed engine the Studio editor's
  backlinks pane uses — `Content.Graph.reverse_referencers/2`, an inbound-edge
  query over the materialised `content_edges` table (edges written on publish).
  It is NOT a full-corpus block scan. The reader therefore sees exactly the
  inbound referencers the graph engine resolved, scoped to the caller's tenant.

  Each referencer is an inbound-edge map:

      %{from_id, from_doc_id, title, type, kind, via_field, plugin_source}

  ## Contract

    * **Zero referencers → `""`.** An empty (or non-list) input renders NOTHING,
      so the controller/template can inline the string unconditionally and the
      section simply vanishes when nothing links here.
    * Each entry is the referencing paper's title as an
      `<a href="/papers/<from_doc_id>">`. The doc_id + title come from the
      referencer map; the href mirrors `Render.Walk.wikilink/3`'s `/papers/<id>`
      form. A referencer with no `from_doc_id` (an unresolved source) is skipped.
    * **No context snippets.** The indexed engine returns no per-occurrence text
      (the Studio pane has none either); the section is a clean list of linking
      titles. This is the deliberate trade for using the proper engine — the old
      scan's snippets are dropped for consistency with the Studio pane.

  ## Styling

  Inline styles only (mirrors `Render.Walk`, which targets email / web / Studio
  alike without an external sheet). It reuses the reader's serif body + warm
  rule colours so it reads as part of the article chrome, but adds NO new heavy
  stylesheet. All user text is HTML-escaped.
  """

  alias Barkpark.PortableDoc.Render.Util

  @typedoc """
  One inbound referencer as returned by `Content.Graph.reverse_referencers/2`.
  """
  @type referencer :: %{
          optional(:from_id) => String.t(),
          optional(:from_doc_id) => String.t() | nil,
          optional(:title) => String.t() | nil,
          optional(:type) => String.t() | nil,
          optional(:kind) => String.t() | nil,
          optional(:via_field) => String.t() | nil,
          optional(:plugin_source) => String.t() | nil
        }

  # Warm parchment palette constants, matched to the `.bp-paper-article` chrome
  # in `layouts/bulldocs.html.heex` (ink / muted / rule / accent). Inline so the
  # section is self-contained.
  @muted "#6a6a6a"
  @rule "#e6e2d8"
  @accent "#a23925"

  @doc """
  Render the "Linked mentions" section for a list of inbound referencers (the
  `Content.Graph.reverse_referencers/2` result). Returns `""` for an empty list
  (or any non-list), so the caller can splice it in unconditionally. A
  referencer with no resolvable `from_doc_id` is skipped; if that leaves no
  renderable entries, the whole section is omitted.
  """
  @spec section_html([referencer()]) :: String.t()
  def section_html(referencers) when is_list(referencers) and referencers != [] do
    items =
      referencers
      |> Enum.map(&entry_html/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("")

    if items == "" do
      ""
    else
      ~s(<section class="bp-paper-backlinks" aria-label="Linked mentions" ) <>
        ~s(style="margin-top:3rem;padding-top:1.4rem;border-top:1px solid #{@rule}">) <>
        ~s(<h2 style="font-size:0.82rem;letter-spacing:0.06em;text-transform:uppercase;) <>
        ~s(color:#{@muted};margin:0 0 1rem">Linked mentions</h2>) <>
        ~s(<ul style="list-style:none;margin:0;padding:0">#{items}</ul>) <>
        ~s(</section>)
    end
  end

  def section_html(_), do: ""

  # One referencer: its title as a link to /papers/<from_doc_id>. A referencer
  # with no resolvable doc_id (a source the engine could not hydrate under the
  # caller's scope) renders nothing — the reader never links to an opaque id.
  defp entry_html(%{from_doc_id: doc_id} = ref) when is_binary(doc_id) and doc_id != "" do
    href = Util.escape_attr("/papers/" <> doc_id)
    title_html = Util.escape_html(title_or_slug(Map.get(ref, :title), doc_id))

    ~s(<li style="margin:0 0 1rem">) <>
      ~s(<a href="#{href}" style="color:#{@accent};text-decoration:none;font-weight:600">) <>
      title_html <> ~s(</a>) <>
      ~s(</li>)
  end

  defp entry_html(_), do: ""

  defp title_or_slug(title, doc_id) do
    case title do
      t when is_binary(t) and t != "" -> t
      _ -> doc_id
    end
  end
end
