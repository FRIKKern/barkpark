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

  # ── helpers ────────────────────────────────────────────────────────────

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

  defp unprocessable(conn, message) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: message})
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
