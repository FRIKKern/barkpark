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

    * `/w/:ws/p/:proj/studio/ecosystem-panel` — the shell LiveView
      (task-d599e49ba75bb30b), `Barkpark.Plugins.EcosystemPanel.PanelLive`.
      Default `:admin` bucket, so the scoped copy rides `live_session
      :scoped_plugin_admin` (`LiveAuth :scoped_admin`, then
      `:require_org_mfa`). It draws the age line and frames the route above.

  Each bucket also mounts a flat copy (`/v1/plugins/ecosystem-panel/snapshot`,
  `/studio/ecosystem-panel/frame`, `/studio/ecosystem-panel`) with no
  workspace in the path. Both controllers answer that copy 404, the shell
  redirects it to `/studio`, and none of them touches a row: acting on the
  stamped Default workspace there is the bug class `docs/auth.md` warns about.

  `register_schemas/1` is `[]`: a snapshot is a row, not a document, so it
  keeps no revision history and never reaches search, webhooks or the desk.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/ecosystem_panel/plugin.json"

  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    [
      {:post, "/ecosystem-panel/snapshot", BarkparkWeb.EcosystemPanelSnapshotController, :create,
       auth: :api},
      {:get, "/ecosystem-panel/frame", BarkparkWeb.EcosystemPanelFrameController, :show},
      {:live, "/ecosystem-panel", Barkpark.Plugins.EcosystemPanel.PanelLive, :index}
    ]
  end
end
