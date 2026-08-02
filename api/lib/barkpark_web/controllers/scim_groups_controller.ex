defmodule BarkparkWeb.ScimGroupsController do
  @moduledoc """
  SCIM 2.0 `/scim/v2/Groups` (era-w4-scim-groups; conformance hardening
  era-w8-scim-conformance). A group maps to a Barkpark role (`role`, defaulting
  to `displayName`); adding a user to the group grants that role in the org's
  workspaces, removing them reverts it. Org-scoped via `RequireScimToken`. Every
  membership change is audited. Wire shapes (ListResponse paging, `displayName`
  filter, resource `meta`/ETag, error `scimType`) render through
  `BarkparkWeb.ScimResponse`; every mutation routes through `Barkpark.Scim`.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Scim
  alias BarkparkWeb.ScimResponse

  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"

  # Barkpark extension schema (RFC 7643 §3.3): a member value the write could
  # not resolve to anybody in this organization is reported here rather than
  # dropped. Directory sync is eventually consistent — an IdP legitimately
  # pushes a group's members before the users' own provisioning POSTs land — so
  # an unresolvable member is answered as a PARTIAL success the IdP can
  # reconcile, never as a 2xx that silently claims a grant that never happened.
  @ext_schema "urn:barkpark:params:scim:schemas:extension:2.0:Group"

  # POST /scim/v2/Groups
  def create(conn, params) do
    org = conn.assigns.scim_org

    case Scim.create_group(org, params) do
      {:ok, group} ->
        %{unmatched: unmatched} = apply_members(org, group, member_ids(params["members"]))

        conn
        |> ScimResponse.with_etag(ScimResponse.version(group.updated_at))
        |> put_status(201)
        |> json(render_group(conn, group, Scim.group_member_ids(org, group), unmatched))

      {:error, :unknown_role} ->
        ScimResponse.error(
          conn,
          400,
          "the mapped role does not exist in this organization",
          "invalidValue"
        )

      {:error, :missing_display_name} ->
        ScimResponse.error(conn, 400, "displayName is required", "invalidValue")

      {:error, %Ecto.Changeset{} = cs} ->
        changeset_error(conn, cs)

      {:error, _} ->
        ScimResponse.error(conn, 400, "could not create group", "invalidValue")
    end
  end

  # GET /scim/v2/Groups/:id
  def show(conn, %{"id" => id}) do
    case Scim.get_org_group(conn.assigns.scim_org, id) do
      nil ->
        ScimResponse.error(conn, 404, "group not found in this organization")

      group ->
        conn
        |> ScimResponse.with_etag(ScimResponse.version(group.updated_at))
        |> json(
          render_group(conn, group, Scim.group_member_ids(conn.assigns.scim_org, group), [])
        )
    end
  end

  # GET /scim/v2/Groups?filter=displayName eq "x"&startIndex=1&count=50
  def index(conn, params) do
    {start_index, count} = ScimResponse.paging(params)
    display_name = parse_display_name_filter(params["filter"])

    {total, groups} =
      Scim.list_org_groups(conn.assigns.scim_org,
        filter: display_name,
        start_index: start_index,
        count: count
      )

    resources = Enum.map(groups, &render_group(conn, &1))
    json(conn, ScimResponse.list_response(resources, total, start_index))
  end

  # PATCH /scim/v2/Groups/:id — add/remove members.
  def update(conn, %{"id" => id} = params) do
    org = conn.assigns.scim_org

    case Scim.get_org_group(org, id) do
      nil ->
        ScimResponse.error(conn, 404, "group not found in this organization")

      group ->
        with_precondition(conn, group, fn conn ->
          # Every op's outcome is READ: an add/remove that matched nobody in
          # this org is collected, never discarded into a 200 that claims it.
          unmatched =
            Enum.reduce(member_ops(params["Operations"]), [], fn {op, uid}, miss ->
              result =
                case op do
                  :add -> Scim.add_group_member(org, group, uid)
                  :remove -> Scim.remove_group_member(org, group, uid)
                end

              case result do
                {:ok, _n} -> miss
                {:error, :no_membership} -> miss ++ [uid]
              end
            end)

          # Re-read AFTER the loop: `group` was fetched before the writes, so
          # rendering it would answer for the PRE-mutation resource (PDS-D551).
          group = Scim.get_org_group(org, id) || group

          conn
          |> ScimResponse.with_etag(ScimResponse.version(group.updated_at))
          |> json(render_group(conn, group, Scim.group_member_ids(org, group), unmatched))
        end)
    end
  end

  # PUT /scim/v2/Groups/:id — full replace (displayName + members set).
  def replace(conn, %{"id" => id} = params) do
    org = conn.assigns.scim_org

    case Scim.get_org_group(org, id) do
      nil ->
        ScimResponse.error(conn, 404, "group not found in this organization")

      group ->
        with_precondition(conn, group, fn conn ->
          case Scim.update_group(org, group, params) do
            {:ok, updated} ->
              {:ok, %{unmatched: unmatched}} =
                Scim.replace_group_members(org, updated, member_ids(params["members"]))

              conn
              |> ScimResponse.with_etag(ScimResponse.version(updated.updated_at))
              |> json(render_group(conn, updated, Scim.group_member_ids(org, updated), unmatched))

            {:error, %Ecto.Changeset{} = cs} ->
              changeset_error(conn, cs)
          end
        end)
    end
  end

  # DELETE /scim/v2/Groups/:id
  def delete(conn, %{"id" => id}) do
    org = conn.assigns.scim_org

    case Scim.get_org_group(org, id) do
      nil ->
        ScimResponse.error(conn, 404, "group not found in this organization")

      group ->
        with_precondition(conn, group, fn conn ->
          # 204 is a claim about the stored row, so it is answered over the
          # delete's own outcome — never over a discarded count. A bare
          # `{:ok, _} =` would be vacuous here: `{:ok, 0}` matches it, which is
          # exactly the "removed nothing" case 204 must not cover (PDS-D523).
          case Scim.delete_group(org, group) do
            {:ok, _n} ->
              send_resp(conn, 204, "")

            # The row is gone (or never belonged to this org) between the
            # org-scoped read above and this write — same answer the read
            # itself gives for an id this org cannot see.
            {:error, :not_found} ->
              ScimResponse.error(conn, 404, "group not found in this organization")
          end
        end)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # Grant the group's role to each supplied member id and READ every grant's
  # outcome — `Enum.each/2` here used to throw all of them away, so a 201 could
  # claim a membership set the write never created.
  defp apply_members(org, group, ids) do
    Enum.reduce(ids, %{granted: 0, unmatched: []}, fn id, acc ->
      case Scim.add_group_member(org, group, id) do
        {:ok, _n} -> %{acc | granted: acc.granted + 1}
        {:error, :no_membership} -> %{acc | unmatched: acc.unmatched ++ [id]}
      end
    end)
  end

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

  # filter=displayName eq "Admins"
  defp parse_display_name_filter(nil), do: nil

  defp parse_display_name_filter(filter) when is_binary(filter) do
    case Regex.run(~r/displayName\s+eq\s+"([^"]+)"/i, filter) do
      [_, name] -> name
      _ -> nil
    end
  end

  # Catch-all: a list param (`?filter[]=x` → Plug parses to `["x"]`) or any other
  # non-scalar falls back to no-filter instead of raising FunctionClauseError → 500.
  defp parse_display_name_filter(_), do: nil

  # Single-resource render: `members` is read back from STORED rows, so a
  # member id that named nobody is absent from the receipt instead of being
  # echoed back from the request, and the unresolvable ids are named outright
  # under the extension schema. List responses use `render_group/2` and omit
  # `members` (RFC 7644 §3.4.2 attribute exclusion) rather than issue a
  # per-group membership query.
  defp render_group(conn, group, members, unmatched) do
    rendered =
      Map.put(
        render_group(conn, group),
        "members",
        members
        |> Enum.sort()
        |> Enum.map(
          &%{"value" => &1, "$ref" => ScimResponse.location(conn, "Users", &1), "type" => "User"}
        )
      )

    case unmatched do
      [] ->
        rendered

      ids ->
        rendered
        |> Map.put("schemas", [@group_schema, @ext_schema])
        |> Map.put(@ext_schema, %{"unmatchedMembers" => ids})
    end
  end

  defp render_group(conn, group) do
    %{
      "schemas" => [@group_schema],
      "id" => group.id,
      "displayName" => group.display_name,
      "meta" =>
        ScimResponse.meta(
          "Group",
          ScimResponse.location(conn, "Groups", group.id),
          group.inserted_at,
          group.updated_at
        )
    }
  end

  # Guard a mutation behind the resource's current ETag (RFC 7644 §3.14): an
  # absent If-Match proceeds; a stale one → 412 Precondition Failed.
  defp with_precondition(conn, group, fun) do
    case ScimResponse.if_match(conn, ScimResponse.version(group.updated_at)) do
      :ok ->
        fun.(conn)

      :precondition_failed ->
        ScimResponse.error(conn, 412, "resource version mismatch (If-Match)")
    end
  end

  # A display_name unique-constraint violation → 409 uniqueness; anything else
  # → 400 invalidValue.
  defp changeset_error(conn, %Ecto.Changeset{errors: errors}) do
    if Enum.any?(errors, fn {field, _} -> field == :display_name end) do
      ScimResponse.error(conn, 409, "a group with that displayName already exists", "uniqueness")
    else
      ScimResponse.error(conn, 400, "could not save group", "invalidValue")
    end
  end
end
