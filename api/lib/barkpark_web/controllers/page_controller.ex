defmodule BarkparkWeb.PageController do
  use BarkparkWeb, :controller

  def redirect_to_studio(conn, _params) do
    # The bare-Studio landing dataset. Resolved through Content so the Default
    # scope's dataset is a single source of truth, not a scattered "production"
    # literal (Task barkpark-k86v). Re-scoping the URL under /w/:ws/p/:project
    # is the sibling task barkpark-4tuu.
    redirect(conn, to: "/studio/#{Barkpark.Content.default_dataset()}")
  end
end
