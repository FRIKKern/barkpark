defmodule BarkparkWeb.ScimUsersController do
  @moduledoc """
  SCIM 2.0 `/scim/v2/Users` — directory-sync user provisioning (era-w4-scim-users;
  conformance hardening era-w8-scim-conformance).

  Org-scoped via `RequireScimToken` (`conn.assigns.scim_org`). Provision (POST)
  creates a confirmed user + org membership; deprovision (DELETE, or PATCH/PUT
  `active:false`) revokes all sessions + membership immediately. Every mutating
  op is audited. Wire shapes (ListResponse paging, resource `meta`/ETag, error
  `scimType`) render through `BarkparkWeb.ScimResponse`.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Scim
  alias BarkparkWeb.ScimPatch
  alias BarkparkWeb.ScimResponse

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"

  # POST /scim/v2/Users — provision.
  def create(conn, params) do
    org = conn.assigns.scim_org

    case Scim.provision_user(org, params) do
      {:ok, user} ->
        conn
        |> ScimResponse.with_etag(ScimResponse.version(user.updated_at))
        |> put_status(201)
        |> json(render_user(conn, user))

      {:error, :missing_username} ->
        ScimResponse.error(conn, 400, "userName is required", "invalidValue")

      {:error, _} ->
        ScimResponse.error(conn, 400, "could not provision user", "invalidValue")
    end
  end

  # GET /scim/v2/Users/:id
  def show(conn, %{"id" => id}) do
    org = conn.assigns.scim_org

    case Scim.get_org_user(org, id) do
      nil ->
        ScimResponse.error(conn, 404, "user not found in this organization")

      user ->
        conn
        |> ScimResponse.with_etag(ScimResponse.version(user.updated_at))
        |> json(render_user(conn, user))
    end
  end

  # GET /scim/v2/Users?filter=userName eq "x"&startIndex=1&count=50
  def index(conn, params) do
    org = conn.assigns.scim_org
    {start_index, count} = ScimResponse.paging(params)
    email = parse_username_filter(params["filter"])

    {total, users} =
      Scim.list_org_users(org, filter: email, start_index: start_index, count: count)

    resources = Enum.map(users, &render_user(conn, &1))
    json(conn, ScimResponse.list_response(resources, total, start_index))
  end

  # PATCH /scim/v2/Users/:id — the deprovision signal is active:false.
  #
  # The signal reaches us three ways, and only the first two used to be read:
  # a top-level `active` field (PUT), a PATCH op with `path: "active"`, and —
  # Azure AD's habit — a PATH-LESS `replace` whose `value` is the whole
  # resource (`{"op":"replace","value":{"active":false}}`). That third shape hit
  # `deactivating?/1`'s `path` comparison, failed it, and returned `200` with
  # `"active": true` for a user the IdP had just disabled: a deprovision the
  # directory believed had happened and that had not. `ScimPatch.classify/1`
  # folds it into `whole_resource`, which is read alongside the other two.
  def update(conn, %{"id" => id} = params) do
    org = conn.assigns.scim_org

    # Body shape is judged BEFORE the resource is touched, so a refused PATCH
    # cannot have half-applied.
    with {:ok, patch} <- ScimPatch.classify(params) do
      case Scim.get_org_user(org, id) do
        nil ->
          ScimResponse.error(conn, 404, "user not found in this organization")

        user ->
          apply_update(conn, org, user, params, patch)
      end
    else
      {:error, scim_type, detail} -> ScimResponse.error(conn, 400, detail, scim_type)
    end
  end

  defp apply_update(conn, org, user, params, patch) do
    with_precondition(conn, user, fn conn ->
      if deactivating?(params) or inactive?(patch.whole_resource) do
        {:ok, _summary} = Scim.deprovision_user(org, user)
        # READ THE ANSWER BACK. `active` was a literal `false` chosen by this
        # clause, so the body was byte-identical whether the deprovision took
        # or matched nothing (PDS-D503). Re-derive it from the stored rows.
        json(conn, render_user(conn, user, Scim.org_user_active?(org, user)))
      else
        conn
        |> ScimResponse.with_etag(ScimResponse.version(user.updated_at))
        |> json(render_user(conn, user))
      end
    end)
  end

  # PUT /scim/v2/Users/:id — replace; honour active:false as deprovision.
  def replace(conn, params), do: update(conn, params)

  # DELETE /scim/v2/Users/:id — hard deprovision.
  def delete(conn, %{"id" => id}) do
    org = conn.assigns.scim_org

    case Scim.get_org_user(org, id) do
      nil ->
        ScimResponse.error(conn, 404, "user not found in this organization")

      user ->
        with_precondition(conn, user, fn conn ->
          {:ok, _} = Scim.deprovision_user(org, user, hard: true)
          send_resp(conn, 204, "")
        end)
    end
  end

  # ── SCIM rendering ─────────────────────────────────────────────────────────

  defp render_user(conn, user, active \\ true) do
    %{
      "schemas" => [@user_schema],
      "id" => user.id,
      "userName" => user.email,
      "active" => active,
      "meta" =>
        ScimResponse.meta(
          "User",
          ScimResponse.location(conn, "Users", user.id),
          user.inserted_at,
          user.updated_at
        )
    }
  end

  # Guard a mutation behind the resource's current ETag (RFC 7644 §3.14): an
  # absent If-Match proceeds; a stale one → 412 Precondition Failed.
  defp with_precondition(conn, user, fun) do
    case ScimResponse.if_match(conn, ScimResponse.version(user.updated_at)) do
      :ok ->
        fun.(conn)

      :precondition_failed ->
        ScimResponse.error(conn, 412, "resource version mismatch (If-Match)")
    end
  end

  # `active:false` arrives either as a top-level PUT field or a PATCH Operations
  # entry (op replace, path active, value false).
  defp deactivating?(%{"active" => false}), do: true
  defp deactivating?(%{"active" => "false"}), do: true

  defp deactivating?(%{"Operations" => ops}) when is_list(ops) do
    Enum.any?(ops, fn op ->
      # `is_list(ops)` proves the container, not the elements: `op["op"]` is
      # `Access.get/3` and raises FunctionClauseError on a scalar Operation.
      is_map(op) and
        String.downcase(to_string(op["op"] || "")) == "replace" and
        String.downcase(to_string(op["path"] || "")) == "active" and
        op["value"] in [false, "false"]
    end)
  end

  defp deactivating?(_), do: false

  # The whole-resource half of the same signal: a path-less `replace`/`add`
  # whose merged attribute map carries `active: false` (RFC 7644 §3.5.2.3).
  defp inactive?(%{} = attrs), do: Map.get(attrs, "active") in [false, "false"]
  defp inactive?(_), do: false

  # filter=userName eq "alice@example.com"
  defp parse_username_filter(nil), do: nil

  defp parse_username_filter(filter) when is_binary(filter) do
    case Regex.run(~r/userName\s+eq\s+"([^"]+)"/i, filter) do
      [_, email] -> email
      _ -> nil
    end
  end

  # Catch-all: a list param (`?filter[]=x` → Plug parses to `["x"]`) or any other
  # non-scalar falls back to no-filter instead of raising FunctionClauseError → 500.
  defp parse_username_filter(_), do: nil
end
