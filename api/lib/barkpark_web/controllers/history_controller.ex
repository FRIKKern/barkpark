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

  @doc """
  Read ONE revision, addressed EITHER by its `revisions` row UUID (the original
  contract) OR by a `_rev` content hash (task-8d4b1f2c7a0e3591).

  The hash arm is what makes a CITED revision retrievable. `_rev` is the token
  every envelope stamps and every seal / acceptance criterion quotes; a UUID is
  not. Before this arm a non-UUID `:id` fell straight into `{:error,
  :invalid_uuid}` → 404, so a caller holding the `_rev` of a sealed paper had no
  read anywhere in the API that could resolve it to the content it named.

  ADDITIVE, and no new route: `GET /v1/data/revision/:dataset/:id` (and the
  workspace-scoped `/w/:ws/p/:proj/...` twin) now accept both id shapes. A UUID
  behaves byte-identically to before — the hash arm is only reached once
  `validate_uuid/1` has already refused, and only for a 32-char lowercase hex
  token.

  The two arms differ in payload, honestly rather than by accident:

    * UUID → `content`, the raw `revisions.content` snapshot redacted through
      `Envelope.redact/3`.
    * hash → `document`, the stored `mutation_events.document` envelope (the
      snapshot AS OF that rev) redacted through the SAME `Envelope.redact/3`
      chokepoint — the same call the SSE delete-replay path makes on that same
      column. It is an envelope, not raw content, so it carries `_rev` and the
      caller can see the hash it asked for echoed back.
  """
  def show(conn, %{"dataset" => dataset, "id" => id}) do
    with {:error, :invalid_uuid} <- validate_uuid(id),
         {:ok, snapshot} <- Content.get_revision_by_rev(id, dataset, scope_opts(conn)) do
      schema =
        case Content.get_schema(snapshot.type, dataset, scope_opts(conn)) do
          {:ok, s} -> s
          _ -> nil
        end

      json(conn, %{
        revision: %{
          rev: snapshot.rev,
          doc_id: snapshot.doc_id,
          type: snapshot.type,
          dataset: snapshot.dataset,
          action: snapshot.action,
          # `owner_id` is unknown for a stored snapshot, so an `owner_only`
          # field conservatively drops for non-admins — fail closed, exactly as
          # the UUID arm below.
          document: Envelope.redact(snapshot.document, schema, CallerContext.from_conn(conn)),
          timestamp: snapshot.timestamp
        }
      })
    else
      # `:ok` — the id IS a UUID, so this is the original revision-row read.
      :ok -> show_by_uuid(conn, dataset, id)
      # A non-UUID that is also not a resolvable `_rev` hash.
      {:error, :not_found} -> not_found(conn, "revision not found")
    end
  end

  defp show_by_uuid(conn, dataset, id) do
    with :ok <- validate_uuid(id),
         {:ok, rev} <- Content.get_revision(id, dataset, scope_opts(conn)) do
      # WS-B (revision-detail leak): the stored snapshot `rev.content` is raw
      # plaintext — a non-encrypted `private` / `owner_only` / `readable_by`
      # field lives there in the clear. Route it through the Envelope redaction
      # boundary (the same chokepoint the sibling `restore/2` uses) so a
      # non-authorized token receives the redacted snapshot, never the raw dump.
      schema =
        case Content.get_schema(rev.type, dataset, scope_opts(conn)) do
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
        case Content.get_schema(type, dataset, scope_opts(conn)) do
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
