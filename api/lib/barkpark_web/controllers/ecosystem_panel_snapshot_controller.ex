defmodule BarkparkWeb.EcosystemPanelSnapshotController do
  @moduledoc """
  `POST /w/:ws/p/:proj/v1/plugins/ecosystem-panel/snapshot` — the ecosystem
  panel upload (task-270112c682dc71de). Mounted by the
  `Barkpark.Plugins.EcosystemPanel` plugin on the `:api` bucket.

  Body: `{"html": "<built page>", "built_at": "<ISO 8601 time>"}`.

  ## Who may write

  The scoped mount pipes through `[:scoped_api, :scoped_admin]`, so by the time
  `create/2` runs: the URL workspace is resolved (`ResolveWorkspace`, which
  also refuses non-members), a token is present (`RequireToken`), and its seat
  in that workspace is owner or admin (`RequireWorkspaceRole`). This
  controller adds one more check, `Tenancy.Auth.authorize/3` with `:admin`:
  the token's own permissions must include `admin` and, for a user-owned
  token, the owner's seat must allow it too. A read-only token that somehow
  sits on an admin seat is refused.

  ## Which row

  The row is keyed by `conn.assigns.current_workspace.id`, the workspace the
  URL slug resolved to. A `workspace_id` in the body or query is ignored.

  ## The flat copy

  The plugin bucket also mounts `/v1/plugins/ecosystem-panel/snapshot` with no
  workspace in the path. That copy answers 404 and writes nothing.

  ## Answers

    * 200 `{"sha256", "bytes", "built_at", "received_at"}` — never the HTML.
    * 413 `payload_too_large` — HTML over 2 MB.
    * 422 `built_at_in_future` — `built_at` more than 10 minutes ahead.
    * 422 `invalid_snapshot` — `html` missing or empty, or `built_at` not an
      ISO 8601 time.
  """
  use BarkparkWeb, :controller

  alias Barkpark.EcosystemPanel
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.ErrorResponse

  def create(%Plug.Conn{path_params: %{"workspace_slug" => _}} = conn, params) do
    with {:ok, workspace_id} <- url_workspace_id(conn),
         :ok <- TenancyAuth.authorize(conn.assigns[:api_token], workspace_id, :admin),
         {:ok, html, built_at} <- parse_snapshot(params),
         {:ok, snapshot} <- EcosystemPanel.put(workspace_id, html, built_at) do
      json(conn, %{
        sha256: snapshot.sha256,
        bytes: snapshot.bytes,
        built_at: DateTime.to_iso8601(snapshot.built_at),
        received_at: DateTime.to_iso8601(snapshot.received_at)
      })
    else
      {:error, :forbidden} -> ErrorResponse.emit(conn, {:error, :forbidden})
      {:error, :too_large} -> too_large(conn)
      {:error, :built_at_in_future} -> future(conn)
      {:error, _invalid} -> invalid(conn)
    end
  end

  # No workspace in the path: the flat mount. Nothing is written.
  def create(conn, _params), do: ErrorResponse.emit(conn, {:error, :not_found})

  defp url_workspace_id(conn) do
    case conn.assigns[:current_workspace] do
      %{id: id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :forbidden}
    end
  end

  defp parse_snapshot(%{"html" => html, "built_at" => built_at})
       when is_binary(html) and html != "" and is_binary(built_at) do
    case DateTime.from_iso8601(built_at) do
      {:ok, dt, _offset} -> {:ok, html, dt}
      {:error, _} -> {:error, :invalid}
    end
  end

  defp parse_snapshot(_params), do: {:error, :invalid}

  defp too_large(conn) do
    ErrorResponse.emit_custom(
      conn,
      413,
      "payload_too_large",
      "The snapshot is larger than 2 MB. Nothing was saved.",
      %{max_bytes: EcosystemPanel.max_bytes()}
    )
  end

  defp future(conn) do
    ErrorResponse.emit_custom(
      conn,
      422,
      "built_at_in_future",
      "built_at is more than 10 minutes ahead of the server clock. Check the clock " <>
        "on the machine that built the page. Nothing was saved.",
      %{max_future_seconds: EcosystemPanel.max_future_seconds()}
    )
  end

  defp invalid(conn) do
    ErrorResponse.emit_custom(
      conn,
      422,
      "invalid_snapshot",
      "Send a JSON body with a non-empty html string and an ISO 8601 built_at. " <>
        "Nothing was saved."
    )
  end
end
