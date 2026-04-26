defmodule BarkparkWeb.MutateController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Errors

  action_fallback BarkparkWeb.FallbackController

  def mutate(conn, %{"dataset" => dataset, "mutations" => mutations}) when is_list(mutations) do
    mutations = apply_if_match_header(conn, mutations)

    case Content.apply_mutations(mutations, dataset) do
      {:ok, {tx_id, results}} ->
        json(conn, %{transactionId: tx_id, results: results})

      {:error, reason} ->
        env = Errors.to_envelope({:error, reason}, conn)

        conn
        |> put_status(env.status)
        |> json(%{error: Map.delete(env, :status)})
    end
  end

  def mutate(conn, _params) do
    env = Errors.to_envelope({:error, :malformed}, conn)

    conn
    |> put_status(env.status)
    |> json(%{error: Map.delete(env, :status)})
  end

  defp apply_if_match_header(conn, [mutation] = _mutations) do
    case get_req_header(conn, "if-match") do
      [value | _] when is_binary(value) and value != "" ->
        [inject_if_match(mutation, unquote_etag(value))]

      _ ->
        [mutation]
    end
  end

  defp apply_if_match_header(_conn, mutations), do: mutations

  defp inject_if_match(mutation, rev) when is_map(mutation) do
    Enum.into(mutation, %{}, fn
      {op, %{} = payload} -> {op, Map.put_new(payload, "ifMatch", rev)}
      pair -> pair
    end)
  end

  defp inject_if_match(mutation, _rev), do: mutation

  defp unquote_etag(value) do
    value
    |> String.trim()
    |> String.trim_leading("W/")
    |> String.trim()
    |> String.trim("\"")
  end
end
