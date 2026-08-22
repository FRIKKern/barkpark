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
        already_running(conn)

      {:error, :disabled} ->
        feature_not_configured(conn)

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

  @doc """
  Trigger an instance rollback to the idle blue/green slot's recorded sha.

  Fail-closed on the SAME `BARKPARK_SELF_UPDATE_APPLY` gate as self-update
  (503 `feature_not_configured`). The rollback preflight is run SYNCHRONOUSLY
  and read-only so the control plane learns the target sha before anything
  mutates and gets a typed refusal on a bad box; only on a clear preflight is
  the mutating `--rollback` spawned as an async `Port`, sharing the Runner's
  single run slot with self-update. Typed refusals: 409 `no_previous_slot`
  (no idle slot to return to), 409 `not_supported` (box has no `.slots`
  machinery), 409 `already_running` (a run is in flight either direction),
  500 `rollback_preflight_failed` (preflight could not clear it → FAIL CLOSED,
  never flip to garbage). Success answers 202 `{status:"started",target_sha}`.
  """
  def rollback(conn, _params) do
    cond do
      not Runner.enabled?() ->
        feature_not_configured(conn)

      # Shared single-flight: refuse a colliding rollback before spending a
      # preflight subprocess. The GenServer trigger stays the authoritative
      # gate for the check→spawn race.
      Runner.running?() ->
        already_running(conn)

      true ->
        do_rollback(conn)
    end
  end

  defp do_rollback(conn) do
    case Runner.preflight_rollback() do
      {:ok, target_sha} ->
        start_rollback(conn, target_sha)

      {:error, :no_previous_slot} ->
        conflict(conn, "no_previous_slot", "no previous slot to roll back to")

      {:error, :not_supported} ->
        conflict(conn, "not_supported", "rollback is not supported on this instance")

      {:error, :already_running} ->
        already_running(conn)

      {:error, {:preflight_failed, _reason}} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: %{
            code: "rollback_preflight_failed",
            message:
              "rollback preflight could not determine a safe target — check the server logs"
          }
        })
    end
  end

  defp start_rollback(conn, target_sha) do
    case Runner.trigger_rollback() do
      {:ok, :started} ->
        conn
        |> put_status(:accepted)
        |> json(%{status: "started", target_sha: target_sha})

      # A self-update/rollback slipped in between preflight and the spawn.
      {:error, :already_running} ->
        already_running(conn)

      {:error, :disabled} ->
        feature_not_configured(conn)

      {:error, :start_failed} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: %{
            code: "runner_start_failed",
            message: "rollback runner failed to start — check the server logs"
          }
        })
    end
  end

  def status(conn, _params) do
    # `check` is the CHECKER's view (is an update available?) riding along
    # with the runner state — one admin GET gives a control plane everything:
    # Barkpark Cloud polls this to light up its per-instance update badge.
    #
    # `apply_enabled` is the NON-DESTRUCTIVE ARMING PROBE. `state` describes the
    # RUN and reads "idle" identically whether or not one-click apply is armed,
    # so before this key the only way to learn a box was unarmed was to POST —
    # and that POST's 503 `feature_not_configured` is what the control plane's
    # AutoupdateRolloutWorker answers with `Registry.pause_autoupdate/1`, a pause
    # NO code path clears (the sole writer of `autoupdate_paused: false` is the
    # admin-and-audited PATCH /v1/barkparks/:id/autoupdate). The only probe was
    # the one that breaks the thing it measures.
    #
    # It reports `Runner.enabled?/0` — the RUNNING BEAM's boot-frozen
    # `Application.get_env` value, which is the exact input the 503 is decided
    # from. A box whose env file gained BARKPARK_SELF_UPDATE_APPLY=1 but was
    # never restarted still reads false here, and that is correct: the env file
    # is not the running truth, and confusing the two is what makes a box look
    # armed while it 503s.
    conn
    |> json(
      Runner.status()
      |> render_status()
      |> Map.put(:apply_enabled, Runner.enabled?())
      |> Map.put(:check, render_check(Barkpark.SelfUpdate.status()))
    )
  end

  # Shared typed-error responses (self-update + rollback speak the same
  # vocabulary — charter W6 D23).
  defp already_running(conn) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{code: "already_running", message: "an update is already running"}})
  end

  defp conflict(conn, code, message) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{code: code, message: message}})
  end

  defp feature_not_configured(conn) do
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
  end

  # Whitelist-render: state/mode/exit_code/log/timestamps only — never the
  # command. `mode` (self_update | rollback) tells a surface which verb the
  # current/last run is.
  defp render_status(status) do
    %{
      state: Atom.to_string(status.state),
      mode: Atom.to_string(status.mode),
      exit_code: status.exit_code,
      log: status.log,
      started_at: iso(status.started_at),
      finished_at: iso(status.finished_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  # The checker status map, JSON-shaped (atoms → strings, DateTime → ISO).
  defp render_check(status) do
    %{
      state: Atom.to_string(status.state),
      running_version: status.running_version,
      running_release: status.running_release,
      latest_release: status.latest_release,
      canonical_release: status.canonical_release,
      digest: status.digest,
      notes_body: Map.get(status, :notes_body),
      notes_url: Map.get(status, :notes_url),
      checked_at: iso(status.checked_at)
    }
  end
end
