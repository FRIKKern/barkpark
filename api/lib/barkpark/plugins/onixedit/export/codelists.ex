defmodule Barkpark.Plugins.OnixEdit.Export.Codelists do
  @moduledoc """
  Static codelist resolver for the ONIX 3.0 export pipeline.

  WI3 starter maps for the four lists DescriptiveDetail emits against:

    * List 17  — `contributor_role/1`  (`A01 By (author)`, `B01 Edited by`, …)
    * List 93  — `thema/1`             (Thema subject codes; representative subset)
    * List 150 — `product_form/1`      (`BA Book`, `BB Hardback`, `EB Digital download…`)
    * List 175 — `product_form_detail/1` (Common product form detail codes)

  These maps are intentionally small — they cover the Norwegian-publisher
  primary use cases the test fixtures and seed data exercise. The full
  enumerations live in the vendored EDItEUR XSDs at
  `api/priv/onix/onix-3.0/ONIX_BookProduct_CodeLists.xsd`; WI4–WI5 will grow
  these maps as new fixtures demand it (and WI5's xmllint gate validates
  that whatever we emit matches the XSD enumerations exactly).

  Unknown codes raise `ArgumentError` with a clear `unknown_<list>_code`
  message — silent fall-through would risk emitting invalid ONIX that the
  XSD gate catches much later in the pipeline.
  """

  @type code :: String.t()

  @contributor_role %{
    "A01" => "By (author)",
    "A02" => "With",
    "A03" => "Screenplay by",
    "A04" => "Libretto by",
    "A05" => "Lyrics by",
    "A06" => "By (composer)",
    "A07" => "By (artist)",
    "A08" => "By (photographer)",
    "A09" => "Created by",
    "A12" => "Illustrated by",
    "A13" => "Photographs by",
    "A19" => "Afterword by",
    "A23" => "Foreword by",
    "A24" => "Introduction by",
    "B01" => "Edited by",
    "B02" => "Revised by",
    "B05" => "Adapted by",
    "B06" => "Translated by",
    "E07" => "Read by"
  }

  @product_form %{
    "AB" => "Audio cassette",
    "AC" => "CD-Audio",
    "AJ" => "Downloadable audio file",
    "AN" => "Downloadable and online / streamed audio file",
    "BA" => "Book",
    "BB" => "Hardback",
    "BC" => "Paperback / softback",
    "BE" => "Spiral bound",
    "BF" => "Pamphlet",
    "BG" => "Leather / fine binding",
    "BH" => "Board book",
    "EA" => "Digital (delivered electronically)",
    "EB" => "Digital download and online / streamed",
    "EC" => "Digital online / streamed",
    "ED" => "Digital download"
  }

  @product_form_detail %{
    "B102" => "Mass market (rack) paperback",
    "B104" => "Trade paperback",
    "B304" => "With dust jacket",
    "B305" => "Without dust jacket",
    "E101" => "EPUB",
    "E107" => "PDF",
    "E116" => "MOBI",
    "E117" => "AZW3"
  }

  @thema %{
    "F" => "Fiction & related items",
    "FB" => "General fiction",
    "FBA" => "Modern & contemporary fiction (post c 1945)",
    "FBC" => "Classic fiction (pre c 1945)",
    "Y" => "Children's, Teenage & Educational",
    "YF" => "Children's / Teenage fiction & true stories",
    "YN" => "Children's / Teenage: General non-fiction",
    "DN" => "Biography & non-fiction prose",
    "N" => "History & Archaeology",
    "P" => "Mathematics & Science"
  }

  @doc """
  Resolve a ContributorRole code (List 17). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_contributor_role_code` message on miss.
  """
  @spec contributor_role(code()) :: {:ok, code()}
  def contributor_role(code) when is_binary(code) do
    if Map.has_key?(@contributor_role, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_contributor_role_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a ProductForm code (List 150). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_product_form_code` message on miss.
  """
  @spec product_form(code()) :: {:ok, code()}
  def product_form(code) when is_binary(code) do
    if Map.has_key?(@product_form, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_product_form_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a ProductFormDetail code (List 175). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_product_form_detail_code` message on miss.
  """
  @spec product_form_detail(code()) :: {:ok, code()}
  def product_form_detail(code) when is_binary(code) do
    if Map.has_key?(@product_form_detail, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_product_form_detail_code: #{inspect(code)}"
    end
  end

  @doc """
  Resolve a Thema subject code (List 93 / Thema 1.5). Returns `{:ok, code}` on hit;
  raises `ArgumentError` with an `unknown_thema_code` message on miss.

  WI3 ships only a small representative subset (top-level fiction and
  non-fiction categories). Full Thema is ~3000 codes and is not enumerated in
  the ONIX XSD — when a publisher needs broader coverage WI4/WI5 grow this map
  or wire to `Barkpark.Content.Codelists` for DB-backed lookup.
  """
  @spec thema(code()) :: {:ok, code()}
  def thema(code) when is_binary(code) do
    if Map.has_key?(@thema, code) do
      {:ok, code}
    else
      raise ArgumentError, "unknown_thema_code: #{inspect(code)}"
    end
  end

  @doc false
  @spec contributor_role_label(code()) :: String.t() | nil
  def contributor_role_label(code), do: Map.get(@contributor_role, code)

  @doc false
  @spec product_form_label(code()) :: String.t() | nil
  def product_form_label(code), do: Map.get(@product_form, code)

  @doc false
  @spec thema_label(code()) :: String.t() | nil
  def thema_label(code), do: Map.get(@thema, code)
end
