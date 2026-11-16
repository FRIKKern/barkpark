defmodule BarkparkWeb.AuditController do
  @moduledoc """
  `GET /w/:ws/p/:proj/v1/audit` — the workspace's audit log, newest first, for
  its admins. `bp audit ls` lands here.

  ## Who may read

  The route is mounted only under the workspace path, on
  `[:scoped_api, :scoped_admin]`: the URL workspace is resolved (non-members
  are refused there), a token is present, and its seat in that workspace is
  owner or admin (`RequireWorkspaceRole`). This action also requires
  `Tenancy.Auth.authorize/3` with `:admin`, so a read-only token on an admin
  seat is refused, and a global `admin` permission without a seat here is
  refused by the plug. There is no flat `/v1/audit`: a flat path names no
  workspace.

  ## What it answers

  `Barkpark.Audit.Feed.list/3` for the URL workspace and project: rows of this
  project or of no project, never another project's, another workspace's or
  an instance-level row. Each row carries only the fields that module
  documents; `metadata` is never sent.

  Query: `category`, `actor`, `since`, `until`, `limit` (capped at 200, never
  refused for size) and `cursor`. A cursor is the `next_cursor` of an earlier
  page, encrypted and bound to this workspace and project, so a cursor from
  another workspace or a made-up one answers 422 `invalid_filter`.

  200 `{"events": [...], "next_cursor": "..." | null, "limit": n}`.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Audit.Feed
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.ErrorResponse

  @cursor_salt "audit feed cursor"
  @cursor_max_age 7 * 86_400

  def index(%Plug.Conn{path_params: %{"workspace_slug" => _}} = conn, params) do
    with {:ok, ws_id, proj_id} <- url_scope(conn),
         :ok <- TenancyAuth.authorize(conn.assigns[:api_token], ws_id, :admin),
         {:ok, filters} <- Feed.parse(params),
         {:ok, filters} <- cursor(params["cursor"], ws_id, proj_id, filters) do
      page = Feed.list(ws_id, proj_id, filters)

      json(conn, %{
        events: page.events,
        next_cursor: page.next_before_id && encode_cursor(ws_id, proj_id, page.next_before_id),
        limit: page.limit
      })
    else
      {:error, {:invalid, field}} -> invalid(conn, field)
      _forbidden -> ErrorResponse.emit(conn, {:error, :forbidden})
    end
  end

  # No workspace in the path. Nothing mounts this today; refuse rather than
  # read the stamped Default workspace.
  def index(conn, _params), do: ErrorResponse.emit(conn, {:error, :not_found})

  defp url_scope(conn) do
    case conn.assigns do
      %{current_workspace: %{id: ws}, current_project: %{id: proj}}
      when is_binary(ws) and is_binary(proj) ->
        {:ok, ws, proj}

      _ ->
        {:error, :forbidden}
    end
  end

  defp cursor(nil, _ws, _proj, filters), do: {:ok, filters}
  defp cursor("", _ws, _proj, filters), do: {:ok, filters}

  defp cursor(token, ws, proj, filters) when is_binary(token) do
    case Phoenix.Token.decrypt(BarkparkWeb.Endpoint, @cursor_salt, token,
           max_age: @cursor_max_age
         ) do
      {:ok, {^ws, ^proj, id}} when is_integer(id) -> {:ok, Map.put(filters, :before_id, id)}
      _ -> {:error, {:invalid, "cursor"}}
    end
  end

  defp cursor(_token, _ws, _proj, _filters), do: {:error, {:invalid, "cursor"}}

  defp encode_cursor(ws, proj, id),
    do: Phoenix.Token.encrypt(BarkparkWeb.Endpoint, @cursor_salt, {ws, proj, id})

  defp invalid(conn, field) do
    ErrorResponse.emit_custom(
      conn,
      422,
      "invalid_filter",
      invalid_message(field),
      %{field: field}
    )
  end

  defp invalid_message("category"),
    do: "category must be one of: " <> Enum.join(Barkpark.Audit.Event.categories(), ", ") <> "."

  defp invalid_message("limit"), do: "limit must be a whole number above 0."

  defp invalid_message("cursor"),
    do:
      "This cursor is not from this workspace's audit log, or it is too old. Start again without it."

  defp invalid_message(field) when field in ["since", "until"],
    do: "#{field} must be a date (2026-11-16) or an ISO 8601 time."

  defp invalid_message(_field), do: "actor must be an actor id of 200 characters or fewer."
end
