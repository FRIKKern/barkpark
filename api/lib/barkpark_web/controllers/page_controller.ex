defmodule BarkparkWeb.PageController do
  use BarkparkWeb, :controller

  def redirect_to_studio(conn, _params) do
    redirect(conn, to: "/studio/production")
  end
end
