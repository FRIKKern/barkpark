defmodule BarkparkWeb.MutateController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Errors
  alias BarkparkWeb.ErrorEnvelope

  action_fallback BarkparkWeb.FallbackController

  def mutate(conn, %{"dataset" => dataset, "mutations" => mutations}) when is_list(mutations) do
    mutations = apply_if_match_header(conn, mutations)
    opts = [source: :api] ++ scope_opts(conn)

    case Content.apply_mutations(mutations, dataset, opts) do
      {:ok, {tx_id, results}} ->
        json(conn, %{transactionId: tx_id, results: results})

      {:error, {:halted, reason}} ->
        # Lifecycle-hook veto (per plan §0 Q4). HTTP 409 Conflict with a
        # stable error shape so plugin authors can rely on it.
        conn
        |> put_status(:conflict)
        |> json(%{error: "halted", reason: reason})

      {:error, reason} ->
        respond_with_error(conn, reason)
    end
  end

  def mutate(conn, _params) do
    respond_with_error(conn, :malformed)
  end

  # Tenancy scope opts pulled from the conn assigns set by ResolveWorkspace /
  # ResolveProject (scoped routes) or AssignDefaultScope (flat back-compat
  # routes). Mirrors QueryController.scope_opts/1 — the same WHERE workspace_id
  # gate, applied on the WRITE side: new rows are STAMPED with this scope via
  # Content.put_scope_attrs/2 (the s2 stamping mechanism). When neither assign
  # is set (a fresh DB before the Default backfill), the opts are empty and the
  # write lands unscoped — put_scope_attrs no-ops on nil, never nulling scope.
  defp scope_opts(conn) do
    []
    |> put_scope(:workspace_id, conn.assigns[:current_workspace])
    |> put_scope(:project_id, conn.assigns[:current_project])
  end

  defp put_scope(opts, _key, nil), do: opts
  defp put_scope(opts, key, %{id: id}), do: Keyword.put(opts, key, id)
  defp put_scope(opts, _key, _other), do: opts

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
