defmodule BarkparkWeb.SelfUpdateController do
  @moduledoc """
  Admin-only trigger + status for the instance self-update executor
  (`/v1/admin/self-update`, backed by `Barkpark.SelfUpdate.Runner`).

  Routes are pipelined through `:api` + `:require_admin`, so a non-admin
  caller receives 403 and an un-authenticated caller 401. POST answers 503
  `feature_not_configured` unless the box opted in (fail-closed —
  `BARKPARK_SELF_UPDATE_APPLY=1`), 409 `already_running` while a run is in
  flight, else 202 with the fresh runner status. GET returns the runner
  status plus the captured log tail. The configured command is NEVER
  exposed in any response — only its output lines are.
  """

  use BarkparkWeb, :controller

  alias Barkpark.SelfUpdate.Runner

  def trigger(conn, _params) do
    case Runner.trigger() do
      {:ok, :started} ->
        conn
        |> put_status(:accepted)
        |> json(%{ok: true, status: render_status(Runner.status())})

      {:error, :already_running} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: %{code: "already_running", message: "an update is already running"}})

      {:error, :disabled} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          error: %{
            code: "feature_not_configured",
            message:
              "self-update apply is not enabled on this instance " <>
                "(set BARKPARK_SELF_UPDATE_APPLY=1)"
          }
        })

      {:error, :start_failed} ->
        # Distinct from :disabled — the feature IS enabled but the runner
        # could not spawn (missing executable, bad cd). Telling the admin to
        # flip an env var that is already set would be actively wrong.
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: %{
            code: "runner_start_failed",
            message: "self-update runner failed to start — check the server logs"
          }
        })
    end
  end

  def status(conn, _params) do
    json(conn, render_status(Runner.status()))
  end

  # Whitelist-render: state/exit_code/log/timestamps only — never the command.
  defp render_status(status) do
    %{
      state: Atom.to_string(status.state),
      exit_code: status.exit_code,
      log: status.log,
      started_at: iso(status.started_at),
      finished_at: iso(status.finished_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
