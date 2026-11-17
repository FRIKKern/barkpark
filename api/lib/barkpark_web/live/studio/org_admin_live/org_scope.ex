defmodule BarkparkWeb.Studio.OrgAdminLive.OrgScope do
  @moduledoc """
  Which organizations the Studio org-admin page shows and acts on
  (task-4d44f2aefec77aff).

  The page opens for every admin while the operator allowlist is unset, the
  single-tenant default. It used to list every organization on the instance,
  with its SSO, SCIM, member and policy state, and let any admin mint a SCIM
  token or change the MFA, session and sign-in policy of any of them. Who may
  open the page is unchanged; the organizations narrowed.

    * A listed instance operator (allowlist set, and the viewer on it) sees and
      acts on every organization, as before.
    * Everyone else sees and acts on an organization only when they administer
      it: it has at least one workspace, and the viewer holds an admin seat
      (`Barkpark.Tenancy.Auth.workspace_admin?/2`) in EVERY one of them. There
      are no organization roles; an organization is its workspaces. A SCIM
      token and the MFA, session and sign-in policy reach every member of
      every workspace of the organization, so an admin of one workspace must
      not set them for another's members (the same rule as token rotation in
      `Barkpark.Auth`: an admin of A never mints a secret that reaches into B).
    * A dataset-bound admin token gets none while
      `BarkparkWeb.Plugs.DatasetBoundAdminReads` refuses it.

  `orgs/1` feeds the cards; `guard/4` runs before every event handler and
  re-asks `permits?/2` for the organization the event names, from the database,
  never from what was rendered. A refused event writes nothing.
  """

  use Gettext, backend: BarkparkWeb.Gettext

  import Ecto.Query, warn: false

  alias Barkpark.Accounts.User
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.{Auth, Membership, Workspace}
  alias BarkparkWeb.Plugs.{DatasetBoundAdminReads, RequirePlatformOperator}

  @doc "The organizations the viewer in `assigns` may see on the page."
  @spec orgs(map()) :: [Barkpark.Tenancy.Organization.t()]
  def orgs(assigns) do
    principal = principal(assigns)
    all = Tenancy.list_organizations()

    if listed_operator?(principal) do
      all
    else
      admin_ws = MapSet.new(administered(principal))
      by_org = Enum.group_by(org_workspace_pairs(nil), &elem(&1, 0), &elem(&1, 1))
      Enum.filter(all, &covers?(admin_ws, Map.get(by_org, &1.id, [])))
    end
  end

  @doc "True when the viewer in `assigns` may act on organization `org_id`."
  @spec permits?(map(), term()) :: boolean()
  def permits?(assigns, org_id) do
    principal = principal(assigns)

    case Repo.uuid_or_nil(org_id) do
      nil ->
        false

      id ->
        listed_operator?(principal) or
          covers?(
            MapSet.new(administered(principal)),
            Enum.map(org_workspace_pairs(id), &elem(&1, 1))
          )
    end
  end

  @doc """
  Run `handler.(event, params, socket)` only when the viewer may act on the
  organization in `params["org"]`; otherwise refuse with a flash and no write.
  """
  @spec guard(String.t(), map(), Phoenix.LiveView.Socket.t(), function()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def guard(event, params, socket, handler) do
    if permits?(socket.assigns, params["org"]),
      do: handler.(event, params, socket),
      else:
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("You do not administer this organization.")
         )}
  end

  defp principal(assigns), do: assigns[:api_token] || assigns[:current_user]

  # `permits?/1` is true for everyone while the allowlist is unset, so it alone
  # does not name an operator: the allowlist must be set too.
  defp listed_operator?(principal) do
    RequirePlatformOperator.allowlist() != %{emails: [], token_ids: []} and
      RequirePlatformOperator.permits?(principal)
  end

  # An organization with no workspace is nobody's but the operator's.
  defp covers?(_admin_ws, []), do: false
  defp covers?(admin_ws, ws_ids), do: Enum.all?(ws_ids, &MapSet.member?(admin_ws, &1))

  defp org_workspace_pairs(nil) do
    Repo.all(
      from w in Workspace,
        where: not is_nil(w.organization_id),
        select: {w.organization_id, w.id}
    )
  end

  defp org_workspace_pairs(org_id) do
    Repo.all(
      from w in Workspace, where: w.organization_id == ^org_id, select: {w.organization_id, w.id}
    )
  end

  defp administered(%ApiToken{id: id} = token) when is_binary(id) do
    if DatasetBoundAdminReads.refused?(token), do: [], else: seats(token, id, "api_token")
  end

  defp administered(%User{id: id} = user) when is_binary(id), do: seats(user, id, "user")
  defp administered(_principal), do: []

  defp seats(principal, id, type) do
    Repo.all(
      from m in Membership,
        where: m.principal_id == ^id and m.principal_type == ^type,
        select: m.workspace_id
    )
    |> Enum.filter(&Auth.workspace_admin?(principal, &1))
  end

  @doc """
  True when the viewer sees only the organizations they administer (everyone
  but a listed operator). The page then says so in one line, naming no hidden
  organization and no count.
  """
  @spec scoped?(map()) :: boolean()
  def scoped?(assigns), do: not listed_operator?(principal(assigns))

  @doc """
  True when the viewer in `assigns` holds an admin seat in workspace
  `workspace_id` by the rule `permits?/2` counts seats with (a listed operator:
  always; a refused dataset-bound token: never). `BarkparkWeb.Plugs.RequireOrgAdmin`
  asks it before a workspace with no organization joins one.
  """
  @spec administers_workspace?(map(), term()) :: boolean()
  def administers_workspace?(assigns, workspace_id) do
    principal = principal(assigns)

    listed_operator?(principal) or
      (is_binary(workspace_id) and workspace_id in administered(principal))
  end
end
