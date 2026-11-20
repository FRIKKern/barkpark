defmodule BarkparkWeb.RoleNamesController do
  @moduledoc """
  `GET /w/:ws/p/:proj/v1/workspace/roles` — the role names a seat in this
  workspace may hold (task-4d3cd1a5e8265646): the built-ins in their fixed
  order, then the custom roles defined for this workspace or globally, A to Z.
  Names only: no permissions, no who holds what. Roles belong to the
  workspace, not to a dataset, so one read covers every dataset in it.

  The list is `Barkpark.Tenancy.Auth.valid_role_names/1`, the one set every
  membership write is checked against, so a name here is always one an admin
  can grant.

  Mounted in the schema-read block (`:scoped_api,
  :require_token_or_member_login_session`), so the Studio reads it on the
  signed-in person's own credential: a seated member's API token or login
  session reads it; no seat, or a session let in only by an access grant, is
  the scoped 403 `not_a_member`. A dataset-bound token names no dataset here,
  so it reads its workspace's list, and is refused only when it names another
  dataset (`?dataset=`).
  """
  use BarkparkWeb, :controller

  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  def index(conn, _params) do
    %{id: workspace_id} = conn.assigns.current_workspace
    built_in = Membership.roles()
    custom = TenancyAuth.valid_role_names(workspace_id) -- built_in
    json(conn, %{roles: built_in ++ Enum.sort(custom)})
  end
end
