defmodule BarkparkWeb.MutateController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.{Errors, Warnings, WriteScope}
  alias BarkparkWeb.ErrorEnvelope

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  action_fallback BarkparkWeb.FallbackController

  def mutate(conn, %{"dataset" => dataset, "mutations" => mutations}) when is_list(mutations) do
    with {:ok, mutations} <- apply_if_match_header(conn, mutations),
         {:ok, scope, resolved} <- resolve_write_scope(conn) do
      opts = [source: :api] ++ scope

      # The advisory channel (authoring-excellence D5): the publish wall queues
      # non-blocking warnings ([{code, severity, message}]) while the batch
      # applies; they ride the SUCCESS envelope only. Reset before the batch so
      # a prior request on a reused test process can never leak entries in.
      Warnings.reset()

      case Content.apply_mutations(mutations, dataset, opts) do
        {:ok, {tx_id, results}} ->
          body = %{transactionId: tx_id, results: results}

          # The INFER half of the unscoped-write ruling NAMES the workspace it
          # chose. Present ONLY when the scope was inferred — a request that
          # said where it goes gets a byte-identical body.
          body = if resolved, do: Map.put(body, :resolvedScope, resolved), else: body

          body =
            case Warnings.drain() do
              [] -> body
              warnings -> Map.put(body, :warnings, warnings)
            end

          json(conn, body)

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

  # ── The unscoped-WRITE ruling at the door (task-6fa023cdabdc5f6a) ───────────
  #
  # Ratified on main 2026-09-05: INFER-WHEN-UNAMBIGUOUS, REFUSE-WHEN-AMBIGUOUS,
  # never log-only. `Content.WriteScope` enforces it for every writer; this door
  # exists because of a SECOND way to arrive unscoped that the seam cannot see.
  #
  # `pipeline :api` runs `DeriveWorkspaceFromToken` then `AssignDefaultScope`.
  # When the path carries no `/w/:workspace_slug` AND the token carries no
  # `workspace_id`, the derivation no-ops and `AssignDefaultScope` stamps the
  # seeded Default — so `scope_opts/1` hands the write a real workspace id that
  # NOBODY CHOSE. That is the silent misattribution the ruling retires, and by
  # the time it reaches `WriteScope` it is indistinguishable from a request that
  # genuinely meant Default. Only here, with the conn, is the difference legible.
  #
  # So: when nothing about the REQUEST named a workspace, replace the guess with
  # the ruling's answer — the one workspace the credential can mean (stamped AND
  # named back in `resolvedScope`), or a typed 422 that names the door to use.
  # `:project_id` is dropped with it: the Default Project belongs to the Default
  # Workspace, and `WriteScope` resolves the inferred workspace's OWN default
  # project instead (pairing workspace A with Default's project stamps a
  # cross-tenant `project_id` — see `AssignDefaultScope`'s moduledoc).
  #
  # A request that DID name a workspace (a scoped route, or a workspace-bound
  # token) returns here unchanged, and `resolved` is nil so its response body is
  # byte-identical to before.
  defp resolve_write_scope(conn) do
    opts = scope_opts(conn)

    if request_named_a_workspace?(conn) do
      {:ok, opts, nil}
    else
      case WriteScope.infer_write_workspace(Keyword.get(opts, :caller_context)) do
        {:ok, workspace} ->
          opts =
            opts
            |> Keyword.delete(:project_id)
            |> Keyword.put(:workspace_id, workspace.id)

          {:ok, opts, %{workspaceId: workspace.id, workspaceSlug: workspace.slug}}

        {:error, :workspace_scope_required} ->
          {:error, {:workspace_scope_required, writable_workspace_slugs(opts)}}
      end
    end
  end

  # The two ways a request can name its own tenant: the scoped route's path
  # slug, or a token bound to one workspace. Nothing else assigned
  # `:current_workspace` on this pipeline.
  defp request_named_a_workspace?(conn) do
    is_binary(conn.path_params["workspace_slug"]) or
      match?(%{workspace_id: ws} when is_binary(ws), conn.assigns[:api_token])
  end

  # The slugs the refusal offers the caller — empty for a platform token, which
  # is itself the answer ("this credential is bound to no workspace").
  defp writable_workspace_slugs(opts) do
    case Keyword.get(opts, :caller_context) do
      %Barkpark.Content.CallerContext{principal_type: :user, user_id: uid}
      when is_binary(uid) ->
        slugs(Barkpark.Tenancy.list_workspaces_for(%Barkpark.Accounts.User{id: uid}))

      %Barkpark.Content.CallerContext{principal_type: :api_token, token_id: tid}
      when is_binary(tid) ->
        slugs(Barkpark.Tenancy.list_workspaces_for(tid))

      _ ->
        []
    end
  end

  defp slugs(workspaces), do: Enum.map(workspaces, & &1.slug)

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
