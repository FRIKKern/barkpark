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

  The bucket also mounts a flat copy at `/v1/plugins/ecosystem-panel/snapshot`
  on the global-permission gate. The controller answers that copy 404 and
  writes nothing: a flat path names no workspace, and acting on the stamped
  Default workspace there is the bug class `docs/auth.md` warns about.

  The frame and shell routes come in later tasks.

  `register_schemas/1` is `[]`: a snapshot is a row, not a document, so it
  keeps no revision history and never reaches search, webhooks or the desk.
  """

  use Barkpark.Plugin, manifest_path: "../../../priv/plugins/ecosystem_panel/plugin.json"

  @impl Barkpark.Plugin
  def register_routes(_ctx) do
    [
      {:post, "/ecosystem-panel/snapshot", BarkparkWeb.EcosystemPanelSnapshotController, :create,
       auth: :api}
    ]
  end
end
