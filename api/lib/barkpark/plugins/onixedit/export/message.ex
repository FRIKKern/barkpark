defmodule Barkpark.Plugins.OnixEdit.Export.Message do
  @moduledoc """
  ONIX 3.0 `<ONIXMessage>` wrapper. Sets the `release="3.0"` attribute and the
  reference-tag namespace per EDItEUR §3.0.
  """

  @release "3.0"
  @xmlns "http://ns.editeur.org/onix/3.0/reference"

  @doc """
  Wrap a header element and a list (or single) of `<Product>` elements into a
  full `<ONIXMessage>`. Returns iodata via `XmlBuilder.generate/2` with an XML
  declaration prologue.
  """
  @spec wrap(any(), any()) :: iodata()
  def wrap(header, products) do
    products_list = if is_list(products), do: products, else: [products]
    children = [header | products_list]

    # NB: attrs are a keyword list, not a map. Erlang's small-map enumeration
    # order is non-deterministic across VM starts (Goal barkpark-mgu surfaced
    # this as proof-artifact drift between `mix onix.export_proof` regens),
    # so we pass an ordered keyword list to keep attribute order byte-stable.
    :ONIXMessage
    |> XmlBuilder.document([release: @release, xmlns: @xmlns], children)
    |> XmlBuilder.generate()
  end
end
