defmodule BarkparkWeb.HistoryController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Envelope, Errors}

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  def index(conn, %{"dataset" => dataset, "type" => type, "doc_id" => doc_id} = params) do
    limit = parse_int(params["limit"], 50)

    revisions =
      Content.list_revisions(doc_id, type, dataset, [limit: limit] ++ scope_opts(conn))
      |> Enum.map(&render_revision/1)

    json(conn, %{revisions: revisions, count: length(revisions)})
  end

  def show(conn, %{"dataset" => dataset, "id" => id}) do
    with {:ok, rev} <- resolve_revision(id, dataset, scope_opts(conn)) do
      # WS-B (revision-detail leak): the stored snapshot `rev.content` is raw
      # plaintext — a non-encrypted `private` / `owner_only` / `readable_by`
      # field lives there in the clear. Route it through the Envelope redaction
      # boundary (the same chokepoint the sibling `restore/2` uses) so a
      # non-authorized token receives the redacted snapshot, never the raw dump.
      schema =
        case Content.Schema.get_schema_for_redaction(rev.type, dataset, scope_opts(conn)) do
          {:ok, s} -> s
          _ -> nil
        end

      caller_context = CallerContext.from_conn(conn)
      json(conn, %{revision: render_revision_full(rev, schema, caller_context)})
    else
      {:error, :invalid_uuid} -> not_found(conn, "revision not found")
      {:error, :not_found} -> not_found(conn, "revision not found")
    end
  end

  def restore(conn, %{"dataset" => dataset, "id" => id} = params) do
    type = get_type(conn, params)

    with :ok <- validate_uuid(id),
         {:ok, doc} <-
           Content.restore_revision(id, type, dataset, [source: :api] ++ scope_opts(conn)) do
      schema =
        case Content.Schema.get_schema_for_redaction(type, dataset, scope_opts(conn)) do
          {:ok, s} -> s
          _ -> nil
        end

      json(conn, %{
        restored: true,
        document: Envelope.render(doc, schema, CallerContext.from_conn(conn))
      })
    else
      {:error, :invalid_uuid} ->
        not_found(conn, "revision not found")

      {:error, :not_found} ->
        not_found(conn, "revision not found")

      {:error, {:halted, _reason}} = halt ->
        # Plugin lifecycle veto on the restore. Render the CANONICAL envelope
        # (code "halted", 409, request_id, hint) via the same Errors.to_envelope
        # path as not_found/2 — was a bare %{error: "halted", reason: reason}
        # with no code/request_id, undecodable by the bp CLI + SDK.
        env = Errors.to_envelope(halt, conn)

        conn
        |> put_status(env.status)
        |> json(%{error: Map.delete(env, :status)})
    end
  end

  defp get_type(_conn, params), do: params["type"]

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  defp validate_uuid(id) when is_binary(id) do
    if Regex.match?(@uuid_regex, id), do: :ok, else: {:error, :invalid_uuid}
  end

  # [rev-hash-has-no-read] `GET /v1/data/revision/:dataset/:id` accepts EITHER a
  # revision UUID or a document `_rev` hash. The envelope publishes `"_rev"` on
  # every read and acceptance criteria cite it, but the hash previously resolved
  # to nothing: this path 404'd every non-UUID before it ever reached a lookup.
  #
  # Surfacing it HERE — rather than on a new route — is deliberate: the read is
  # already reachable, already token-gated, and already carries the dataset /
  # workspace / grant scoping, so an existing CLI verb starts resolving `_rev`
  # with no new surface to secure. The two id shapes are disjoint (a `_rev` hash
  # is not UUID-shaped), so a UUID caller's behaviour is byte-identical.
  #
  # `get_revision_by_rev/3` applies the SAME scope clauses as `get_revision/3`,
  # so this is a new key on the existing read, never a wider one.
  defp resolve_revision(id, dataset, opts) do
    case validate_uuid(id) do
      :ok -> Content.get_revision(id, dataset, opts)
      {:error, :invalid_uuid} -> Content.get_revision_by_rev(id, dataset, opts)
    end
  end

  defp not_found(conn, message) do
    env =
      {:error, :not_found}
      |> Errors.to_envelope(conn)
      |> Map.put(:message, message)

    conn
    |> put_status(env.status)
    |> json(%{error: Map.delete(env, :status)})
  end

  defp render_revision(rev) do
    %{
      id: rev.id,
      action: rev.action,
      # [rev-hash-has-no-read] The document `_rev` this entry captured — the
      # same hash the envelope publishes. Surfacing it in the LISTING is what
      # lets a seal citing a `_rev` be matched to its history entry by eye;
      # without it a caller holding a hash had nothing to compare against.
      # NULL on history written before the column existed.
      rev: rev.rev,
      actor_user_id: rev.actor_user_id,
      title: rev.title,
      status: rev.status,
      timestamp: rev.inserted_at
    }
  end

  defp render_revision_full(rev, schema, caller_context) do
    %{
      id: rev.id,
      doc_id: rev.doc_id,
      type: rev.type,
      dataset: rev.dataset,
      action: rev.action,
      rev: rev.rev,
      actor_user_id: rev.actor_user_id,
      title: rev.title,
      status: rev.status,
      # `owner_id` is unknown for a stored snapshot (revisions carry none), so an
      # `owner_only` field conservatively drops for non-admins — fail closed.
      content: Envelope.redact(rev.content || %{}, schema, caller_context),
      timestamp: rev.inserted_at
    }
  end

  defp parse_int(nil, default), do: default

  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> min(max(n, 1), 200)
      :error -> default
    end
  end

  defp parse_int(val, _default) when is_integer(val), do: min(max(val, 1), 200)

  # Catch-all: a list param (`?limit[]=1` → Plug parses to `["1"]`) or any other
  # non-scalar falls back to the default instead of raising FunctionClauseError → 500.
  defp parse_int(_, default), do: default
end
