defmodule BarkparkWeb.WorkspaceLocaleController do
  @moduledoc """
  `PATCH /w/:ws/p/:proj/v1/workspace/locale` — set the Studio chrome locale of
  the resolved workspace (Gyldendal parity E7). Mounted under `:scoped_api` +
  `:scoped_admin`, so authority is the membership ROLE (`owner`/`admin`) in the
  workspace, never a token's global permissions — the same gate as the roster.

  Body: `{"locale": "nb-NO"}`. `422` for a missing or unknown locale (the
  known list rides in the error so the caller can pick), `404` when no
  workspace resolved.

  `GET /w/:ws/p/:proj/v1/workspace/locale` — read it back (task-9a82d5dc67e5b7e0).
  Mounted on the plain token-required scoped-read pipeline (`:scoped_api,
  :require_token`), not `:scoped_admin`: SETTING the chrome locale is an
  admin act, but READING it is not a secret — any member token needs it to
  pick the Studio's chrome language (`BarkparkWeb.StudioLocale`, which
  already reads the in-process equivalent via `Tenancy.workspace_locale/1`
  for LiveView; nothing external could read it over HTTP before this).
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy
  alias BarkparkWeb.ErrorResponse

  def show(conn, _params) do
    case conn.assigns[:current_workspace] do
      %{} = workspace ->
        json(conn, %{
          locale: Tenancy.workspace_locale(workspace),
          known_locales: Tenancy.known_locales()
        })

      _ ->
        ErrorResponse.emit_custom(conn, 404, "not_found", "no workspace resolved for this route")
    end
  end

  def update(conn, params) do
    with {:ws, %{id: ws_id}} <- {:ws, conn.assigns[:current_workspace]},
         {:locale, locale} when is_binary(locale) and locale != "" <-
           {:locale, params["locale"]} do
      case Tenancy.set_workspace_locale(ws_id, locale) do
        {:ok, workspace} ->
          json(conn, %{
            workspace: workspace.slug,
            locale: Tenancy.workspace_locale(workspace),
            known_locales: Tenancy.known_locales()
          })

        {:error, :unknown_locale} ->
          ErrorResponse.emit_custom(
            conn,
            422,
            "unknown_locale",
            "unknown locale #{inspect(locale)} — known: #{Enum.join(Tenancy.known_locales(), ", ")}"
          )

        {:error, :not_found} ->
          ErrorResponse.emit_custom(conn, 404, "not_found", "workspace not found")

        {:error, _changeset} ->
          ErrorResponse.emit_custom(conn, 422, "invalid", "could not save the workspace locale")
      end
    else
      {:ws, _} ->
        ErrorResponse.emit_custom(conn, 404, "not_found", "no workspace resolved for this route")

      {:locale, _} ->
        ErrorResponse.emit_custom(
          conn,
          422,
          "missing_locale",
          "locale is required — one of: #{Enum.join(Tenancy.known_locales(), ", ")}"
        )
    end
  end
end
