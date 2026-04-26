defmodule BarkparkWeb.LiveAuth do
  @moduledoc """
  `on_mount` hooks for LiveView auth.

  ## :admin

  Reads `session["api_token"]` (the raw bearer token), verifies it via
  `Barkpark.Auth`, and requires the `"admin"` permission. Halts with a
  redirect to `/studio` on failure.

  Tests inject the session token with `Plug.Test.init_test_session/2`.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias Barkpark.Auth

  def on_mount(:admin, _params, session, socket) do
    raw = session["api_token"]

    with token when is_binary(token) <- raw,
         {:ok, api_token} <- Auth.verify_token(token),
         true <- Auth.has_permission?(api_token, "admin") do
      {:cont, assign(socket, :api_token, api_token)}
    else
      _ ->
        {:halt,
         socket
         |> put_flash(:error, "Admin access required")
         |> redirect(to: "/studio")}
    end
  end
end
