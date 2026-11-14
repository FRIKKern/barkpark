defmodule Barkpark.Content.SchemaStoredFields do
  @moduledoc """
  `GET /v1/schemas/:dataset?definition=stored`: the schema list with each
  schema's `fields` as stored.

  The default list serves fields for SDK readers: every field gains
  `required?`, and each member of an array field's `of` (and a reference
  field's `to`) is cut down to `type`, `to` and `name`. A member's own nested
  `fields` are not served. A client that pulls a schema, edits it and posts it
  back would therefore replace the stored members with the cut-down ones.

  The default list also inlines a field of a named object type: the stored
  `{"name": "seo", "type": "seo"}` is served as a composite carrying a copy of
  the type's fields. Posting that back would store the copy and cut the field
  loose from its type.

  With `definition=stored` the list carries each field list as the row holds
  it, before named types are inlined, and the envelope says so with
  `definition: "stored"`. A client that sees no such key is talking to a
  server without this read and has the served form. The set of schemas is the
  default list's: the rows come from the same query, with the same scope and
  grant narrowing. Everything else in the envelope, `schemaHash` included, is
  the default list's.
  """

  alias Barkpark.Content

  @doc "The schema list envelope for `dataset`, in the form `params` asks for."
  @spec index(String.t(), keyword(), map()) :: map()
  def index(dataset, opts, params) do
    envelope = Content.list_schemas_for_sdk(dataset, opts)

    if params["definition"] == "stored" do
      stored =
        dataset
        |> Content.Schema.list_stored_schemas(opts)
        |> Map.new(&{&1.name, &1.fields || []})

      # Paired by name. A schema the stored query no longer returns is left
      # out, so a served copy never stands in for a stored field list.
      schemas =
        for %{name: name} = served <- envelope.schemas, is_map_key(stored, name) do
          %{served | fields: Map.fetch!(stored, name)}
        end

      envelope |> Map.put(:schemas, schemas) |> Map.put(:definition, "stored")
    else
      envelope
    end
  end
end
