defmodule BarkparkWeb.PageController do
  use BarkparkWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: "/studio")
  end
end
