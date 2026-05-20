defmodule BarkparkWeb.AdminLegacyRedirectController do
  @moduledoc """
  Back-compat 301 redirects from legacy `/admin/*` URLs that moved into
  plugin namespaces during the Goal `barkpark-G3` plugin-highway pass.

  One action per legacy URL — each emits a `301 Moved Permanently` to
  the new path. Per the Q3 grill decision: external systems that
  bookmarked the old URL keep working without touching their links.

  ## Routes covered

  | Legacy URL          | New URL                       | Why moved                       |
  |---------------------|-------------------------------|---------------------------------|
  | `/admin/bokbasen`   | `/admin/onixedit/bokbasen`    | OnixEdit plugin owns this LV    |

  Staleness (`/admin/onixedit/staleness`) is NOT here because its URL
  is preserved exactly by the plugin mount — same path, different host
  (plugin namespace instead of host `BarkparkWeb.Admin`).
  """
  use BarkparkWeb, :controller

  def bokbasen(conn, _params) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: "/admin/onixedit/bokbasen")
  end
end
