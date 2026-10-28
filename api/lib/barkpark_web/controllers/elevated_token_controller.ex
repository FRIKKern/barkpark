defmodule BarkparkWeb.ElevatedTokenController do
  @moduledoc """
  Admin-to-admin token mint (task-7d4d405e0ee4bcbf): an admin mints a `write`
  and/or `admin` token for the workspace in the URL.

  `POST /w/:workspace_slug/p/:project_slug/v1/tokens/elevated`, on the same
  `[:scoped_api, :scoped_admin]` pipeline as `TokenController` (owner/admin
  ROLE in the resolved workspace). On top of that gate the caller's token must
  hold the flat `admin` permission, and the minted set is capped at the
  caller's own permissions — `Barkpark.Auth.mint_delegated_token/3` owns both
  rules.

  A separate controller, not a wider `TokenController`: that controller's
  allowlist is read-only by contract (Connectors D36: never widen it), and it
  stays exactly as it was for every caller.

  Body: `{"label": string, "permissions": ["read","write","admin"],
  "dataset": "production", "expires_at": iso8601?, "no_expiry": true?}`.
  `label` and `permissions` are required. At most one of `expires_at` /
  `no_expiry`; neither → the configured api-class default.

  `"workspaces": [slug]` (optional) seats the new token in those workspaces
  too, with the same role as its seat in the URL's workspace. The caller must
  be an owner or admin in every one, or nothing is minted (403
  `not_workspace_admin`, naming the first workspace refused; an unknown slug
  gets the same answer). Barkpark Cloud's admin-token rotation sends the old
  token's seats here.

  201 → `{"token": raw, "id", "inserted_at", "label", "permissions",
  "dataset", "workspace", "seats", "expires_at"}`. `seats` lists every
  workspace slug the token is seated in. The raw token appears only here.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Auth
  alias Barkpark.Auth.TokenExpiry
  alias Barkpark.Tenancy
  alias BarkparkWeb.ErrorResponse

  def create(conn, params) do
    actor = conn.assigns[:api_token]
    home = conn.assigns[:current_workspace]
    also_result = fetch_workspaces(params, home && home.slug)

    with %{id: ws_id, slug: ws_slug} <- home,
         {:ok, perms} <- fetch_permissions(params),
         {:ok, expiry} <- fetch_expiry(params),
         {:ok, also} <- also_result,
         {:ok, {raw, token}} <-
           Auth.mint_delegated_token(actor, ws_id,
             label: params["label"],
             permissions: perms,
             dataset: fetch_dataset(params),
             dataset_bound: dataset_named?(params),
             expires_at: expiry,
             also_seat: Enum.map(also, & &1.id)
           ) do
      conn
      |> put_status(:created)
      |> json(%{
        token: raw,
        id: token.id,
        inserted_at: token.inserted_at,
        label: token.label,
        permissions: token.permissions,
        dataset: token.dataset,
        workspace: ws_slug,
        seats: [ws_slug | Enum.map(also, & &1.slug)],
        expires_at: token.expires_at
      })
    else
      nil ->
        unprocessable(conn, "workspace could not be resolved")

      {:error, {:not_workspace_admin, also_id}} ->
        {:ok, also} = also_result
        not_admin_of(conn, Enum.find_value(also, &(&1.id == also_id and &1.slug)))

      {:error, :invalid_workspaces} ->
        unprocessable(conn, "workspaces must be a list of workspace slugs")

      {:error, :admin_required} ->
        forbidden(
          conn,
          "admin_required",
          "minting a write or admin token needs a token that holds the admin permission; " <>
            "this token holds #{inspect(actor_permissions(actor))}",
          "Use an admin credential for this instance. With none locally, recover one from " <>
            "Barkpark Cloud: `bp instance admin-token <instance-id> --install`."
        )

      {:error, :not_workspace_admin} ->
        forbidden(
          conn,
          "not_workspace_admin",
          "this token is not an owner or admin of the workspace in the URL",
          nil
        )

      {:error, {:escalation, missing}} ->
        forbidden(
          conn,
          "permission_escalation",
          "you can only mint permissions your own token holds; it lacks #{inspect(missing)}",
          nil
        )

      {:error, {:invalid_permissions, bad}} ->
        unprocessable(
          conn,
          "permissions must be a non-empty list drawn from " <>
            "#{inspect(Auth.delegable_permissions())}; refused #{inspect(bad)}"
        )

      {:error, :missing_label} ->
        unprocessable(conn, "label is required and must be a non-empty string")

      {:error, :invalid_expiry} ->
        unprocessable(
          conn,
          "expires_at must be an ISO-8601 datetime and no_expiry must be true; " <>
            "send at most one of them"
        )

      {:error, {:expiry_exceeds_max, _, _} = reason} ->
        expiry_refused(conn, reason)

      {:error, :expiry_not_in_future = reason} ->
        expiry_refused(conn, reason)

      {:error, _reason} ->
        unprocessable(conn, "could not mint token")
    end
  end

  defp not_admin_of(conn, slug) do
    forbidden(
      conn,
      "not_workspace_admin",
      "this token is not an owner or admin of workspace #{inspect(slug)}, " <>
        "so it cannot seat the new token there",
      nil
    )
  end

  # The workspaces besides the URL's, deduplicated, as `%{id, slug}`. An
  # unknown slug gets a fresh id that no workspace has, so the admin check in
  # `Auth.mint_delegated_token/3` refuses it in order, the same way it refuses
  # a workspace the caller does not administer. Nobody learns which slugs exist.
  defp fetch_workspaces(%{"workspaces" => slugs}, home) when is_list(slugs) do
    if Enum.all?(slugs, &is_binary/1) do
      also =
        slugs
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or &1 == home))
        |> Enum.uniq()
        |> Enum.map(fn slug ->
          case Tenancy.get_workspace_by_slug(slug) do
            nil -> %{id: Ecto.UUID.generate(), slug: slug}
            ws -> %{id: ws.id, slug: ws.slug}
          end
        end)

      {:ok, also}
    else
      {:error, :invalid_workspaces}
    end
  end

  defp fetch_workspaces(%{"workspaces" => slugs}, home) when is_binary(slugs),
    do: fetch_workspaces(%{"workspaces" => String.split(slugs, ",", trim: true)}, home)

  defp fetch_workspaces(%{"workspaces" => nil}, _home), do: {:ok, []}
  defp fetch_workspaces(%{"workspaces" => _}, _home), do: {:error, :invalid_workspaces}
  defp fetch_workspaces(_params, _home), do: {:ok, []}

  defp actor_permissions(%{permissions: perms}) when is_list(perms), do: perms
  defp actor_permissions(_), do: []

  # A comma string is accepted as well as a list: the manifest path sends flags
  # as query scalars, and a list element that is not a string is refused.
  defp fetch_permissions(%{"permissions" => perms}) when is_list(perms) do
    if Enum.all?(perms, &is_binary/1),
      do: {:ok, perms |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))},
      else: {:error, {:invalid_permissions, [:invalid]}}
  end

  defp fetch_permissions(%{"permissions" => perms}) when is_binary(perms),
    do: {:ok, perms |> String.split(",", trim: true) |> Enum.map(&String.trim/1)}

  defp fetch_permissions(_), do: {:error, {:invalid_permissions, []}}

  defp fetch_dataset(%{"dataset" => dataset}) when is_binary(dataset) do
    case String.trim(dataset) do
      "" -> "production"
      trimmed -> trimmed
    end
  end

  defp fetch_dataset(_), do: "production"

  # Named dataset = a binding the caller asked for; the fallback is a default
  # (task-4418b517649a58ce). `nil` when absent: unbound, as every legacy row.
  defp dataset_named?(%{"dataset" => dataset}) when is_binary(dataset),
    do: if(String.trim(dataset) == "", do: nil, else: true)

  defp dataset_named?(_), do: nil

  defp fetch_expiry(params) do
    case {Map.get(params, "expires_at"), Map.get(params, "no_expiry")} do
      {nil, nil} ->
        {:ok, nil}

      {nil, v} when v in [true, "true"] ->
        {:ok, :no_expiry}

      {at, nil} when is_binary(at) ->
        case DateTime.from_iso8601(at) do
          {:ok, dt, _offset} -> {:ok, dt}
          _ -> {:error, :invalid_expiry}
        end

      _ ->
        {:error, :invalid_expiry}
    end
  end

  defp forbidden(conn, reason, message, hint) do
    fields = %{code: "forbidden", reason: reason, message: message}
    fields = if hint, do: Map.put(fields, :hint, hint), else: fields
    ErrorResponse.emit_fields(conn, :forbidden, fields)
  end

  defp expiry_refused(conn, reason) do
    ErrorResponse.emit_fields(conn, :unprocessable_entity, %{
      code: "unprocessable",
      message: TokenExpiry.message(reason),
      details: TokenExpiry.details(reason)
    })
  end

  defp unprocessable(conn, message) do
    ErrorResponse.emit_fields(conn, :unprocessable_entity, %{
      code: "unprocessable",
      message: message
    })
  end
end
