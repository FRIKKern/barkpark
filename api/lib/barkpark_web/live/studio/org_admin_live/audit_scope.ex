defmodule BarkparkWeb.Studio.OrgAdminLive.AuditScope do
  @moduledoc """
  Which audit rows the Studio org-admin page lists under "Recent activity"
  (task-fa907a54028f501c).

  The page opens for every admin while the operator allowlist is unset, the
  single-tenant default. It used to list the newest 20 rows of the whole
  instance there, so an admin of one workspace read another workspace's rows
  and the rows with no workspace (sign-ins, MFA, SSO, SCIM, organization
  changes). Who may open the page is unchanged; only these rows narrowed.

    * A listed instance operator (allowlist set, and the viewer on it) sees
      every row, as before. The rest of the page is instance-wide authority for
      them anyway.
    * Everyone else sees rows of the workspaces where they hold an admin seat,
      by `Barkpark.Tenancy.Auth.workspace_admin?/2`, the predicate of every
      scoped admin page. Never another workspace, never a row with no
      workspace. A flat admin token with no seat sees none.
    * A dataset-bound admin token sees none while
      `BarkparkWeb.Plugs.DatasetBoundAdminReads` refuses it, the Activity
      page's rule.

  Rows come from `Barkpark.Audit.Feed.recent/2`: the Activity page's fields,
  never `metadata`.
  """

  import Ecto.Query, warn: false

  alias Barkpark.Accounts.User
  alias Barkpark.Audit.Feed
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy.{Auth, Membership}
  alias BarkparkWeb.Plugs.{DatasetBoundAdminReads, RequirePlatformOperator}

  @limit 20

  @doc "The rows for the viewer in `assigns` (`:api_token`, else `:current_user`)."
  @spec rows(map()) :: [Feed.row()]
  def rows(assigns) do
    principal = assigns[:api_token] || assigns[:current_user]

    if listed_operator?(principal),
      do: Feed.recent(:instance, @limit),
      else: Feed.recent({:workspaces, administered(principal)}, @limit)
  end

  # `permits?/1` is true for everyone while the allowlist is unset, so it alone
  # does not name an operator: the allowlist must be set too.
  defp listed_operator?(principal) do
    RequirePlatformOperator.allowlist() != %{emails: [], token_ids: []} and
      RequirePlatformOperator.permits?(principal)
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
end
