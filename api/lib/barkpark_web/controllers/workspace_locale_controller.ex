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

  Both carry the workspace's time zone too (task-ecaaa898e346dc73):
  `time_zone`, an IANA name such as `"Europe/Oslo"`, or nil when unset. A
  list preview's `|date` shows a date-time as its day in that zone in both
  Studios. `PATCH /w/:ws/p/:proj/v1/workspace/time-zone` sets it, admin-gated
  like the locale: `{"time_zone": "Europe/Oslo"}`, null clears it, and `422
  invalid_time_zone` answers a name not shaped like an IANA zone.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy
  alias BarkparkWeb.ErrorResponse

  def show(conn, _params) do
    case conn.assigns[:current_workspace] do
      %{} = workspace ->
        json(conn, %{
          locale: Tenancy.workspace_locale(workspace),
          known_locales: Tenancy.known_locales(),
          time_zone: Tenancy.workspace_time_zone(workspace)
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
          json(conn, settings_body(workspace))

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

  def update_time_zone(conn, params) do
    with {:ws, %{id: ws_id}} <- {:ws, conn.assigns[:current_workspace]},
         {:zone, true} <- {:zone, Map.has_key?(params, "time_zone")} do
      case Tenancy.set_workspace_time_zone(ws_id, params["time_zone"]) do
        {:ok, workspace} ->
          json(conn, settings_body(workspace))

        {:error, :invalid_time_zone} ->
          invalid_time_zone(conn)

        {:error, :not_found} ->
          ErrorResponse.emit_custom(conn, 404, "not_found", "workspace not found")

        {:error, _changeset} ->
          ErrorResponse.emit_custom(
            conn,
            422,
            "invalid",
            "could not save the workspace time zone"
          )
      end
    else
      {:ws, _} ->
        ErrorResponse.emit_custom(conn, 404, "not_found", "no workspace resolved for this route")

      {:zone, _} ->
        invalid_time_zone(conn)
    end
  end

  defp invalid_time_zone(conn) do
    ErrorResponse.emit_custom(
      conn,
      422,
      "invalid_time_zone",
      "time_zone must be an IANA zone name such as \"Europe/Oslo\", or null to clear it"
    )
  end

  defp settings_body(workspace) do
    %{
      workspace: workspace.slug,
      locale: Tenancy.workspace_locale(workspace),
      known_locales: Tenancy.known_locales(),
      time_zone: Tenancy.workspace_time_zone(workspace)
    }
  end
end
