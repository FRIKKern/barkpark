defmodule BarkparkWeb.TokenSeatRestoreController do
  @moduledoc """
  `POST /v1/admin/tokens/:id/seats/restore` (task-c6185553d0bd7869). Gives a
  live API token back the workspace seats its revoked predecessor held, so
  Barkpark Cloud can repair a token a rotation left short without a root shell
  on the box. `Barkpark.Auth.TokenSeatRestore` owns the rule; read its
  moduledoc for what may be restored.

  Pipeline `[:api, :require_admin, :require_platform_operator]`, the
  instance-operator tier of `/v1/admin/*`. `:id` may be `current`, the calling
  token.

  Body: `{"workspaces": [slug], "apply": true}`. Both are optional. No
  `workspaces` means every seat a predecessor held. Without `"apply": true`
  nothing is written.

  200 → `{"token_id", "predecessors", "restore": [{"workspace", "role",
  "from_token"}], "already", "refused": [{"workspace", "reason"}], "applied"}`.
  A dry run answers 200 even when `refused` is not empty.

  Refusals: 404 `not_found` reason `token_not_found` (no such token; a box
  without this route answers 404 with no reason), 409 `conflict` reason
  `token_not_live`, 409 `conflict` reason `not_held_before` (an apply named a
  workspace no predecessor held; nothing was written, the plan rides
  `details`), 409 `conflict` reason `dataset_binding` (the first refused seat
  came from a predecessor bound to a dataset this token is not bound to), 403
  `forbidden` reason `dataset_binding` (the caller is bound to a dataset and
  the token is not bound to the same one), 422 `unprocessable` (bad body).
  """
  use BarkparkWeb, :controller

  alias Barkpark.Auth.TokenSeatRestore
  alias BarkparkWeb.ErrorResponse

  def create(conn, %{"id" => id} = params) do
    actor = conn.assigns[:api_token]
    token_id = if id == "current" and actor, do: actor.id, else: id

    with {:ok, slugs} <- fetch_workspaces(params),
         {:ok, apply?} <- fetch_apply(params),
         {:ok, plan} <- TokenSeatRestore.restore(token_id, slugs, apply: apply?, actor: actor) do
      json(conn, TokenSeatRestore.to_json(plan))
    else
      {:error, :invalid_workspaces} ->
        unprocessable(conn, "workspaces must be a list of workspace slugs")

      {:error, :invalid_apply} ->
        unprocessable(conn, "apply must be true or false")

      {:error, :token_not_found} ->
        ErrorResponse.emit_fields(conn, :not_found, %{
          code: "not_found",
          reason: "token_not_found",
          message: "no API token has that id"
        })

      {:error, :dataset_binding} ->
        ErrorResponse.emit(conn, {:error, :dataset_binding})

      {:error, :token_not_live} ->
        ErrorResponse.emit_fields(conn, :conflict, %{
          code: "conflict",
          reason: "token_not_live",
          message: "that token is revoked, expired or not an API token"
        })

      {:error, {:refused, %{refused: [%{reason: "dataset_binding"} | _]} = plan}} ->
        ErrorResponse.emit_fields(conn, :conflict, %{
          code: "conflict",
          reason: "dataset_binding",
          message:
            "a predecessor that held a seat in " <>
              Enum.map_join(plan.refused, ", ", & &1.workspace) <>
              " was bound to a dataset this token is not bound to; nothing was written",
          details: TokenSeatRestore.to_json(plan)
        })

      {:error, {:refused, plan}} ->
        ErrorResponse.emit_fields(conn, :conflict, %{
          code: "conflict",
          reason: "not_held_before",
          message:
            "no revoked predecessor of this token held a seat in " <>
              Enum.map_join(plan.refused, ", ", & &1.workspace) <> "; nothing was written",
          details: TokenSeatRestore.to_json(plan)
        })

      {:error, _reason} ->
        unprocessable(conn, "could not restore the seats; nothing was written")
    end
  end

  defp fetch_workspaces(%{"workspaces" => slugs}) when is_list(slugs) do
    if Enum.all?(slugs, &is_binary/1), do: {:ok, slugs}, else: {:error, :invalid_workspaces}
  end

  defp fetch_workspaces(%{"workspaces" => nil}), do: {:ok, []}
  defp fetch_workspaces(%{"workspaces" => _}), do: {:error, :invalid_workspaces}
  defp fetch_workspaces(_), do: {:ok, []}

  defp fetch_apply(%{"apply" => value}) when is_boolean(value), do: {:ok, value}
  defp fetch_apply(%{"apply" => nil}), do: {:ok, false}
  defp fetch_apply(%{"apply" => _}), do: {:error, :invalid_apply}
  defp fetch_apply(_), do: {:ok, false}

  defp unprocessable(conn, message) do
    ErrorResponse.emit_fields(conn, :unprocessable_entity, %{
      code: "unprocessable",
      message: message
    })
  end
end
