defmodule Barkpark.Search.DocumentsRetriever do
  @moduledoc """
  The built-in Postgres retriever — the `"postgres"` engine in the document
  search SEAM and the default for every surface.

  This is a THIN adapter over `Barkpark.Content.search_documents_postgres/3`,
  which is PROD's exact, unchanged search implementation (synonym expansion,
  document FTS `search_vector`, trigram similarity, perspective filtering,
  rank ordering). The seam was layered in additively: extracting the engine
  indirection did NOT change a single line of the Postgres query — for
  `engine: "postgres"` (the default, the only engine any surface uses today)
  the behaviour is byte-identical to calling `search_documents` directly.

  ## Contract

  Implements `Barkpark.Search.Retriever`:

      search(scope, parsed, config, opts) :: {[%Document{}], non_neg_integer()}

  `scope` is the dataset string. `parsed` carries the raw query under
  `:query` (PROD's pipeline is a single ILIKE/FTS pass with synonym
  expansion happening inside `Content`, so the retriever forwards the raw
  string and lets `Content` own term expansion). `config` is the
  string-keyed surface config (unused by the Postgres path today — PROD's
  search is configuration-free; it is threaded through for engine parity).
  `opts` carries `:type`, `:perspective`, `:limit`, `:offset`.

  Plugins back a surface with a different engine by implementing
  `Barkpark.Search.Retriever` and registering under an engine name; this
  module stays the default fallback for any engine that has no registration.
  """

  @behaviour Barkpark.Search.Retriever

  alias Barkpark.Content

  @impl Barkpark.Search.Retriever
  @spec search(String.t(), map(), map(), keyword()) ::
          {[struct()], non_neg_integer()}
  def search(scope, parsed, _config, opts) when is_binary(scope) do
    query = query_string(parsed)

    if query == "" do
      {[], 0}
    else
      search_opts =
        Keyword.take(opts, [:type, :perspective, :limit, :offset])

      # Delegates to PROD's exact Postgres search (synonyms + FTS +
      # similarity + perspective + rank). NOT reimplemented here — the
      # search-intelligence behaviour lives in `Content` untouched.
      Content.search_documents_postgres(query, scope, search_opts)
    end
  end

  # The raw query string lives under `:query` in the parsed map. Fall back to
  # joining tokens for callers that build a token map instead of carrying the
  # raw string (the Indx path uses tokens; the Postgres default uses :query).
  defp query_string(parsed) when is_map(parsed) do
    case Map.get(parsed, :query) do
      q when is_binary(q) ->
        String.trim(q)

      _ ->
        (Map.get(parsed, :terms, []) ++
           Map.get(parsed, :phrases, []) ++ Map.get(parsed, :prefixes, []))
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" ")
        |> String.trim()
    end
  end

  defp query_string(_), do: ""
end
