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
      `invalid_mode` / `invalid_env` / `invalid_artifact` /
      `invalid_artifact_digest` / `artifact_too_large` — nothing reaches argv or
      the child's env until `Barkpark.Sites.DeployRequest` has validated it.
    * **400** `E_DIGEST_MISMATCH` / `E_NOT_GZIP` / `E_NOT_BASE64` /
      `E_MALFORMED` / `E_PATH_TRAVERSAL` / `E_ABSOLUTE_PATH` / `E_SYMLINK` /
      `E_HARDLINK` / `E_SPECIAL_FILE` / `E_UNKNOWN_TYPE` / `E_MODE_BITS` /
      `E_BAD_NAME` / `E_UNSAFE_PARENT` / `E_ENTRY_TOO_LARGE` /
      `E_TOTAL_TOO_LARGE` / `E_COMPRESSION_RATIO` / `E_TOO_MANY_ENTRIES` /
      `E_NO_INDEX` — the 18 typed refusals a PREBUILT artifact can draw from the
      box (`Barkpark.Sites.PrebuiltArtifact`). These are 400s, not 500s: the
      bytes are the caller's, and the box never falls back to building the site
      itself when it refuses them. `E_MALFORMED` covers framing as well as
      corruption — a stream with no end-of-archive marker, or a gzip member that
      never terminates, is a truncated upload; `E_NO_INDEX` is the archive that
      arrived WHOLE and still has nothing to serve.
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
        |> json(
          Map.merge(
            %{ok: true, status: render_status(DeployRunner.status(req.slug))},
            prebuilt_echo(req)
          )
        )

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

      {:error, {:artifact_rejected, code, message}} ->
        # The box REFUSED the caller's prebuilt bytes. 400 with the extractor's
        # own typed code — the control plane must be able to tell "your tarball
        # has a symlink in it" from "the box is broken", and must never read a
        # refusal as a licence to let the box build the site instead.
        bad_request(conn, code, message)

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

  `build_id` is a first-class match key (charter D34). BoxRelay already sends
  the build_id it is polling for; when it is present AND non-empty AND does not
  match the run currently served for that slug (which includes the idle case,
  where the run's build_id is `nil`), this responds **404**. The control plane
  treats 404 as keep-waiting, so a superseded run — or one that has not started
  yet — times out honestly instead of silently adopting another same-slug run's
  stages and its eventual success. An empty (`""`, rollback await-flip) or
  absent (legacy caller) build_id falls back to slug-only match — backward
  compatible. The decision is `resolve_status_match/2`, a pure function.
  """
  def status(conn, params) do
    case DeployRequest.validate_slug(Map.get(params, "slug")) do
      {:ok, slug} ->
        status = DeployRunner.status(slug)
        requested_build_id = Map.get(params, "build_id")

        case resolve_status_match(status, requested_build_id) do
          :serve -> json(conn, render_status(status))
          :not_found -> build_id_mismatch(conn, slug, requested_build_id)
        end

      {:error, code, message} ->
        bad_request(conn, code, message)
    end
  end

  @doc """
  Decide whether a served status matches the polled `build_id` — pure, so it is
  unit-testable with no GenServer or filesystem. `:serve` means the slug-only or
  build_id-matched run is the one the caller wants; `:not_found` means the caller
  is polling for a build that this slug is not currently serving.

    * absent (`nil`) or empty (`""`) requested build_id → `:serve` (slug-only,
      backward compatible: legacy callers and rollback await-flip)
    * non-empty and equal to the run's build_id → `:serve`
    * non-empty and different (including idle, where the run build_id is `nil`)
      → `:not_found`
  """
  @spec resolve_status_match(map(), String.t() | nil) :: :serve | :not_found
  def resolve_status_match(status_payload, requested_build_id) do
    case requested_build_id do
      nil -> :serve
      "" -> :serve
      id when is_binary(id) -> if id == status_payload.build_id, do: :serve, else: :not_found
      _ -> :serve
    end
  end

  # The 202 says WHICH KIND of deploy started. A prebuilt run echoes the digest
  # the box actually verified — not the one the caller sent, though a mismatch
  # never reaches here — so the control plane can record what it deployed
  # instead of assuming. A box build carries NEITHER key: an absent field is an
  # honest "this was built here", where `prebuilt: false` would invite a caller
  # to read a pre-upgrade box's silence as a considered answer.
  defp prebuilt_echo(%DeployRequest{} = req) do
    if DeployRequest.prebuilt?(req) do
      %{prebuilt: true, artifact_sha256: req.artifact_sha256}
    else
      %{}
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

  # The polled build_id is not the run this slug is currently serving — it was
  # superseded by a newer same-slug build, or has not started yet. 404 (not 200)
  # so the control plane keeps waiting instead of adopting the wrong run's stages.
  defp build_id_mismatch(conn, slug, build_id) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: %{
        code: "build_id_mismatch",
        message:
          "no run for site '#{slug}' matches build_id '#{build_id}' — " <>
            "it was superseded by a newer build or has not started yet"
      }
    })
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
