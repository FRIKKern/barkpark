defmodule BarkparkWeb.SchemaController do
  use BarkparkWeb, :controller

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Content.SchemaUnknownKeys

  import BarkparkWeb.ScopeHelpers, only: [scope_opts: 1]

  action_fallback BarkparkWeb.FallbackController

  def index(conn, %{"dataset" => dataset}) do
    envelope = Content.list_schemas_for_sdk(dataset, scope_opts(conn))
    json(conn, Map.put(envelope, :_schemaVersion, 1))
  end

  def show(conn, %{"dataset" => dataset, "name" => name}) do
    case Content.get_schema(name, dataset, scope_opts(conn)) do
      {:ok, schema} ->
        json(conn, %{_schemaVersion: 1, schema: Content.serialize_schema_for_sdk(schema)})

      # The bare {:error, :not_found} renders "document not found" with a hint to
      # check a document _id; what is missing here is a SCHEMA
      # (task-8d46c1fe49954697), so name it and point at the listing.
      {:error, :not_found} ->
        {:error,
         {:not_found,
          "schema not found: no schema named #{inspect(name)} in dataset #{inspect(dataset)}",
          hint:
            "Check the schema name and dataset in the URL — GET /v1/schemas/#{dataset} lists the schemas you can read here."}}

      other ->
        other
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
        |> json(with_key_warnings(Content.serialize_schema_for_sdk(schema), attrs, conn))
      end
    else
      with :ok <- validate_fields(attrs),
           {:ok, schema} <- Content.upsert_schema(attrs, dataset, scope_opts(conn)) do
        conn
        |> put_status(:created)
        |> json(with_key_warnings(Content.serialize_schema_for_sdk(schema), attrs, conn))
      end
    end
  end

  defp validate_only?(params), do: truthy_param?(params, "validate_only")

  # task-415c5c02fad8a3c7 — a misspelled key (`requred`, `requird`,
  # `singelton`) used to vanish without a word. Each key Barkpark never reads
  # now rides the success body as an advisory `warnings` entry naming its
  # path. ADVISORY ONLY: refusing them is an open owner decision. A body with
  # no unknown key keeps its exact pre-existing shape (no `warnings` key).
  defp with_key_warnings(body, attrs, conn) do
    case SchemaUnknownKeys.unknown(Map.drop(attrs, Map.keys(conn.path_params))) do
      [] ->
        body

      found ->
        Map.put(
          body,
          :warnings,
          Enum.map(found, fn a ->
            %{code: "schema_unknown_key", severity: "advisory", message: a.message, path: a.path}
          end)
        )
    end
  end

  # `plugin: nil` — the ad-hoc admin endpoint is not a plugin, so field names in
  # the reserved `plugin:` namespace are rejected (only a plugin's own
  # `register_schemas/1` may declare them). An empty/absent `fields` payload is a
  # legitimate partial update and skips validation entirely.
  defp validate_fields(attrs) do
    if Map.has_key?(attrs, "fields") or Map.has_key?(attrs, :fields) do
      with {:ok, _parsed} <- SchemaDefinition.parse(attrs, plugin: nil),
           :ok <- refuse_reserved_status(attrs) do
        :ok
      else
        {:error, {:invalid_schema_fields, _}} = err -> err
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
  # ANCHORED DELETE/REVOKE ROW — EDITING THIS BODY REDS A GATE IN scripts/.
  # This action is a NARROW row in @exclusion_anchors
  # (scripts/pds-elixir-receipt-census.exs). Any edit inside these clauses, a
  # `mix format` reflow included, moves its def fingerprint and fails
  # EXCLUSION-ANCHORS-FRESH. Re-derive IN THE SAME COMMIT, READING the three
  # values out of the STDOUT of
  #   elixir scripts/pds-elixir-receipt-census.exs --exclusion-keys
  # and never typing them from a log. Editing that register is a DECLARED
  # allowed cross-fence edit for the lane that moved it — the ruling, its
  # limits and the steps: docs/ops/exclusion-anchor-rederive.md
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

  # [reserved-status] owner ruling #45 (task-e427940a663dc687). `status` is
  # the document's draft/published state: Studio writes a `status` select to
  # the row status column and publish sets it to `published`, so a select named
  # `status` whose options are anything else (the demo project's
  # planning/active/completed) loses the editor's choice on publish. Refused at
  # this door — the one `bp schema apply` uses — with a message naming the
  # rename. A `status` select limited to draft/published/archived (the post
  # schema) mirrors the real state and stays allowed. Plugin-declared schemas
  # register through `Content.upsert_schema/3` directly and handle their own
  # status fields, so they are not checked here.
  @lifecycle_status_options ~w(draft published archived)

  defp refuse_reserved_status(attrs) do
    fields = Map.get(attrs, "fields") || Map.get(attrs, :fields) || []

    bad =
      Enum.find_value(List.wrap(fields), fn
        %{} = f ->
          name = Map.get(f, "name") || Map.get(f, :name)
          options = Map.get(f, "options") || Map.get(f, :options)

          with "status" <- name,
               list when is_list(list) <- options_values(options),
               [_ | _] = extra <- list -- @lifecycle_status_options do
            extra
          else
            _ -> nil
          end

        _ ->
          nil
      end)

    case bad do
      nil ->
        :ok

      extra ->
        {:error,
         {:invalid_schema_fields,
          {:status_field_reserved,
           "a field named `status` is the document's draft/published state, so the options " <>
             "#{Enum.join(extra, ", ")} would be lost on publish; rename the field " <>
             "(for example `phase`) or limit its options to draft, published, archived"}}}
    end
  end

  defp options_values(list) when is_list(list) do
    Enum.map(list, fn
      %{"value" => v} -> to_string(v)
      %{value: v} -> to_string(v)
      v -> to_string(v)
    end)
  end

  defp options_values(%{"list" => list}) when is_list(list), do: options_values(list)
  defp options_values(_), do: nil
end
