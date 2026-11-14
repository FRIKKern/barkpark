defmodule Barkpark.Content.SchemaStoredFields do
  @moduledoc """
  `GET /v1/schemas/:dataset?definition=stored`: the schema list with each
  schema's `fields` as stored.

  The default list serves fields for SDK readers: every field gains
  `required?`, and each member of an array field's `of` (and a reference
  field's `to`) is cut down to `type`, `to` and `name`. A member's own nested
  `fields` are not served. A client that pulls a schema, edits it and posts it
  back would therefore replace the stored members with the cut-down ones.

  With `definition=stored` the list carries the field list exactly as the row
  holds it, and the envelope says so with `definition: "stored"`. A client
  that sees no such key is talking to a server without this read and has the
  cut-down form. Everything else in the envelope, `schemaHash` included, is the
  default list's.
  """

  alias Barkpark.Content

  @doc "The schema list envelope for `dataset`, in the form `params` asks for."
  @spec index(String.t(), keyword(), map()) :: map()
  def index(dataset, opts, params) do
    envelope = Content.list_schemas_for_sdk(dataset, opts)

    if params["definition"] == "stored" do
      # `list_schemas/2` is memoized per request, so this is the same list the
      # envelope was built from, in the same order.
      rows = Content.list_schemas(dataset, opts)

      schemas =
        Enum.zip_with(envelope.schemas, rows, fn served, row ->
          %{served | fields: row.fields || []}
        end)

      envelope |> Map.put(:schemas, schemas) |> Map.put(:definition, "stored")
    else
      envelope
    end
  end
end
