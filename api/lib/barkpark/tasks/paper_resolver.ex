defmodule Barkpark.Tasks.PaperResolver do
  @moduledoc """
  The Tasks plugin's paper task resolver (task-9c59aa555e1e015e): what
  `Barkpark.Content.Papers` reads, through `Barkpark.Content.PaperTaskResolver`,
  to render a task chip's criteria segment and a task query block's rows and
  aggregates. Declared by `Barkpark.Plugins.Tasks.paper_task_resolver/0`.

  Pure delegation — the semantics stay owned where they were: the `{met,
  total}` count by `Barkpark.Tasks.Criteria` (via `Barkpark.Tasks`), rows and
  aggregates by `Barkpark.Tasks.Query` (tenancy fail-closed).
  """
  @behaviour Barkpark.Content.PaperTaskResolver

  @impl true
  defdelegate criteria_progress(content), to: Barkpark.Tasks

  @impl true
  defdelegate rows_for_query(query, scope, opts), to: Barkpark.Tasks.Query

  @impl true
  defdelegate agg_for_query(query, scope, opts), to: Barkpark.Tasks.Query
end
