defmodule BarkparkWeb.SiteDeployController do
  @moduledoc """
  Admin-only trigger + status for a content-bound STATIC site deploy
  (`/v1/admin/site-deploy`, backed by `Barkpark.Sites.DeployRunner`).

  This is the remote-exec seam (charter D22): the control plane already knows
  how to make an authenticated admin POST to an instance's own API with the
  per-instance Vault-stored admin token — that is exactly how self-update runs
  today — so a site deploy rides the SAME door. No SSH, no agent channel, no
  new auth: the routes sit in the existing `/v1/admin` scope
  (`pipe_through [:api, :require_admin]`), so an un-authenticated caller gets
  401 and a non-admin 403 before this module is ever reached.

  Status contract, mirroring `SelfUpdateController`:

    * **503** `feature_not_configured` — the box has not opted in
      (`BARKPARK_SITE_DEPLOY_APPLY=1`). Fail-closed default.
    * **400** `invalid_slug` / `invalid_build_id` / `invalid_content_rev` /
      `invalid_mode` / `invalid_env` — nothing reaches argv or the child's env
      until `Barkpark.Sites.DeployRequest` has validated it.
    * **409** `already_running` — a run for THAT SLUG is in flight. A different
      slug (or an unrelated self-update) never collides.
    * **202** `started` — with the fresh run status.
    * **500** `runner_start_failed` — the feature IS enabled but the command
      could not spawn (missing script, bad cd). Distinct from 503: telling an
      admin to set an env var they already set would be actively wrong.

  `GET /v1/admin/site-deploy?slug=<slug>` returns the run status for one slug:
  state, the six parsed `stages` (retained separately from the log ring, so a
  900-line `npm ci` cannot evict PLAN/BUILD), `exit_code`, an honest
  `failure_reason` carrying the real lines from the child's stream, and the
  bounded log tail. The configured command is never exposed — only its output.
  """

  use BarkparkWeb, :controller

  alias Barkpark.Sites.DeployRequest
  alias Barkpark.Sites.DeployRunner

  @doc """
  Start a site deploy (`mode: "deploy"`, the default) or an instant rollback
  (`mode: "rollback"` — a symlink repoint, no rebuild) for one slug.
  """
  def trigger(conn, params) do
    # Fail-closed FIRST: a box that cannot execute site deploys says so before
    # it says anything about the shape of the request.
    if DeployRunner.enabled?() do
      do_trigger(conn, params)
    else
      feature_not_configured(conn)
    end
  end

  defp do_trigger(conn, params) do
    case DeployRequest.new(params) do
      {:ok, req} -> start(conn, req)
      {:error, code, message} -> bad_request(conn, code, message)
    end
  end

  defp start(conn, %DeployRequest{} = req) do
    case DeployRunner.trigger(req) do
      {:ok, :started} ->
        conn
        |> put_status(:accepted)
        |> json(%{
          ok: true,
          status: render_status(DeployRunner.status(req.slug))
        })

      {:error, :already_running} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          error: %{
            code: "already_running",
            message: "a deploy for site '#{req.slug}' is already running"
          }
        })

      {:error, :disabled} ->
        # The apply flag flipped off (or the Runner died) between the guard and
        # the call — still fail-closed.
        feature_not_configured(conn)

      {:error, :start_failed} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{
          error: %{
            code: "runner_start_failed",
            message: "site-deploy runner failed to start — check the server logs"
          }
        })
    end
  end

  @doc """
  The run status for one slug (`?slug=<slug>`). A slug that has never deployed
  reports `state: "idle"` — an honest empty state, not a 404.
  """
  def status(conn, params) do
    case DeployRequest.validate_slug(Map.get(params, "slug")) do
      {:ok, slug} ->
        json(conn, render_status(DeployRunner.status(slug)))

      {:error, code, message} ->
        bad_request(conn, code, message)
    end
  end

  defp feature_not_configured(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: %{
        code: "feature_not_configured",
        message:
          "site deploys are not enabled on this instance " <>
            "(set BARKPARK_SITE_DEPLOY_APPLY=1)"
      }
    })
  end

  defp bad_request(conn, code, message) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: code, message: message}})
  end

  # Whitelist-render: the runner's status map, JSON-shaped (atoms → strings,
  # DateTime → ISO8601). Never the command.
  defp render_status(status) do
    %{
      state: Atom.to_string(status.state),
      slug: status.slug,
      build_id: status.build_id,
      content_rev: status.content_rev,
      mode: atom_or_nil(status.mode),
      stages: Enum.map(status.stages, &render_stage/1),
      exit_code: status.exit_code,
      failure_reason: status.failure_reason,
      log: status.log,
      started_at: iso(status.started_at),
      finished_at: iso(status.finished_at)
    }
  end

  # `detail` is the failed stage's REAL reason (npm's 401, HEALTH's marker miss).
  # The control plane reads it straight off this key and `bp cloud site` prints
  # it; omitting it degrades every failure to a canned line, silently.
  defp render_stage(stage) do
    %{
      name: stage.name,
      status: stage.status,
      build_id: stage.build_id,
      detail: Map.get(stage, :detail),
      at: iso(stage.at)
    }
  end

  defp atom_or_nil(nil), do: nil
  defp atom_or_nil(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
