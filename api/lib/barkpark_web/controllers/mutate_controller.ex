defmodule BarkparkWeb.MutateController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Errors
  alias BarkparkWeb.ErrorEnvelope

  action_fallback BarkparkWeb.FallbackController

  def mutate(conn, %{"dataset" => dataset, "mutations" => mutations}) when is_list(mutations) do
    mutations = apply_if_match_header(conn, mutations)

    case Content.apply_mutations(mutations, dataset) do
      {:ok, {tx_id, results}} ->
        json(conn, %{transactionId: tx_id, results: results})

      {:error, reason} ->
        respond_with_error(conn, reason)
    end
  end

  def mutate(conn, _params) do
    respond_with_error(conn, :malformed)
  end

  defp respond_with_error(conn, reason) do
    env = Errors.to_envelope({:error, reason}, conn)
    body = render_error_body(conn, env)

    conn
    |> put_status(env.status)
    |> json(%{error: body})
  end

  defp render_error_body(conn, env) do
    base = Map.delete(env, :status)
    version = Map.get(conn.assigns, :error_envelope_version, :v1)

    if version == :v2 and validation_failed?(env) do
      base
      |> Map.delete(:details)
      |> Map.merge(ErrorEnvelope.serialize_v2(Map.get(env, :details, %{})))
    else
      base
    end
  end

  defp validation_failed?(%{code: "validation_failed", details: %{}}), do: true
  defp validation_failed?(_), do: false

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
