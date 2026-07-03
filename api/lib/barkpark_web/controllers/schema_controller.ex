defmodule BarkparkWeb.SchemaController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  action_fallback BarkparkWeb.FallbackController

  def index(conn, %{"dataset" => dataset}) do
    envelope = Content.list_schemas_for_sdk(dataset, scope_opts(conn))
    json(conn, Map.put(envelope, :_schemaVersion, 1))
  end

  def show(conn, %{"dataset" => dataset, "name" => name}) do
    with {:ok, schema} <- Content.get_schema(name, dataset, scope_opts(conn)) do
      json(conn, %{_schemaVersion: 1, schema: Content.serialize_schema_for_sdk(schema)})
    end
  end

  def upsert(conn, %{"dataset" => dataset} = params) do
    attrs = Map.drop(params, ["dataset"])

    # Validate the `fields` payload at WRITE time so structurally-invalid field
    # defs (missing names, bad v2 types, reserved `plugin:` prefixes) fail with a
    # clean 422 here instead of blowing up later at document-validation time.
    # Gated on a `fields` key actually being present: a partial in-place update
    # that omits `fields` leaves the stored (already-valid) definition untouched
    # and is never re-validated, so previously-valid rows never get false 422s.
    with :ok <- validate_fields(attrs),
         {:ok, schema} <- Content.upsert_schema(attrs, dataset, scope_opts(conn)) do
      conn
      |> put_status(:created)
      |> json(render_schema(schema))
    end
  end

  # `plugin: nil` — the ad-hoc admin endpoint is not a plugin, so field names in
  # the reserved `plugin:` namespace are rejected (only a plugin's own
  # `register_schemas/1` may declare them). An empty/absent `fields` payload is a
  # legitimate partial update and skips validation entirely.
  defp validate_fields(attrs) do
    if Map.has_key?(attrs, "fields") or Map.has_key?(attrs, :fields) do
      case SchemaDefinition.parse(attrs, plugin: nil) do
        {:ok, _parsed} -> :ok
        {:error, reason} -> {:error, {:invalid_schema_fields, reason}}
      end
    else
      :ok
    end
  end

  # `?force=true` opts into orphaning existing documents of the type. Without it,
  # deleting a schema that still has documents is refused with a 409
  # `schema_has_documents` (see Content.Schema.delete_schema/3) so a public type
  # can't be silently removed out from under its now-unreadable documents.
  def delete(conn, %{"dataset" => dataset, "name" => name} = params) do
    opts = Keyword.put(scope_opts(conn), :force, force_param?(params))

    with {:ok, _} <- Content.delete_schema(name, dataset, opts) do
      json(conn, %{deleted: name})
    end
  end

  defp force_param?(params) do
    case Map.get(params, "force") do
      v when v in [true, "true", "1"] -> true
      _ -> false
    end
  end

  defp render_schema(schema) do
    %{
      name: schema.name,
      title: schema.title,
      icon: schema.icon,
      visibility: schema.visibility,
      fields: schema.fields,
      actions: schema.actions || []
    }
  end
end
