defmodule BarkparkWeb.MutateController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.Errors
  alias BarkparkWeb.ErrorEnvelope

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  action_fallback BarkparkWeb.FallbackController

  def mutate(conn, %{"dataset" => dataset, "mutations" => mutations}) when is_list(mutations) do
    with {:ok, mutations} <- apply_if_match_header(conn, mutations) do
      opts = [source: :api] ++ scope_opts(conn)

      case Content.apply_mutations(mutations, dataset, opts) do
        {:ok, {tx_id, results}} ->
          json(conn, %{transactionId: tx_id, results: results})

        {:error, {:halted, reason}} ->
          # Lifecycle-hook veto (per plan §0 Q4): a plugin's before_* hook
          # returned {:halt, reason}. Route through the CANONICAL envelope (409)
          # so the bp CLI + SDK can key on error.code and read request_id — was a
          # bare %{error: "halted", reason: reason} that carried neither and
          # broke every machine consumer. The reason becomes error.message.
          respond_with_error(conn, {:halted, reason})

        {:error, reason} ->
          respond_with_error(conn, reason)
      end
    else
      {:error, reason} -> respond_with_error(conn, reason)
    end
  end

  def mutate(conn, _params) do
    respond_with_error(conn, :malformed)
  end

  # Tenancy scope opts come from BarkparkWeb.ScopeHelpers.scope_opts/1, the
  # shared seam over the conn assigns set by ResolveWorkspace / ResolveProject
  # (scoped routes) or AssignDefaultScope (flat back-compat routes). The same
  # WHERE workspace_id gate, applied on the WRITE side: new rows are STAMPED
  # with this scope via Content.put_scope_attrs/2.

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

  # Single-op batch: the one HTTP If-Match ETag unambiguously targets the one
  # document, so inject it as that op's ifMatch (a per-op ifMatch/ifRevisionID in
  # the body still wins — Map.put_new never overwrites it).
  defp apply_if_match_header(conn, [mutation] = _mutations) do
    case if_match_header(conn) do
      nil -> {:ok, [mutation]}
      rev -> {:ok, [inject_if_match(mutation, rev)]}
    end
  end

  # Multi-op batch: a single HTTP If-Match ETag cannot sensibly gate N different
  # documents. The old code silently DROPPED the header here (fell through to a
  # no-op catch-all), so a caller's optimistic-lock intent evaporated and every
  # op applied last-write-wins with no 412 → lost update. Fail CLOSED with a 400
  # that steers the caller to the per-op ifRevisionID/ifMatch mechanism
  # (Content.Mutations.if_rev/1), which fences each document unambiguously and
  # works for any batch size. When no If-Match header is present the batch is
  # accepted unchanged (per-op fences, if any, still apply downstream).
  defp apply_if_match_header(conn, mutations) when is_list(mutations) do
    case if_match_header(conn) do
      nil -> {:ok, mutations}
      _rev -> {:error, :unsupported_if_match_for_batch}
    end
  end

  defp if_match_header(conn) do
    case get_req_header(conn, "if-match") do
      [value | _] when is_binary(value) and value != "" -> unquote_etag(value)
      _ -> nil
    end
  end

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
