defmodule BarkparkWeb.MutateController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Errors

  action_fallback BarkparkWeb.FallbackController

  def mutate(conn, %{"dataset" => dataset, "mutations" => mutations}) when is_list(mutations) do
    case Content.apply_mutations(mutations, dataset) do
      {:ok, {tx_id, results}} ->
        json(conn, %{transactionId: tx_id, results: results})

      {:error, reason} ->
        env = Errors.to_envelope({:error, reason})
        conn
        |> put_status(env.status)
        |> json(%{error: Map.delete(env, :status)})
    end
  end

  def mutate(conn, _params) do
    env = Errors.to_envelope({:error, :malformed})
    conn
    |> put_status(env.status)
    |> json(%{error: Map.delete(env, :status)})
  end
end
