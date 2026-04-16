defmodule BarkparkWeb.WebhookController do
  use BarkparkWeb, :controller

  alias Barkpark.Webhooks

  def index(conn, %{"dataset" => dataset}) do
    hooks = Webhooks.list_webhooks(dataset)
    json(conn, %{webhooks: Enum.map(hooks, &render_webhook/1)})
  end

  def show(conn, %{"id" => id}) do
    with :ok <- validate_uuid(id),
         {:ok, wh} <- Webhooks.get_webhook(id) do
      json(conn, %{webhook: render_webhook(wh)})
    else
      _ -> conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "webhook not found"}})
    end
  end

  def create(conn, %{"dataset" => dataset} = params) do
    attrs = Map.put(params, "dataset", dataset)

    case Webhooks.create_webhook(attrs) do
      {:ok, wh} ->
        conn |> put_status(201) |> json(%{webhook: render_webhook(wh)})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: %{code: "validation_failed", details: format_errors(changeset)}})
    end
  end

  def update(conn, %{"id" => id} = params) do
    with :ok <- validate_uuid(id),
         {:ok, wh} <- Webhooks.get_webhook(id),
         {:ok, updated} <- Webhooks.update_webhook(wh, params) do
      json(conn, %{webhook: render_webhook(updated)})
    else
      {:error, :invalid_uuid} ->
        conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "webhook not found"}})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "webhook not found"}})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: %{code: "validation_failed", details: format_errors(changeset)}})
    end
  end

  def delete(conn, %{"id" => id}) do
    with :ok <- validate_uuid(id),
         {:ok, wh} <- Webhooks.get_webhook(id),
         {:ok, _} <- Webhooks.delete_webhook(wh) do
      json(conn, %{deleted: id})
    else
      _ -> conn |> put_status(404) |> json(%{error: %{code: "not_found", message: "webhook not found"}})
    end
  end

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  defp validate_uuid(id) when is_binary(id) do
    if Regex.match?(@uuid_regex, id), do: :ok, else: {:error, :invalid_uuid}
  end

  defp render_webhook(wh) do
    %{
      id: wh.id,
      name: wh.name,
      url: wh.url,
      dataset: wh.dataset,
      events: wh.events,
      types: wh.types,
      active: wh.active,
      created_at: wh.inserted_at,
      updated_at: wh.updated_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
