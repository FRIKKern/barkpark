defmodule BarkparkWeb.ScimGroupsController do
  @moduledoc """
  SCIM 2.0 `/scim/v2/Groups` (era-w4-scim-groups). A group maps to a Barkpark
  role (`role`, defaulting to `displayName`); adding a user to the group grants
  that role in the org's workspaces, removing them reverts it. Org-scoped via
  `RequireScimToken`. Every membership change is audited.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Scim

  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"
  @list_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"

  # POST /scim/v2/Groups
  def create(conn, params) do
    org = conn.assigns.scim_org

    case Scim.create_group(org, params) do
      {:ok, group} ->
        apply_members(org, group, member_ids(params["members"]))
        conn |> put_status(201) |> json(render_group(group))

      {:error, :unknown_role} ->
        scim_error(conn, 400, "the mapped role does not exist in this organization")

      {:error, :missing_display_name} ->
        scim_error(conn, 400, "displayName is required")

      {:error, _} ->
        scim_error(conn, 400, "could not create group")
    end
  end

  # GET /scim/v2/Groups/:id
  def show(conn, %{"id" => id}) do
    case Scim.get_org_group(conn.assigns.scim_org, id) do
      nil -> scim_error(conn, 404, "group not found in this organization")
      group -> json(conn, render_group(group))
    end
  end

  # GET /scim/v2/Groups
  def index(conn, _params) do
    groups = Scim.list_org_groups(conn.assigns.scim_org)

    json(conn, %{
      "schemas" => [@list_schema],
      "totalResults" => length(groups),
      "Resources" => Enum.map(groups, &render_group/1)
    })
  end

  # PATCH /scim/v2/Groups/:id — add/remove members.
  def update(conn, %{"id" => id} = params) do
    org = conn.assigns.scim_org

    case Scim.get_org_group(org, id) do
      nil ->
        scim_error(conn, 404, "group not found in this organization")

      group ->
        for {op, uid} <- member_ops(params["Operations"]) do
          case op do
            :add -> Scim.add_group_member(org, group, uid)
            :remove -> Scim.remove_group_member(org, group, uid)
          end
        end

        json(conn, render_group(group))
    end
  end

  # DELETE /scim/v2/Groups/:id
  def delete(conn, %{"id" => id}) do
    org = conn.assigns.scim_org

    case Scim.get_org_group(org, id) do
      nil -> scim_error(conn, 404, "group not found in this organization")
      group -> Barkpark.Repo.delete!(group) && send_resp(conn, 204, "")
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp apply_members(org, group, ids),
    do: Enum.each(ids, &Scim.add_group_member(org, group, &1))

  defp member_ids(nil), do: []

  defp member_ids(members) when is_list(members),
    do: Enum.map(members, & &1["value"]) |> Enum.filter(&is_binary/1)

  defp member_ids(_), do: []

  # SCIM PATCH member Operations → [{:add|:remove, user_id}, …].
  defp member_ops(nil), do: []

  defp member_ops(ops) when is_list(ops) do
    ops
    |> Enum.filter(&(String.downcase(to_string(&1["path"] || "")) == "members"))
    |> Enum.flat_map(fn op ->
      action = if String.downcase(to_string(op["op"] || "")) == "remove", do: :remove, else: :add
      op["value"] |> member_ids() |> Enum.map(&{action, &1})
    end)
  end

  defp member_ops(_), do: []

  defp render_group(group) do
    %{
      "schemas" => [@group_schema],
      "id" => group.id,
      "displayName" => group.display_name,
      "meta" => %{"resourceType" => "Group"}
    }
  end

  defp scim_error(conn, status, detail) do
    conn
    |> put_status(status)
    |> json(%{
      "schemas" => ["urn:ietf:params:scim:api:messages:2.0:Error"],
      "status" => to_string(status),
      "detail" => detail
    })
  end
end
