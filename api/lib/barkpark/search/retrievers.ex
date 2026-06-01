defmodule Barkpark.Search.Retrievers do
  @moduledoc """
  Engine → retriever-module registry for the document search SEAM.

  The built-in registry maps `"postgres"` to `Barkpark.Search.DocumentsRetriever`.
  Plugins extend it by registering their own engines:

      config :barkpark, :search_retrievers, %{"indx" => MyApp.IndxRetriever}

  Registered engines are merged OVER the built-ins, so a plugin could even
  override `"postgres"` if it ever needed to. `resolve/1` reads the surface
  config's `"engine"` (defaulting to `"postgres"`) and returns the module that
  implements `Barkpark.Search.Retriever`. An unknown engine falls back to the
  Postgres default — a misconfigured `engine` never takes a surface dark.
  """

  alias Barkpark.Search.DocumentsRetriever

  @default_engine "postgres"

  @builtin %{@default_engine => DocumentsRetriever}

  @doc """
  Resolve the retriever module for a surface config's engine.

  Reads `config["engine"]` (defaulting to `"postgres"`) and returns the
  registered module, falling back to the Postgres `DocumentsRetriever` for any
  engine that has no registration.
  """
  @spec resolve(map()) :: module()
  def resolve(config) when is_map(config) do
    engine = Map.get(config, "engine") || @default_engine
    Map.get(registry(), engine, DocumentsRetriever)
  end

  @doc """
  The full engine → module registry (built-ins merged with plugin-registered
  engines from `config :barkpark, :search_retrievers`).
  """
  @spec registry() :: %{optional(String.t()) => module()}
  def registry do
    Map.merge(@builtin, Application.get_env(:barkpark, :search_retrievers, %{}))
  end
end
