defmodule BarkparkWeb.ShareController do
  @moduledoc """
  `/v1/shares` — admin-only CRUD over the PERSISTENT scoped-sharing registry
  (P4b). The HTTP surface behind `bp share ls/add/rm` and the Studio Shares
  panel.

  Mounted under `[:api, :require_admin]`: managing which tenant scopes are
  exposed on the network is an administrative act, so every verb requires an
  admin token. The anonymous reader/query/media surfaces a share opens are
  unauthenticated, but DECLARING a share is not.

  Each write goes through `Barkpark.Sharing.add_share/1` / `remove_share/3`,
  which validate through the SAME parser as a `BARKPARK_SHARES` env entry and
  call `refresh/0`, so a new share is live immediately (no restart) and a
  malformed request can never widen access.
  """
  use BarkparkWeb, :controller

  alias Barkpark.Content.Errors
  alias Barkpark.Sharing

  @doc """
  `GET /v1/shares` — list every live share, env baseline + persisted, each
  tagged with its `source` (`"env"` | `"stored"`). Only `"stored"` shares are
  mutable here; `"env"` shares come from `BARKPARK_SHARES`.
  """
  def index(conn, _params) do
    env = Enum.map(Sharing.shares_env(), &share_json(&1, "env"))
    stored = Enum.map(Sharing.list_stored(), &share_json(&1, "stored"))

    json(conn, %{shares: env ++ stored, active: Sharing.active?()})
  end

  @doc """
  `POST /v1/shares` — add (or upsert) a stored share.

  Body/params: `scope` (required, `"ws[/project[/dataset]]"`), `surfaces`
  (required, comma list of `papers,docs,media`), `access` (optional,
  `read|edit`, default `read`). 201 on success, 422 on an invalid scope /
  surface / access.
  """
  def create(conn, params) do
    scope = params["scope"]
    surfaces = params["surfaces"]
    access = params["access"] || "read"

    cond do
      not is_binary(scope) or scope == "" ->
        unprocessable(conn, "scope is required")

      not is_binary(surfaces) or surfaces == "" ->
        unprocessable(conn, "surfaces is required (comma list of papers,docs,media)")

      true ->
        case Sharing.add_share("#{scope}:#{surfaces}:#{access}") do
          {:ok, share} ->
            conn |> put_status(:created) |> json(%{share: share_json(share, "stored")})

          {:error, :invalid} ->
            unprocessable(
              conn,
              "invalid share — check scope, surfaces (papers,docs,media), access (read,edit)"
            )

          {:error, %Ecto.Changeset{} = changeset} ->
            unprocessable(conn, changeset_errors(changeset))
        end
    end
  end

  @doc """
  `DELETE /v1/shares` — remove the stored share for a scope.

  Body/params: `scope` (required). Applies the same default project/dataset as
  the parser, so `"gyldendal"` deletes `gyldendal/default/production`. Returns
  the count removed (0 if none / if the scope was env-only). 422 on a malformed
  scope.
  """
  def delete(conn, params) do
    scope = params["scope"]

    case scope && Sharing.scope_triple(scope) do
      {:ok, {ws, proj, dataset}} ->
        {:ok, count} = Sharing.remove_share(ws, proj, dataset)
        json(conn, %{removed: count, scope: "#{ws}/#{proj}/#{dataset}"})

      _ ->
        unprocessable(conn, "scope is required and must be ws[/project[/dataset]]")
    end
  end

  @doc """
  `POST /v1/shares/tokens` — mint a scoped-share EDIT token (P5).

  Body/params: `scope` (required), `surfaces` (required, comma list of
  `docs,media`), `ttl` (optional seconds; default 7d, cap 1y), `label`
  (optional). 201 with the RAW token shown ONCE; 422 if the scope is not
  `:edit`-shared for the surfaces.
  """
  def mint_token(conn, params) do
    scope = params["scope"]
    surfaces = params["surfaces"]

    with true <- is_binary(scope) and scope != "",
         true <- is_binary(surfaces) and surfaces != "",
         {:ok, {ws, proj, dataset}} <- Sharing.scope_triple(scope) do
      surface_list =
        surfaces |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      opts = token_opts(params)

      case Barkpark.Auth.create_share_token(ws, proj, dataset, surface_list, opts) do
        {:ok, {raw, token}} ->
          conn
          |> put_status(:created)
          |> json(%{token: raw, share_token: token_json(token)})

        {:error, reason} ->
          unprocessable(conn, "could not mint edit token: #{describe_token_error(reason)}")
      end
    else
      _ -> unprocessable(conn, "scope and surfaces (comma list of docs,media) are required")
    end
  end

  @doc """
  `GET /v1/shares/tokens` — list share-edit tokens (optional `?scope=` filter).
  Never returns the raw token or its hash.
  """
  def list_tokens(conn, params) do
    scope = if is_binary(params["scope"]) and params["scope"] != "", do: params["scope"]
    tokens = Barkpark.Auth.list_share_tokens(scope) |> Enum.map(&token_json/1)
    json(conn, %{tokens: tokens})
  end

  @doc """
  `DELETE /v1/shares/tokens/:token_id` — revoke one share-edit token.
  """
  def revoke_token(conn, %{"token_id" => token_id}) do
    case Barkpark.Auth.revoke_token(token_id) do
      {:ok, _} -> json(conn, %{revoked: true, token_id: token_id})
      {:error, :not_found} -> not_found(conn, "token not found")
      {:error, _} -> unprocessable(conn, "could not revoke token")
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp token_opts(params) do
    ttl =
      case params["ttl"] do
        t when is_integer(t) ->
          t

        t when is_binary(t) ->
          case Integer.parse(t) do
            {n, _} -> n
            :error -> nil
          end

        _ ->
          nil
      end

    [ttl: ttl, label: params["label"]]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  # The token row, MINUS the secret (token_hash never leaves the server).
  defp token_json(token) do
    %{
      id: token.id,
      label: token.label,
      scope: token.share_scope,
      surfaces:
        token.permissions
        |> List.wrap()
        |> Enum.map(&String.replace_prefix(&1, "share-edit-", "")),
      dataset: token.dataset,
      expires_at: token.expires_at,
      revoked_at: token.revoked_at,
      inserted_at: Map.get(token, :inserted_at)
    }
  end

  defp describe_token_error(:not_edit_shared), do: "the scope is not edit-shared"
  defp describe_token_error(:surface_not_shared), do: "a requested surface is not edit-shared"
  defp describe_token_error(:unsupported_surface), do: "only docs and media are editable surfaces"
  defp describe_token_error(:no_surfaces), do: "no valid surfaces"
  defp describe_token_error(:unknown_scope), do: "the workspace/project does not exist"
  defp describe_token_error(%Ecto.Changeset{}), do: "validation failed"
  defp describe_token_error(other), do: inspect(other)

  defp share_json(%Sharing.Share{} = s, source) do
    %{
      scope: "#{s.workspace_slug}/#{s.project_slug}/#{s.dataset}",
      workspace: s.workspace_slug,
      project: s.project_slug,
      dataset: s.dataset,
      surfaces: Enum.map(s.surfaces, &Atom.to_string/1),
      access: Atom.to_string(s.access),
      source: source
    }
  end

  # Canonical v1 validation envelope (code + request_id), the same contract as
  # the content endpoints — was a bare `%{error: message}` with neither. A string
  # rides as the human `message`; a changeset-errors map rides as `details`.
  defp unprocessable(conn, message) do
    base =
      {:error, :malformed}
      |> Errors.to_envelope(conn)
      |> Map.put(:code, "validation_failed")

    env =
      case message do
        msg when is_binary(msg) -> Map.put(base, :message, msg)
        details -> base |> Map.put(:message, "validation failed") |> Map.put(:details, details)
      end

    conn |> put_status(422) |> json(%{error: Map.delete(env, :status)})
  end

  # Canonical not_found with a resource-specific message.
  defp not_found(conn, message) do
    env =
      {:error, :not_found}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, message)

    conn |> put_status(env.status) |> json(%{error: Map.delete(env, :status)})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
