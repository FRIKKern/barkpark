defmodule BarkparkWeb.BulldocsEmailHTML do
  @moduledoc false

  alias Barkpark.PortableDoc.Render

  @absolute_scheme ~r/^(?:https?|mailto|tel):/i
  @href ~r/\s+href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i
  @unsafe_link_sentinel "https://email.invalid/.barkpark-unsafe-link"

  def authored_heading?(value), do: contains_heading?(value)

  def prepare_blocks(blocks, trusted_paper_uri),
    do: rewrite_block_links(blocks, trusted_paper_uri)

  def legacy_heading?(html) when is_binary(html),
    do: Regex.match?(~r/<h[1-6](?:\s|>)/i, html)

  def fallback_heading(title, opts) do
    Render.render_block(%{"type" => "heading", "level" => 1, "text" => title}, opts)
  end

  def finalize(html, title, trusted_paper_uri) do
    html
    |> add_title(title)
    |> absolutize_links(trusted_paper_uri)
  end

  defp contains_heading?(%{"type" => "heading"}), do: true

  defp contains_heading?(map) when is_map(map),
    do: Enum.any?(Map.values(map), &contains_heading?/1)

  defp contains_heading?(list) when is_list(list), do: Enum.any?(list, &contains_heading?/1)
  defp contains_heading?(_), do: false

  defp rewrite_block_links(%{"href" => href} = map, trusted_paper_uri) do
    rewritten = email_href(href, trusted_paper_uri) || @unsafe_link_sentinel

    map
    |> Map.put("href", rewritten)
    |> Map.new(fn {key, value} -> {key, rewrite_block_links(value, trusted_paper_uri)} end)
  end

  defp rewrite_block_links(map, trusted_paper_uri) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, rewrite_block_links(value, trusted_paper_uri)} end)

  defp rewrite_block_links(list, trusted_paper_uri) when is_list(list),
    do: Enum.map(list, &rewrite_block_links(&1, trusted_paper_uri))

  defp rewrite_block_links(value, _trusted_paper_uri), do: value

  defp add_title(html, title) do
    title_tag = "<title>#{Render.escape_html(title)}</title>"

    String.replace(html, ~s(<meta charset="utf-8">), ~s(<meta charset="utf-8">#{title_tag}),
      global: false
    )
  end

  defp absolutize_links(html, trusted_paper_uri) do
    Regex.replace(@href, html, fn _match, double, single, bare ->
      encoded_href = double <> single <> bare

      case email_href(encoded_href, trusted_paper_uri) do
        nil -> ""
        href -> ~s( href="#{Render.escape_attr(href)}")
      end
    end)
  end

  defp email_href(encoded_href, trusted_paper_uri) do
    href = decode_attr(encoded_href) |> String.replace(~r/^[\x00-\x20]+/, "")

    cond do
      href in ["", @unsafe_link_sentinel] -> nil
      String.starts_with?(href, "#") -> href
      Regex.match?(@absolute_scheme, href) -> href
      protocol_relative?(href) -> nil
      internal_relative?(href) -> trusted_paper_uri |> URI.merge(href) |> URI.to_string()
      true -> nil
    end
  end

  defp internal_relative?(href),
    do: String.starts_with?(href, ["/", "./", "../", "?"])

  defp protocol_relative?(href), do: Regex.match?(~r|^/[/\\]|, href)

  defp decode_attr(value) do
    value
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end
end
