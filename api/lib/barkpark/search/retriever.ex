defmodule Barkpark.Search.Retriever do
  @moduledoc """
  The public, engine-neutral retriever contract for the document search SEAM.

  A retriever takes a resolved tenant `scope`, a `parsed` query map, the
  surface `config` (string-keyed), and read `opts`, and returns the matching
  hits plus a total count. The built-in `Barkpark.Search.DocumentsRetriever`
  implements this over Postgres and is the default for every surface.

  Plugins back a surface with a different engine by implementing this behaviour
  and registering the module under an engine name:

      config :barkpark, :search_retrievers, %{"indx" => MyApp.IndxRetriever}

  A surface then opts in by setting its `engine` field (see
  `Barkpark.Search.SurfaceConfigs`) to that name. `Barkpark.Search.Retrievers`
  resolves the engine to the module; an unknown engine falls back to the
  Postgres default, so a misconfiguration never takes a surface dark.
  """

  @doc """
  Run a search for the given scope/query/config and return `{hits, total}`.
  """
  @callback search(
              scope :: String.t(),
              parsed :: map(),
              config :: map(),
              opts :: keyword()
            ) :: {list(), non_neg_integer()}
end
