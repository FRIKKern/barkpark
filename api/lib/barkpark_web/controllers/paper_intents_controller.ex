defmodule BarkparkWeb.PaperIntentsController do
  @moduledoc """
  Pending-intents API over `paper_events` — the Barkpark half of the
  loop-closer (P6.U6a, barkpark-jwai). The paperflow-side reader loop (U6b)
  polls these token-gated endpoints to drain the actionable intents that
  U4/U5 record into `paper_events`.

  Token-gated via the `:paperflow_ingest` pipeline (RequireIngestToken plug —
  shared-secret bearer, NOT the api_tokens table), same as the paper-ingest
  endpoint.

      GET /v1/paperflow/intents
      Authorization: Bearer <BARKPARK_INGEST_TOKEN>
      → 200 {"intents": [{id, event_type, goal_id, paper_slug, branch,
                          payload_html, inserted_at}, …]}

      POST /v1/paperflow/intents/:id/processed
      Authorization: Bearer <BARKPARK_INGEST_TOKEN>
      → 200 {"ok": true, "id": "<id>"}        marked processed
      → 404 {"ok": false, "error": "not_found"} no such event

  Only `action:*` / `simplify-*` events with a NULL `processed_at` are returned
  (see `Events.list_pending_intents/0`); lifecycle events never surface here.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Papers.Events

  @doc """
  Return the pending actionable intents, oldest first, as a JSON list.
  """
  def index(conn, _params) do
    intents = Enum.map(Events.list_pending_intents(), &intent_json/1)

    conn
    |> put_status(:ok)
    |> json(%{intents: intents})
  end

  @doc """
  Mark the intent at `:id` processed so it drops out of the pending list.
  200 `{ok: true, id}` on success; 404 `{ok: false, error: "not_found"}` for
  an unknown id.
  """
  def mark_processed(conn, %{"id" => id}) do
    case Events.mark_processed(id) do
      {:ok, event} ->
        conn
        |> put_status(:ok)
        |> json(%{ok: true, id: event.id})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{ok: false, error: "not_found"})
    end
  end

  defp intent_json(event) do
    %{
      id: event.id,
      event_type: event.event_type,
      goal_id: event.goal_id,
      paper_slug: event.paper_slug,
      branch: event.branch,
      payload_html: event.payload_html,
      inserted_at: event.inserted_at
    }
  end
end
