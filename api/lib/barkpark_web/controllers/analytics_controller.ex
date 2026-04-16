defmodule BarkparkWeb.AnalyticsController do
  use BarkparkWeb, :controller

  alias Barkpark.Content

  def index(conn, %{"dataset" => dataset}) do
    types = Content.document_stats(dataset)
    total = Content.total_documents(dataset)
    activity = Content.recent_activity(dataset)

    json(conn, %{
      dataset: dataset,
      total_documents: total,
      types: types,
      recent_activity: activity
    })
  end
end
