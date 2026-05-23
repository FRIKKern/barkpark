defmodule BarkparkWeb.PaperIngestController do
  @moduledoc """
  Ingest endpoint for paperflow papers (convergence MVP, masterplan Figure 6).

  Matches the request the `paperflow/hooks/event-on-save.sh` mirror block
  POSTs:

      POST /v1/paperflow/papers
      Authorization: Bearer <BARKPARK_INGEST_TOKEN>   (RequireIngestToken plug)
      Content-Type: application/json
      {
        "source_doc": "plans/2026-05-23-foo.html",
        "slug":       "2026-05-23-foo",
        "event_type": "plan-written",
        "body_html":  "<article>…</article>",
        "goal_id":    "bd-a1b2"        // optional
      }

  Upserts the paper keyed by slug and broadcasts on its per-doc PubSub topic
  so any mounted `PaperLive` re-renders with no reload. Persists so a fresh
  mount renders the latest HTML.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Papers

  def ingest(conn, %{"slug" => slug, "body_html" => body_html} = params)
      when is_binary(slug) and slug != "" and is_binary(body_html) do
    attrs = %{
      "slug" => slug,
      "body_html" => body_html,
      "source_doc" => params["source_doc"],
      "event_type" => params["event_type"],
      "goal_id" => params["goal_id"]
    }

    case Papers.upsert_paper(attrs) do
      {:ok, paper} ->
        conn
        |> put_status(:ok)
        |> json(%{
          ok: true,
          slug: paper.slug,
          rev: paper.rev,
          liveview_path: "/papers/#{paper.slug}"
        })

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_paper", message: "could not store paper"}})
    end
  end

  def ingest(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "malformed", message: "slug and body_html are required"}})
  end
end
