defmodule BarkparkWeb.HistoryController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.{Envelope, Errors}

  def index(conn, %{"dataset" => dataset, "type" => type, "doc_id" => doc_id} = params) do
    limit = parse_int(params["limit"], 50)

    revisions =
      Content.list_revisions(doc_id, type, dataset, limit: limit)
      |> Enum.map(&render_revision/1)

    json(conn, %{revisions: revisions, count: length(revisions)})
  end

  def show(conn, %{"dataset" => _dataset, "id" => id}) do
    with :ok <- validate_uuid(id),
         {:ok, rev} <- Content.get_revision(id) do
      json(conn, %{revision: render_revision_full(rev)})
    else
      {:error, :invalid_uuid} -> not_found(conn, "revision not found")
      {:error, :not_found} -> not_found(conn, "revision not found")
    end
  end

  def restore(conn, %{"dataset" => dataset, "id" => id} = params) do
    type = get_type(conn, params)

    with :ok <- validate_uuid(id),
         {:ok, doc} <- Content.restore_revision(id, type, dataset) do
      json(conn, %{restored: true, document: Envelope.render(doc)})
    else
      {:error, :invalid_uuid} -> not_found(conn, "revision not found")
      {:error, :not_found} -> not_found(conn, "revision not found")
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
      title: rev.title,
      status: rev.status,
      timestamp: rev.inserted_at
    }
  end

  defp render_revision_full(rev) do
    %{
      id: rev.id,
      doc_id: rev.doc_id,
      type: rev.type,
      dataset: rev.dataset,
      action: rev.action,
      title: rev.title,
      status: rev.status,
      content: rev.content,
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
end
