defmodule Barkpark.Tenancy.SlugText do
  @moduledoc """
  Is this slug text the database takes?

  Postgres refuses a `text` value that is not UTF-8, and one that holds a NUL
  (Postgrex 22021 either way). No stored slug can hold such bytes, so a slug
  that does names nothing: `Tenancy.get_workspace_by_slug/1` and
  `Tenancy.get_project/2` answer nil for it without a read, as they do for a
  slug nobody has.
  """

  @doc "UTF-8 with no NUL in it."
  @spec text?(binary()) :: boolean()
  def text?(slug) when is_binary(slug),
    do: String.valid?(slug) and not String.contains?(slug, <<0>>)
end
