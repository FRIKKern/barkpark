defmodule BarkparkWeb.Plugs.RequireOrgAdmin do
  @moduledoc """
  `/v1/admin/orgs/:org_slug/...` acts only on an organization the caller
  administers in full (task-e04a14e5834fb086).

  The scope rides `[:api, :require_admin, :require_platform_operator]`. With the
  operator allowlist unset (the default) the operator plug lets every admin
  through, so any admin of one workspace could set the sign-in methods, the
  OIDC connection and the SSO domains of every organization, and move
  workspaces between organizations. Moving a workspace could also reshape an
  organization until the caller counted as its admin on the Studio org-admin
  page (#26648).

  The rule is `BarkparkWeb.Studio.OrgAdminLive.OrgScope`'s, read from the
  database on every request, before the action writes anything:

    * A listed operator (allowlist set, caller on it) passes, as before. The
      action then answers as it always did, 404 for a missing organization.
    * Everyone else must administer the organization in the URL: it has at
      least one workspace, and the caller is admin in every one of them
      (`OrgScope.permits?/2`). An organization with no workspace is the
      operator's only.
    * `PUT /:org_slug/workspaces/:workspace_slug` moves a workspace. The caller
      must also administer the organization the workspace is in now. A
      workspace in no organization needs an admin seat in that workspace
      (`OrgScope.administers_workspace?/2`).

  A refusal is the same 403 whether the organization or the workspace exists
  or not, so a slug cannot be probed. It writes nothing, no audit event
  either.
  """

  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Organization, Workspace}
  alias BarkparkWeb.ErrorResponse
  alias BarkparkWeb.Studio.OrgAdminLive.OrgScope

  @message "you do not administer this organization"
  @hint "Only an admin of every workspace in the organization can change it. " <>
          "Moving a workspace also needs admin of every workspace in the organization " <>
          "it leaves, or of the workspace itself when it is in none. An organization " <>
          "with no workspace needs a token on BARKPARK_OPERATOR_TOKEN_IDS. Setting that " <>
          "list also closes the other instance-wide admin routes (self-update, plugins, " <>
          "global secrets, incidents, playground, import, instance metrics) to every " <>
          "admin not on it."

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      not OrgScope.scoped?(conn.assigns) -> conn
      permitted?(conn.assigns, conn.path_params) -> conn
      true -> ErrorResponse.emit(conn, {:error, :forbidden}, @message, @hint)
    end
  end

  defp permitted?(assigns, %{"org_slug" => slug} = params) when is_binary(slug) do
    case Tenancy.get_organization_by_slug(slug) do
      %Organization{id: id} -> OrgScope.permits?(assigns, id) and source_ok?(assigns, params)
      nil -> false
    end
  end

  defp permitted?(_assigns, _params), do: false

  defp source_ok?(assigns, %{"workspace_slug" => ws_slug}) when is_binary(ws_slug) do
    case Tenancy.get_workspace_by_slug(ws_slug) do
      %Workspace{organization_id: nil, id: id} -> OrgScope.administers_workspace?(assigns, id)
      %Workspace{organization_id: org_id} -> OrgScope.permits?(assigns, org_id)
      nil -> false
    end
  end

  defp source_ok?(_assigns, params), do: not Map.has_key?(params, "workspace_slug")
end
