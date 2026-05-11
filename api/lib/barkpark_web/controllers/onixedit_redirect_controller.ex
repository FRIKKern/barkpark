defmodule BarkparkWeb.OnixeditRedirectController do
  @moduledoc """
  Back-compat redirect from the old plugin-owned book editor routes to the
  native StudioLive path. The dedicated `Plugins.OnixEdit.BookEditor` and
  `Plugins.OnixEdit.BookView` LiveViews were removed in Goal `barkpark-zdy`
  ("we cannot walk in the shoes of failed old design like OnixEdit — we
  will use our native features"). The `book` document type now opens in
  the native Studio document editor at `/studio/:dataset/book/:doc_id`.

  Handles both:

    GET /studio/:dataset/onixedit/book/:doc_id        → /studio/:dataset/book/:doc_id
    GET /studio/:dataset/onixedit/book/:doc_id/view   → /studio/:dataset/book/:doc_id

  Query strings (e.g. `?tab=subjects`) are preserved so deep links from
  external systems keep landing on the right tab inside StudioLive.
  """
  use BarkparkWeb, :controller

  def show(conn, %{"doc_id" => doc_id} = params) do
    dataset = params["dataset"] || "production"
    target = "/studio/#{dataset}/book/#{doc_id}"

    target =
      case conn.query_string do
        "" -> target
        nil -> target
        qs -> target <> "?" <> qs
      end

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: target)
  end
end
