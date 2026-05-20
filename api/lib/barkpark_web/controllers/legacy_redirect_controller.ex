defmodule BarkparkWeb.LegacyRedirectController do
  @moduledoc """
  Back-compat 301 redirects from URLs that moved during the plugin-highway
  umbrella (G1–G4). Host-namespaced + plugin-agnostic — each action emits
  a `301 Moved Permanently` to the new path so external bookmarks keep
  working without touching their links.

  Adding a new redirect: add one named action per legacy URL, give it a
  short docstring naming the source Goal + the reason, and register the
  route in `router.ex`.

  ## Routes covered

  | Action            | Legacy URL                                       | New URL                                | Why moved (Goal)                                              |
  |-------------------|--------------------------------------------------|----------------------------------------|---------------------------------------------------------------|
  | `bokbasen`        | `/admin/bokbasen`                                | `/admin/onixedit/bokbasen`             | LV moved into plugin namespace (G3.s4)                        |
  | `onixedit_book`   | `/studio/:dataset/onixedit/book/:doc_id`         | `/studio/:dataset/book/:doc_id`        | Dedicated book LVs removed; native StudioLive (barkpark-zdy)  |
  | `onixedit_book`   | `/studio/:dataset/onixedit/book/:doc_id/view`    | `/studio/:dataset/book/:doc_id`        | same as above                                                 |

  Query strings on the source URL are preserved through the redirect so
  deep links keep their `?tab=…` state.
  """
  use BarkparkWeb, :controller

  def bokbasen(conn, _params) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: "/admin/onixedit/bokbasen")
  end

  def onixedit_book(conn, %{"doc_id" => doc_id} = params) do
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
