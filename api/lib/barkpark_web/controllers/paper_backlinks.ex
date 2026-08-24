defmodule BarkparkWeb.PaperBacklinks do
  @moduledoc """
  Renders graph-backed, editorial Paper cards below the public reader.

  Every card is a real tenant-scoped document from the materialised content
  graph. The LiveView refreshes this projection when edge projection finishes,
  keeping titles, summaries, revisions, timestamps, and relationships current.
  """

  alias Barkpark.PortableDoc.Render.Util

  @max_cards 6

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
      ~s(<section id="#{css_class}" class="bp-paper-connections #{css_class}" aria-label="#{label}" data-live="true">) <>
        ~s(<header class="bp-paper-connections-head"><div>) <>
        ~s(<p class="bp-paper-connections-kicker">Connected work</p>) <>
        ~s(<h2>#{label}</h2><p>#{description}</p></div>) <>
        ~s(<span class="bp-paper-live"><i aria-hidden="true"></i>Live</span></header>) <>
        ~s(<div class="bp-paper-card-grid">#{cards}</div></section>)
    end
  end

  defp card_html(%{from_doc_id: doc_id} = ref) when is_binary(doc_id) and doc_id != "" do
    href = Util.escape_attr("/papers/" <> doc_id)
    title = Util.escape_html(title_or_slug(Map.get(ref, :title), doc_id))
    summary = Util.escape_html(summary(ref))
    badge = Util.escape_html(badge(ref))
    metadata = Util.escape_html(metadata(ref))

    ~s(<a class="bp-paper-card" href="#{href}">) <>
      ~s(<span class="bp-paper-card-top"><span class="bp-paper-card-badge">#{badge}</span>) <>
      ~s(<span class="bp-paper-card-arrow" aria-hidden="true">↗</span></span>) <>
      ~s(<strong>#{title}</strong><span class="bp-paper-card-summary">#{summary}</span>) <>
      ~s(<span class="bp-paper-card-meta">#{metadata}</span></a>)
  end

  defp card_html(_), do: ""

  defp title_or_slug(title, _doc_id) when is_binary(title) and title != "", do: title
  defp title_or_slug(_title, doc_id), do: doc_id

  defp summary(ref) do
    case Map.get(ref, :description) do
      value when is_binary(value) and value != "" -> value
      _ -> "References this Paper in its current published revision."
    end
  end

  defp badge(ref) do
    case Map.get(ref, :event_type) || Map.get(ref, :type) do
      value when is_binary(value) and value != "" ->
        value |> String.replace("_", " ") |> String.capitalize()

      _ ->
        "Paper"
    end
  end

  defp metadata(ref) do
    [revision_label(Map.get(ref, :rev)), updated_label(Map.get(ref, :updated_at))]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "Published Paper"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp revision_label(rev) when is_binary(rev) and rev != "", do: "Rev " <> rev
  defp revision_label(_), do: nil

  defp updated_label(%DateTime{} = value),
    do: "Updated " <> Calendar.strftime(value, "%d %b %Y")

  defp updated_label(%NaiveDateTime{} = value),
    do: "Updated " <> Calendar.strftime(value, "%d %b %Y")

  defp updated_label(_), do: nil
end
