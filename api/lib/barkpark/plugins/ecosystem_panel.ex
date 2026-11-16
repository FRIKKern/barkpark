defmodule Barkpark.Plugins.EcosystemPanel do
  @moduledoc """
  Ecosystem panel — thin plugin wiring for `Barkpark.EcosystemPanel`, the
  one-row-per-workspace snapshot store behind the eco-dash page (plan Paper
  `ecosystem-panel-behind-login`, goal task-0ec42207605b91fe).

  Core owns the machinery (the context, the table, the controller); the plugin
  owns the mounting, the tasks.ex / pulse.ex precedent.

  ## Routes

    * `POST /w/:ws/p/:proj/v1/plugins/ecosystem-panel/snapshot` — the upload
      (task-270112c682dc71de). `auth: :api`, so the scoped mount pipes through
      `[:scoped_api, :scoped_admin]`: RequireToken, then RequireWorkspaceRole
      (owner or admin seat in the URL workspace), then RefuseWhileHeld. The
      controller also requires `Tenancy.Auth.authorize/3` `:admin`, so a
      read-only token on an admin seat is refused too.

    * `GET /w/:ws/p/:proj/studio/ecosystem-panel/frame` — the stored page for
      the shell's iframe (task-d76b1c09fe303401). Default `:admin` bucket, so
      the scoped copy rides `:scoped_browser`. A controller gets no
      `on_mount`: `EcosystemPanelFrameController` checks
      `Tenancy.Auth.workspace_admin?/2` on every request and answers with a
      sandbox CSP.

  Each bucket also mounts a flat copy (`/v1/plugins/ecosystem-panel/snapshot`,
  `/studio/ecosystem-panel/frame`) with no workspace in the path. Both
  controllers answer that copy 404 and touch no row: acting on the stamped
  Default workspace there is the bug class `docs/auth.md` warns about.

  The shell route comes in a later task.

  `register_schemas/1` is `[]`: a snapshot is a row, not a document, so it
  keeps no revision history and never reaches search, webhooks or the desk.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/ecosystem_panel/plugin.json"

  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    [
      {:post, "/ecosystem-panel/snapshot", BarkparkWeb.EcosystemPanelSnapshotController, :create,
       auth: :api},
      {:get, "/ecosystem-panel/frame", BarkparkWeb.EcosystemPanelFrameController, :show}
    ]
  end
end
