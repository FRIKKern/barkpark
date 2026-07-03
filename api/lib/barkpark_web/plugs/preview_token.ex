defmodule BarkparkWeb.Plugs.PreviewToken do
  @moduledoc """
  Verifies a short-lived preview JWT from `Authorization: Preview <jwt>`
  or `?preview_token=<jwt>`. Forces perspective to drafts on success.
  """

  import Plug.Conn

  alias Barkpark.Content.Errors
  alias Barkpark.PreviewToken

  def init(opts), do: opts

  def call(conn, _opts) do
    secret = Application.get_env(:barkpark, :preview, [])[:secret]

    with raw when is_binary(raw) <- extract_token(conn),
         true <- is_binary(secret) and byte_size(secret) > 0,
         {:ok, claims} <- PreviewToken.verify(raw, secret),
         :ok <- check_dataset_scope(conn, claims),
         {:ok, _} <- PreviewToken.record_jti(claims) do
      conn
      |> assign(:preview_claims, claims)
      |> assign(:forced_perspective, "drafts")
    else
      {:error, :already_used} -> deny(conn, :replay)
      {:error, :dataset_mismatch} -> deny(conn, :forbidden)
      _ -> deny(conn, :unauthorized)
    end
  end

  # Bind the token's `dataset` claim to the dataset the request actually reads.
  # Without this a token minted for one dataset (e.g. `production`) could read
  # drafts from ANY other dataset in the same workspace simply by typing that
  # dataset into the `/v1/preview/.../:dataset/...` path — cross-dataset draft
  # scope escalation. The check runs BEFORE `record_jti` so a wrong-dataset
  # attempt never consumes (burns) the JTI of an otherwise-legitimate token.
  #
  #   * claim carries no dataset  → :ok here; `record_jti` rejects it (:invalid
  #     → 401), preserving the pre-existing "missing dataset claim" contract.
  #   * route carries no :dataset → :ok (no such preview route today; keeps the
  #     plug route-agnostic rather than failing shapes it can't bind).
  #   * both present + differ     → {:error, :dataset_mismatch} → 403.
  defp check_dataset_scope(conn, claims) do
    route_ds = conn.path_params["dataset"]
    claim_ds = Map.get(claims, "dataset")

    cond do
      not is_binary(claim_ds) -> :ok
      not is_binary(route_ds) -> :ok
      claim_ds == route_ds -> :ok
      true -> {:error, :dataset_mismatch}
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Preview " <> jwt] ->
        jwt

      _ ->
        conn = fetch_query_params(conn)
        conn.query_params["preview_token"]
    end
  end

  defp deny(conn, reason) do
    env = Errors.to_envelope({:error, reason}, conn)

    conn
    |> put_status(env.status)
    |> Phoenix.Controller.json(%{error: Map.delete(env, :status)})
    |> halt()
  end
end
