defmodule SanityApiWeb.PageController do
  use SanityApiWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: "/studio")
  end
end
