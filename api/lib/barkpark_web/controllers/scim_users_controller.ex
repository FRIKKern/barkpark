defmodule BarkparkWeb.ScimUsersController do
  @moduledoc """
  SCIM 2.0 `/scim/v2/Users` — directory-sync user provisioning (era-w4-scim-users).

  Org-scoped via `RequireScimToken` (`conn.assigns.scim_org`). Provision (POST)
  creates a confirmed user + org membership; deprovision (DELETE, or PATCH/PUT
  `active:false`) revokes all sessions + membership immediately. Every mutating
  op is audited.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Scim

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @list_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"

  # POST /scim/v2/Users — provision.
  def create(conn, params) do
    org = conn.assigns.scim_org

    case Scim.provision_user(org, params) do
      {:ok, user} ->
        conn |> put_status(201) |> json(render_user(user))

      {:error, :missing_username} ->
        scim_error(conn, 400, "userName is required")

      {:error, _} ->
        scim_error(conn, 400, "could not provision user")
    end
  end

  # GET /scim/v2/Users/:id
  def show(conn, %{"id" => id}) do
    org = conn.assigns.scim_org

    case Scim.get_org_user(org, id) do
      nil -> scim_error(conn, 404, "user not found in this organization")
      user -> json(conn, render_user(user))
    end
  end

  # GET /scim/v2/Users?filter=userName eq "x"
  def index(conn, params) do
    org = conn.assigns.scim_org
    email = parse_username_filter(params["filter"])
    users = Scim.list_org_users(org, email)

    json(conn, %{
      "schemas" => [@list_schema],
      "totalResults" => length(users),
      "Resources" => Enum.map(users, &render_user/1)
    })
  end

  # PATCH /scim/v2/Users/:id — the deprovision signal is active:false.
  def update(conn, %{"id" => id} = params) do
    org = conn.assigns.scim_org

    case Scim.get_org_user(org, id) do
      nil ->
        scim_error(conn, 404, "user not found in this organization")

      user ->
        if deactivating?(params) do
          {:ok, _} = Scim.deprovision_user(org, user)
          json(conn, render_user(user, false))
        else
          json(conn, render_user(user))
        end
    end
  end

  # PUT /scim/v2/Users/:id — replace; honour active:false as deprovision.
  def replace(conn, params), do: update(conn, params)

  # DELETE /scim/v2/Users/:id — hard deprovision.
  def delete(conn, %{"id" => id}) do
    org = conn.assigns.scim_org

    case Scim.get_org_user(org, id) do
      nil ->
        scim_error(conn, 404, "user not found in this organization")

      user ->
        {:ok, _} = Scim.deprovision_user(org, user, hard: true)
        send_resp(conn, 204, "")
    end
  end

  # ── SCIM rendering ─────────────────────────────────────────────────────────

  defp render_user(user, active \\ true) do
    %{
      "schemas" => [@user_schema],
      "id" => user.id,
      "userName" => user.email,
      "active" => active,
      "meta" => %{"resourceType" => "User"}
    }
  end

  # `active:false` arrives either as a top-level PUT field or a PATCH Operations
  # entry (op replace, path active, value false).
  defp deactivating?(%{"active" => false}), do: true
  defp deactivating?(%{"active" => "false"}), do: true

  defp deactivating?(%{"Operations" => ops}) when is_list(ops) do
    Enum.any?(ops, fn op ->
      String.downcase(to_string(op["op"] || "")) == "replace" and
        String.downcase(to_string(op["path"] || "")) == "active" and
        op["value"] in [false, "false"]
    end)
  end

  defp deactivating?(_), do: false

  # filter=userName eq "alice@example.com"
  defp parse_username_filter(nil), do: nil

  defp parse_username_filter(filter) when is_binary(filter) do
    case Regex.run(~r/userName\s+eq\s+"([^"]+)"/i, filter) do
      [_, email] -> email
      _ -> nil
    end
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
