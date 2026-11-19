defmodule Barkpark.PortableDoc.FromMarkdown.Url do
  @moduledoc """
  Which URLs `Barkpark.PortableDoc.FromMarkdown` keeps as links: the ones the
  renderer allows (`Barkpark.PortableDoc.Render.Util.safe_url/1`: http(s),
  mailto, tel, a root-relative `/path` that is not `//host`, and in-doc `#`,
  `?`, `./`, `../` forms). Any other link or image keeps its text only.
  """

  alias Barkpark.PortableDoc.Render.Util

  # Util.safe_url/1 strips these before it checks; the import keeps the cleaned
  # URL, so the stored href is the one that was checked.
  @control_bytes ~r/[\x{00}-\x{1F}\x{7F}-\x{9F}]/u
  @leading_spaces ~r/^\x20+/

  @doc "The cleaned URL when the renderer allows it, else nil."
  @spec safe(term()) :: String.t() | nil
  def safe(href) when is_binary(href) do
    cleaned =
      href
      |> String.replace(@control_bytes, "")
      |> String.replace(@leading_spaces, "")

    # safe_url/1 answers "#" for a refused URL; "#" itself is an allowed in-doc link.
    cond do
      cleaned == "" -> nil
      cleaned == "#" or Util.safe_url(cleaned) != "#" -> cleaned
      true -> nil
    end
  end

  def safe(_href), do: nil
end
