defmodule Barkpark.Media.SearchAnalytics do
  @moduledoc """
  Deprecated — use `Barkpark.Search.MediaIntelligence`.

  Thin delegate kept for backward compatibility during the DAM → core migration.
  """

  defdelegate retention_days(), to: Barkpark.Search.MediaIntelligence
  defdelegate prune(opts \\ []), to: Barkpark.Search.MediaIntelligence
  defdelegate record(scope, params, total, ms, opts \\ []), to: Barkpark.Search.MediaIntelligence

  defdelegate suggestions(scope, actor, prefix \\ nil, opts \\ []),
    to: Barkpark.Search.MediaIntelligence

  defdelegate insights(scope, opts \\ []), to: Barkpark.Search.MediaIntelligence
end
