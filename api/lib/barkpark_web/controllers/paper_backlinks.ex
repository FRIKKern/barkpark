defmodule BarkparkWeb.PaperBacklinks do
  @moduledoc """
  Renders graph-backed, editorial Paper cards below the public reader.

  Every card is a real tenant-scoped document from the materialised content
  graph. The LiveView refreshes this projection when edge projection finishes,
  keeping titles, summaries, revisions, timestamps, and relationships current.
  """

  alias Barkpark.PortableDoc.Render.Util

  @max_cards 4

  @section_style "margin-top:4.5rem;padding-top:1.5rem;border-top:1px solid var(--paper-rule,#dde7e2)"
  @head_style "display:flex;align-items:flex-start;justify-content:space-between;gap:1.5rem;margin-bottom:1.25rem"
  @kicker_style "margin:0 0 0.35rem;color:var(--paper-accent,#1e5347);font-family:ui-sans-serif,system-ui,sans-serif;font-size:0.68rem;font-weight:700;letter-spacing:0.11em;text-transform:uppercase"
  @heading_style "margin:0;color:var(--paper-ink,#17332d);font-size:1.45rem;line-height:1.2;letter-spacing:-0.02em"
  @description_style "max-width:32rem;margin:0.4rem 0 0;color:var(--paper-ink-soft,#55635e);font-size:0.88rem;line-height:1.5"
  @live_style "display:inline-flex;flex:none;align-items:center;gap:0.4rem;margin-top:0.2rem;color:var(--paper-ink-soft,#55635e);font-family:ui-sans-serif,system-ui,sans-serif;font-size:0.68rem;font-weight:650;letter-spacing:0.08em;text-transform:uppercase"
  @dot_style "display:block;width:0.42rem;height:0.42rem;border-radius:50%;background:var(--paper-accent,#1e5347)"
  @grid_style "display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,16rem),1fr));gap:0.75rem"
  @card_style "display:flex;min-width:0;min-height:10.5rem;flex-direction:column;padding:1rem;border:1px solid var(--paper-rule,#dde7e2);background:color-mix(in srgb,var(--paper-bg,#fff) 84%,transparent);color:var(--paper-ink,#17332d);text-decoration:none"
  @card_top_style "display:flex;align-items:center;justify-content:space-between;gap:1rem;margin-bottom:1.1rem"
  @badge_style "color:var(--paper-ink-soft,#55635e);font-family:ui-sans-serif,system-ui,sans-serif;font-size:0.67rem;letter-spacing:0.075em;text-transform:uppercase"
  @arrow_style "color:var(--paper-accent,#1e5347);font-size:1rem"
  @title_style "display:block;color:var(--paper-ink,#17332d);font-family:ui-serif,Georgia,serif;font-size:1.05rem;line-height:1.28"
  @summary_style "display:-webkit-box;overflow:hidden;margin-top:0.45rem;color:var(--paper-ink-soft,#55635e);font-size:0.79rem;line-height:1.45;-webkit-box-orient:vertical;-webkit-line-clamp:2"
  @meta_style "margin-top:auto;padding-top:1rem;color:var(--paper-ink-soft,#55635e);font-family:ui-sans-serif,system-ui,sans-serif;font-size:0.67rem;letter-spacing:0.075em;text-transform:uppercase"

  @type referencer :: %{
          optional(:from_id) => String.t(),
          optional(:from_doc_id) => String.t() | nil,
          optional(:title) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:event_type) => String.t() | nil,
          optional(:rev) => String.t() | nil,
          optional(:updated_at) => DateTime.t() | NaiveDateTime.t() | nil,
          optional(:type) => String.t() | nil,
          optional(:kind) => String.t() | nil
        }

  @spec section_html([referencer()]) :: String.t()
  def section_html(referencers) when is_list(referencers) and referencers != [] do
    {used_by, related} =
      referencers
      |> Enum.filter(&(Map.get(&1, :type) in [nil, "paper"]))
      |> Enum.split_with(&(Map.get(&1, :kind) == "valueref"))

    group_html(used_by, "Used by", "Papers that depend on this work.", "bp-paper-usedby") <>
      group_html(
        related,
        "Related papers",
        "Live from Barkpark’s content graph — open a Paper to keep reading.",
        "bp-paper-related"
      )
  end

  def section_html(_), do: ""

  defp group_html(referencers, label, description, css_class) do
    cards =
      referencers
      |> Enum.map(&card_html/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(@max_cards)
      |> Enum.join("")

    if cards == "" do
      ""
    else
      ~s(<section id="#{css_class}" class="bp-paper-connections #{css_class}" aria-label="#{label}" data-live="true" style="#{@section_style}">) <>
        ~s(<header class="bp-paper-connections-head" style="#{@head_style}"><div>) <>
        ~s(<p class="bp-paper-connections-kicker" style="#{@kicker_style}">Connected work</p>) <>
        ~s(<h2 style="#{@heading_style}">#{label}</h2><p style="#{@description_style}">#{description}</p></div>) <>
        ~s(<span class="bp-paper-live" style="#{@live_style}"><i aria-hidden="true" style="#{@dot_style}"></i>Live</span></header>) <>
        ~s(<div class="bp-paper-card-grid" style="#{@grid_style}">#{cards}</div></section>)
    end
  end

  defp card_html(%{from_doc_id: doc_id} = ref) when is_binary(doc_id) and doc_id != "" do
    href = Util.escape_attr("/papers/" <> doc_id)
    title = Util.escape_html(title_or_slug(Map.get(ref, :title), doc_id))
    summary = Util.escape_html(summary(ref))
    badge = Util.escape_html(badge(ref))
    metadata = Util.escape_html(metadata(ref))
    revision = revision_attr(Map.get(ref, :rev))

    ~s(<a class="bp-paper-card" href="#{href}"#{revision} style="#{@card_style}">) <>
      ~s(<span class="bp-paper-card-top" style="#{@card_top_style}"><span class="bp-paper-card-badge" style="#{@badge_style}">#{badge}</span>) <>
      ~s(<span class="bp-paper-card-arrow" aria-hidden="true" style="#{@arrow_style}">↗</span></span>) <>
      ~s(<strong style="#{@title_style}">#{title}</strong><span class="bp-paper-card-summary" style="#{@summary_style}">#{summary}</span>) <>
      ~s(<span class="bp-paper-card-meta" style="#{@meta_style}">#{metadata}</span></a>)
  end

  defp card_html(_), do: ""

  defp title_or_slug(title, _doc_id) when is_binary(title) and title != "", do: title
  defp title_or_slug(_title, doc_id), do: doc_id

  defp summary(ref) do
    case Map.get(ref, :description) do
      value when is_binary(value) and value != "" -> value
      _ -> "See how this work fits into the wider story."
    end
  end

  defp badge(ref) do
    case Map.get(ref, :event_type) || Map.get(ref, :type) do
      "changelog.index" ->
        "Chronicle"

      "changelog.year" ->
        "Year in review"

      "changelog.month" ->
        "Monthly edition"

      "changelog.week" ->
        "Weekly edition"

      "changelog.day" ->
        "Daily edition"

      value when is_binary(value) and value != "" ->
        value
        |> String.replace(~r/[._-]+/, " ")
        |> String.capitalize()

      _ ->
        "Paper"
    end
  end

  defp metadata(ref) do
    updated_label(Map.get(ref, :updated_at)) || "Published Paper"
  end

  defp revision_attr(rev) when is_binary(rev) and rev != "",
    do: ~s( data-paper-revision="#{Util.escape_attr(rev)}")

  defp revision_attr(_), do: ""

  defp updated_label(%DateTime{} = value),
    do: "Updated " <> Calendar.strftime(value, "%d %b %Y")

  defp updated_label(%NaiveDateTime{} = value),
    do: "Updated " <> Calendar.strftime(value, "%d %b %Y")

  defp updated_label(_), do: nil
end
