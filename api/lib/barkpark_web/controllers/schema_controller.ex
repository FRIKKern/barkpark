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

  @doc """
  Create or replace a schema definition — `POST /v1/schemas/:dataset`.

  ## `validate_only` — validate without writing (task-19b7ca7ff92fb710 #21)

  A truthy `validate_only` (body or query string; `true`, `"true"` or `"1"`)
  runs the ENTIRE pipeline the write runs — `validate_fields/1` plus
  `Content.Schema.validate_schema/3`'s fail-closed scope stamp and the
  `SchemaDefinition` changeset — and answers with the verdict WITHOUT calling
  `Content.upsert_schema/3`. Nothing is written: no row appears, an existing
  row keeps its stored definition byte for byte, and no write event is emitted.

  Refusals are IDENTICAL to the write's — the same 422s from the same two
  seams, so a caller can trust a green verdict to mean the same payload would
  be accepted. Success answers **200, not the write's 201**: `201 Created`
  would be a lie about a row that does not exist. The body is the schema that
  WOULD have been stored, through the same `serialize_schema_for_sdk/1` the
  write echoes, so a client can diff a proposed definition against the live one
  without a round trip through the store.

  ONE THING IT CANNOT PROMISE: `validate_schema/3` never reaches Postgres, so
  the `(name, dataset_id)` uniqueness constraints are not evaluated. A green
  verdict is "well-formed and in scope", not a reservation.

  Spelled `validate_only`, deliberately NOT `dry_run`: `--dry-run` is a GLOBAL
  bp flag that short-circuits CLIENT-side before the request is ever sent
  (`internal/cli/run.go`), so reusing that name would leave a caller unable to
  tell which of the two halves they were asking for.
  """
  def upsert(conn, %{"dataset" => dataset} = params) do
    attrs = Map.drop(params, ["dataset", "validate_only"])

    # Validate the `fields` payload at WRITE time so structurally-invalid field
    # defs (missing names, bad v2 types, reserved `plugin:` prefixes) fail with a
    # clean 422 here instead of blowing up later at document-validation time.
    # Gated on a `fields` key actually being present: a partial in-place update
    # that omits `fields` leaves the stored (already-valid) definition untouched
    # and is never re-validated, so previously-valid rows never get false 422s.
    #
    # BOTH branches run `validate_fields/1` first, from the same call site, so
    # the validate-only verdict cannot drift from the write's refusal set.
    if validate_only?(params) do
      with :ok <- validate_fields(attrs),
           {:ok, schema} <- Content.Schema.validate_schema(attrs, dataset, scope_opts(conn)) do
        conn
        |> put_status(:ok)
        |> json(Content.serialize_schema_for_sdk(schema))
      end
    else
      with :ok <- validate_fields(attrs),
           {:ok, schema} <- Content.upsert_schema(attrs, dataset, scope_opts(conn)) do
        conn
        |> put_status(:created)
        |> json(Content.serialize_schema_for_sdk(schema))
      end
    end
  end

  defp validate_only?(params), do: truthy_param?(params, "validate_only")

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

    # RECEIPT LAW (pds w39): the emitted value DESCENDS FROM THE WRITE RETURN.
    # `delete_schema/3` already hands back the row `Repo.delete/2` removed
    # (content/schema.ex:181-206) — this used to discard it and echo the `:name`
    # path param, so the printed sentence could not change if the store said
    # something else. `id` is the store's own binary_id: it appears nowhere in
    # the request, so a revert to echoing `name` cannot reproduce this body.
    with {:ok, %SchemaDefinition{} = deleted} <- Content.delete_schema(name, dataset, opts) do
      json(conn, %{deleted: deleted.name, id: deleted.id, dataset: deleted.dataset})
    end
  end

  defp force_param?(params), do: truthy_param?(params, "force")

  # One truthiness rule for every boolean request param on this controller —
  # `?force=true` and `validate_only` must not drift into disagreeing about
  # what "1" means.
  defp truthy_param?(params, key) do
    case Map.get(params, key) do
      v when v in [true, "true", "1"] -> true
      _ -> false
    end
  end
end
