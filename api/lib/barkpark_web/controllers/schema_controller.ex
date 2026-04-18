defmodule BarkparkWeb.SchemaController do
  use BarkparkWeb, :controller

  alias Barkpark.Content

  action_fallback BarkparkWeb.FallbackController

  def index(conn, %{"dataset" => dataset}) do
    envelope = Content.list_schemas_for_sdk(dataset)
    json(conn, Map.put(envelope, :_schemaVersion, 1))
  end

  def show(conn, %{"dataset" => dataset, "name" => name}) do
    with {:ok, schema} <- Content.get_schema(name, dataset) do
      json(conn, %{_schemaVersion: 1, schema: Content.serialize_schema_for_sdk(schema)})
    end
  end

  def upsert(conn, %{"dataset" => dataset} = params) do
    attrs = Map.drop(params, ["dataset"])

    case Content.upsert_schema(attrs, dataset) do
      {:ok, schema} ->
        conn
        |> put_status(:created)
        |> json(render_schema(schema))

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete(conn, %{"dataset" => dataset, "name" => name}) do
    with {:ok, _} <- Content.delete_schema(name, dataset) do
      json(conn, %{deleted: name})
    end
  end

  defp render_schema(schema) do
    %{
      name: schema.name,
      title: schema.title,
      icon: schema.icon,
      visibility: schema.visibility,
      fields: schema.fields
    }
  end
end
