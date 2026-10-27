defmodule Barkpark.DeskIcons do
  @moduledoc """
  The icon names a desk item may carry (task-af038d8b0d769e82): Sanity's, as
  `@sanity/icons` 5.2.3 names them (MIT), so a desk declared for Sanity draws in
  both Barkpark Studios. `priv/desk_icons.json` maps each name to its SVG body in
  Sanity's 25-unit box; barkpark-studio vendors the same file. Plus `library`
  (lucide, ISC), which gyldendal.no's desk uses, and the `lucide:<name>` icons
  (lucide-static 1.61.0, ISC) that gyldendal.no's schemas name.

  The LiveView Studio draws one of these with `BarkparkWeb.Icons.desk_icon/1`
  when its own (lucide) set has no glyph of that name, and a deskStructure
  document naming anything else is answered with an `unknown_desk_icon`
  advisory on save (`Barkpark.Content.Writer`).
  """

  @path Path.expand("../../priv/desk_icons.json", __DIR__)
  @external_resource @path
  @icons @path |> File.read!() |> Jason.decode!()

  @doc "Every desk icon name, sorted."
  @spec names() :: [String.t()]
  def names, do: @icons |> Map.keys() |> Enum.sort()

  @doc "True for a name a desk item may carry."
  @spec known?(term()) :: boolean()
  def known?(name) when is_binary(name), do: Map.has_key?(@icons, name)
  def known?(_), do: false

  @doc "The SVG body (inside a 25×25 viewBox) for `name`, or nil."
  @spec body(term()) :: String.t() | nil
  def body(name) when is_binary(name), do: Map.get(@icons, name)
  def body(_), do: nil
end
