defmodule BarkparkWeb.PageController do
  use BarkparkWeb, :controller

  def redirect_to_studio(conn, _params) do
    # P3 cutover (Scoped-by-URL): bare / and /studio land on the
    # session-resolved SCOPED Studio — workspace/project/dataset chosen by
    # the documented resolution rule (StudioRedirectController), visible in
    # the address bar instead of silently picked in-socket.
    case BarkparkWeb.StudioRedirectController.scoped_studio_target(conn, nil) do
      {:ok, target} -> redirect(conn, to: target)
      :error -> redirect(conn, to: "/login")
    end
  end
end
