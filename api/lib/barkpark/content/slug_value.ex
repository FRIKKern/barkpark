defmodule Barkpark.Content.SlugValue do
  @moduledoc """
  The stored shape of a `slug` field (owner ruling #43, task-26394ff887df3261).

  `{"_type": "slug", "current": "my-post"}` is canonical: the starters, the
  seeds and the typed SDK use it, and Studio writes it since the ruling.
  Studio wrote a plain string before; such a value is still read everywhere
  and is rewritten the next time its document is saved in Studio, never in
  bulk.
  """

  @doc "The slug text of either stored shape, or `nil`."
  @spec text(term()) :: String.t() | nil
  def text(s) when is_binary(s), do: if(s == "", do: nil, else: s)
  def text(%{"current" => s}) when is_binary(s), do: text(s)
  def text(%{current: s}) when is_binary(s), do: text(s)
  def text(_), do: nil

  @doc "The canonical stored value for slug text."
  @spec canonical(String.t()) :: map()
  def canonical(s) when is_binary(s), do: %{"_type" => "slug", "current" => s}
end
