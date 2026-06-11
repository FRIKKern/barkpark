defmodule Barkpark.Media.SearchAnalytics do
  @moduledoc """
  Deprecated — use `Barkpark.Media.SearchIntelligence`.

  Thin delegate kept for backward compatibility during the DAM → core migration.
  """

  defdelegate retention_days(), to: Barkpark.Media.SearchIntelligence
  defdelegate prune(opts \\ []), to: Barkpark.Media.SearchIntelligence
  defdelegate record(scope, params, total, ms, opts \\ []), to: Barkpark.Media.SearchIntelligence

  defdelegate suggestions(scope, actor, prefix \\ nil, opts \\ []),
    to: Barkpark.Media.SearchIntelligence

  defdelegate insights(scope, opts \\ []), to: Barkpark.Media.SearchIntelligence
end
