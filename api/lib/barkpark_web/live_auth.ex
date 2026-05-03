defmodule BarkparkWeb.LiveAuth do
  @moduledoc """
  `on_mount` hooks for LiveView auth.

  ## Hooks

    * `:admin` — requires the `"admin"` permission. Used by `/studio/settings`
      and any LiveView that exposes plugin-secret reveal/audit, schema CRUD,
      or other privileged surfaces.

    * `:ops` — requires the `"ops"` *or* `"admin"` permission (Phase 8 WI5).
      Used by the `/admin/bokbasen` operations console. Admin tokens
      retain ops capabilities; this is purely an *additive* role so a
      future operator persona can be granted publish-ops access without
      exposing the full admin surface (settings reveal, schema CRUD).

  Both hooks read `session["api_token"]` (the raw bearer token), verify it
  via `Barkpark.Auth`, and halt with a redirect to `/studio` on failure.

  Tests inject the session token with `Plug.Test.init_test_session/2`.
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  alias Barkpark.Auth

  def on_mount(:admin, _params, session, socket) do
    authorize(socket, session, ["admin"], "Admin access required")
  end

  def on_mount(:ops, _params, session, socket) do
    authorize(socket, session, ["ops", "admin"], "Operator access required")
  end

  defp authorize(socket, session, allowed_perms, denial_flash) do
    raw = session["api_token"]

    with token when is_binary(token) <- raw,
         {:ok, api_token} <- Auth.verify_token(token),
         true <- Enum.any?(allowed_perms, &Auth.has_permission?(api_token, &1)) do
      {:cont, assign(socket, :api_token, api_token)}
    else
      _ ->
        {:halt,
         socket
         |> put_flash(:error, denial_flash)
         |> redirect(to: "/studio")}
    end
  end
end
