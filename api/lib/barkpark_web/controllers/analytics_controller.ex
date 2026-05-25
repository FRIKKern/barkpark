defmodule BarkparkWeb.AnalyticsController do
  use BarkparkWeb, :controller

  alias Barkpark.Content

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  def index(conn, %{"dataset" => dataset}) do
    scope = scope_opts(conn)
    types = Content.document_stats(dataset, scope)
    total = Content.total_documents(dataset, scope)
    activity = Content.recent_activity(dataset, scope)

    json(conn, %{
      dataset: dataset,
      total_documents: total,
      types: types,
      recent_activity: activity
    })
  end
end
