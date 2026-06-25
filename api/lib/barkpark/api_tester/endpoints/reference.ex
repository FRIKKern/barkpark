defmodule Barkpark.ApiTester.Endpoints.Reference do
  @moduledoc """
  Docs-only Reference catalog pages for the Studio API Docs + Playground
  pane. Split out of `Barkpark.ApiTester.Endpoints` (the facade) — each
  entry is moved verbatim; see that module's @moduledoc for the spec shape.

  `entries/1` returns this category's slice of the full catalog, in the
  exact order the facade concatenates it.
  """

  @doc "Reference entries (envelope, error codes, known limitations), in catalog order."
  @spec entries(String.t()) :: [map()]
  def entries(_dataset) do
    [
      ref_envelope(),
      ref_error_codes(),
      ref_known_limitations()
    ]
  end

  defp ref_envelope do
    %{
      id: "ref-envelope",
      category: "Reference",
      label: "Document envelope",
      kind: :reference,
      render_key: :envelope,
      description:
        "Every document is returned as a flat JSON object with 7 reserved _-prefixed keys plus arbitrary user fields."
    }
  end

  defp ref_error_codes do
    %{
      id: "ref-errors",
      category: "Reference",
      label: "Error codes",
      kind: :reference,
      render_key: :error_codes,
      description:
        "All errors return {\"error\": {\"code\": \"...\", \"message\": \"...\"}} — 9 codes total."
    }
  end

  defp ref_known_limitations do
    %{
      id: "ref-limits",
      category: "Reference",
      label: "Known limitations",
      kind: :reference,
      render_key: :known_limitations,
      description: "6 quirks of v1 that may bite real clients."
    }
  end
end
