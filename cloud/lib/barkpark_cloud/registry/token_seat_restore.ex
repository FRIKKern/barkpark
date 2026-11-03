defmodule BarkparkCloud.Registry.TokenSeatRestore do
  @moduledoc """
  Give a token on a box back the workspace seats its revoked predecessor held
  (`POST /v1/operator/barkparks/:id/token-seats/restore`,
  `bp barkparks repair-token-seats`). Operator only. Task-c6185553d0bd7869.

  An admin-token rotation from before the rotation carried every seat
  (task-86e3a3a0c885097a) left the successor seated in one workspace. The box
  repair `mix barkpark.token_seat` needs a root shell. This module asks the
  box instead, with the admin token Cloud holds:

      POST <url>/v1/admin/tokens/<token id | current>/seats/restore
           {"workspaces": [slug], "apply": bool}

  The box decides what may be restored. It reads the token's predecessors from
  its own `token_minted` and `token_revoked` audit rows, follows only minters
  that rotated themselves out, and restores only seats one of them held,
  never above that predecessor's role
  (`Barkpark.Auth.TokenSeatRestore` in api/). Cloud sends no lineage of its
  own, so a wrong or hostile request to Cloud cannot widen what the box
  allows. Without `apply` the box writes nothing and answers with the plan.

  Transport is the `:studio_link_http_client` seam every instance call uses.
  No secret is sent back; the plan names token ids, slugs and roles.
  """

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.Barkpark

  @typedoc "Why a restore stopped. Nothing was written on the box for any of these."
  @type refusal ::
          :not_live
          | :no_admin_token
          | :decrypt_failed
          | :unreachable
          | {:held_token_refused, non_neg_integer()}
          | {:box_too_old, String.t()}
          | :token_not_found
          | :token_not_live
          | {:not_held_before, map()}
          | {:restore_refused, non_neg_integer(), String.t() | nil}

  @doc """
  Ask the box to restore seats. `token_id` is a token id, or `nil` for the
  token Cloud holds. `workspaces` may be `[]`, meaning every seat a
  predecessor held. Returns `{:ok, plan}` with the box's plan (`applied` says
  whether it wrote), or `{:error, refusal}`.
  """
  @spec restore(Barkpark.t(), String.t() | nil, [String.t()], boolean()) ::
          {:ok, map()} | {:error, refusal()}
  def restore(%Barkpark{} = bp, token_id, workspaces, apply?)
      when is_list(workspaces) and is_boolean(apply?) do
    with {:ok, base} <- base_url(bp),
         {:ok, held} <- held_token(bp) do
      target = if is_binary(token_id) and token_id != "", do: token_id, else: "current"
      path = "/v1/admin/tokens/#{URI.encode(target, &URI.char_unreserved?/1)}/seats/restore"

      case request(base, path, held, %{workspaces: workspaces, apply: apply?}) do
        {:ok, 200, %{"token_id" => _} = plan} ->
          {:ok, plan}

        {:ok, 404, body} ->
          if reason(body) == "token_not_found",
            do: {:error, :token_not_found},
            else: {:error, {:box_too_old, "POST /v1/admin/tokens/:id/seats/restore"}}

        {:ok, 409, body} ->
          case reason(body) do
            "token_not_live" -> {:error, :token_not_live}
            "not_held_before" -> {:error, {:not_held_before, details(body)}}
            other -> {:error, {:restore_refused, 409, other}}
          end

        {:ok, status, _} when status in [401, 403] ->
          {:error, {:held_token_refused, status}}

        {:ok, status, body} ->
          {:error, {:restore_refused, status, reason(body)}}

        {:error, :unreachable} ->
          {:error, :unreachable}
      end
    end
  end

  defp base_url(%Barkpark{url: url}) when is_binary(url) and url != "",
    do: {:ok, String.trim_trailing(url, "/")}

  defp base_url(_), do: {:error, :not_live}

  defp held_token(bp) do
    case Registry.reveal_admin_token(bp) do
      {:ok, nil} -> {:error, :no_admin_token}
      {:ok, token} -> {:ok, token}
      :error -> {:error, :decrypt_failed}
    end
  end

  # The box's envelope is `{"error": {"code", "reason", "message", "details"}}`.
  defp reason(%{"error" => %{} = err}), do: err["reason"] || err["code"]
  defp reason(_), do: nil

  defp details(%{"error" => %{"details" => %{} = d}}), do: d
  defp details(_), do: %{}

  defp request(base, path, bearer, body) do
    req = %{
      method: :post,
      url: base <> path,
      headers: [
        {"Authorization", "Bearer " <> bearer},
        {"Accept", "application/json"},
        {"Content-Type", "application/json"}
      ],
      body: Jason.encode!(body)
    }

    case http_client().request(req) do
      {:ok, %{status: status, body: resp}} when is_integer(status) ->
        case Jason.decode(resp || "") do
          {:ok, %{} = decoded} -> {:ok, status, decoded}
          _ -> {:ok, status, %{}}
        end

      _ ->
        {:error, :unreachable}
    end
  end

  defp http_client do
    Application.get_env(
      :barkpark_cloud,
      :studio_link_http_client,
      BarkparkCloud.Billing.HttpClient
    )
  end
end
