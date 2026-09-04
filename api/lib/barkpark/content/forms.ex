defmodule Barkpark.Content.Forms do
  @moduledoc """
  Form ↔ content coercion for the Studio Classic editor.

  Owns the schema-driven mapping between a flat form params map and a
  document's `content` map: `doc_to_form/2` (read side), `build_content/2`
  (write side, with `coerce_field_value` type coercion), and `upsert_draft/6`
  (the autosave/save entry point). The data-loss guard `classic_save_content`
  (Exp-P3.2) preserves FREE blocks + block ORDER byte-identical when a doc has
  been opened in the Beta block editor.

  Extracted from `Barkpark.Content`, which keeps a thin delegating facade so
  every external caller (StudioLive native editor pane, pane_builder) is
  unchanged.

  Depends on `Barkpark.PortableDoc.{Projection, Synthesis}` (block engine),
  `Barkpark.Content.{DraftId, Labels}` (already extracted), and the
  still-on-facade write spine (concern E) via `Barkpark.Content.{validate_document,
  upsert_document}`.
  """

  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId, Labels}
  alias Barkpark.PortableDoc.{Projection, Synthesis}

  @doc """
  Build a form map from a document and its schema. Returns a map keyed
  by field name with string values, including `"title"` and `"status"`
  baseline keys. Returns `%{}` when `doc` is nil. Used by StudioLive's
  native editor pane — consolidated in Task #11 WI3 from prior
  duplicates in StudioLive (`doc_to_form`, `doc_data_to_form`) and the
  deleted plugin BookEditor.
  """
  @spec doc_to_form(map() | nil, map() | nil) :: map()
  def doc_to_form(nil, _schema), do: %{}

  def doc_to_form(doc, schema) do
    base = %{"title" => doc.title || "", "status" => doc.status || "draft"}

    if schema do
      Enum.reduce(schema.fields, base, fn field, acc ->
        key = field["name"]

        raw = get_in(doc.content || %{}, [key])

        val =
          cond do
            key in ["title", "status"] ->
              Map.get(acc, key)

            # A `richText` field that opted into the block editor is read by
            # the field canvas as its block array, not as flattened HTML — it
            # has no form input, so this map never reaches a form param.
            Barkpark.PortableDoc.FieldVocabulary.blocks_field?(field) ->
              raw

            # An `image` value decoded into a map at the save boundary rides
            # back to the picker as its JSON wire string (Gyldendal parity E1).
            field["type"] == "image" and is_map(raw) ->
              Jason.encode!(raw)

            true ->
              classic_form_value(raw)
          end

        Map.put(acc, key, val)
      end)
    else
      base
    end
  end

  # A field's projected content value, flattened to the SCALAR the Classic form
  # input expects. A `body` REGION projects to a body map (`%{"blocks" => …,
  # "html" => …}` — Projection.project_body/2); the Classic richText/text input
  # is a string editor, so surface the rendered HTML string. This is the Classic
  # read side of the lossless Beta↔Classic toggle (Exp-P3.2): both views read
  # the ONE projected content, each presenting it in its own shape — no
  # conversion of the underlying block list. Non-map (scalar) values pass through
  # unchanged; nil becomes "".
  defp classic_form_value(%{"html" => html}) when is_binary(html), do: html
  defp classic_form_value(nil), do: ""
  defp classic_form_value(value), do: value

  @doc """
  Build a `content` map from a form params map by reducing schema
  fields. Excludes `"title"` and `"status"` (those live on the
  document row, not under `content`). Empty-string values are dropped.
  Returns `%{}` when `schema` is nil. Used by StudioLive's native
  editor pane — consolidated in Task #11 WI3 (the plugin BookEditor
  that originally shared this helper was removed in Goal `barkpark-zdy`).
  """
  @spec build_content(map(), map() | nil) :: map()
  def build_content(_params, nil), do: %{}

  def build_content(params, schema) do
    Enum.reduce(schema.fields, %{}, fn field, acc ->
      key = field["name"]
      val = Map.get(params, key, "")

      if key in ["title", "status"] or val == "" do
        acc
      else
        Map.put(acc, key, coerce_field_value(field, val))
      end
    end)
  end

  # Schema `"number"` fields arrive from the Classic form as STRINGS (the
  # numeric field renders as a text input with inputmode="numeric"), but
  # the API contract stores numbers — e.g. the task validator's
  # integer-0..4 `priority` check hard-rejects the string and fails the
  # save. Coerce at the save boundary so the API contract stays the
  # source of truth: integer parse first, float fallback. An unparseable
  # value is kept AS-IS so the schema/kind validator rejects it loudly
  # instead of the save path silently corrupting it. Empty strings never
  # reach here (build_content/2 drops them — the existing field-clearing
  # semantics). Non-binary values (API callers already sending numbers)
  # pass through unchanged.
  defp coerce_field_value(%{"type" => "number"}, val) when is_binary(val) do
    trimmed = String.trim(val)

    case Integer.parse(trimmed) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(trimmed) do
          {float, ""} -> float
          _ -> val
        end
    end
  end

  # Schema `"boolean"` fields arrive from the Classic form as the STRINGS
  # "true"/"false" (the checkbox + hidden-false pair) — found live 2026-06-12
  # by clicking the Studio switch and reading the draft back: `featured`
  # stored as the string "true", a silent JSONB type flip under every typed
  # consumer (the same bug class the TUI/CLI typed saves fixed client-side).
  # Coerce at the save boundary; any other string is kept AS-IS so a schema
  # validator rejects it loudly rather than this path guessing.
  defp coerce_field_value(%{"type" => "boolean"}, "true"), do: true
  defp coerce_field_value(%{"type" => "boolean"}, "false"), do: false

  # Schema `"image"` fields arrive from the picker as a STRING: a bare URL, or
  # a JSON object {url, assetId, alt?, focalX?, focalY?} (Gyldendal parity E1
  # added the last three). Storing the JSON as a string-in-a-string made every
  # consumer re-parse it ad hoc; decode it here so `content.cover.focalX` is a
  # number. A bare URL stays a string (it never was an object), and a string
  # that only LOOKS like JSON but does not parse is kept as-is.
  defp coerce_field_value(%{"type" => "image"}, val) when is_binary(val) do
    trimmed = String.trim(val)

    if String.starts_with?(trimmed, "{") do
      case Jason.decode(trimmed) do
        {:ok, %{} = map} -> map
        _ -> val
      end
    else
      val
    end
  end

  defp coerce_field_value(_field, val), do: val

  # ── Exp-P3.2 — Classic-save content (the data-loss guard) ─────────────────
  #
  # A document THAT HAS content["blocks"] (it has been opened in the Beta block
  # editor) must NOT be saved by overwriting content from the flat Classic form
  # map — that would drop every FREE block and content["blocks"] itself. Instead
  # the submitted fields are mapped onto the matching BOUND blocks' values, the
  # block list is re-projected, and FREE blocks + block ORDER survive
  # byte-identical. A document WITHOUT blocks (legacy, never Beta-edited) keeps
  # the existing build_content/2 field-map behavior unchanged.
  defp classic_save_content(base_doc, params, schema, dataset) do
    base_content = Map.get(base_doc, :content) || %{}

    case Map.get(base_content, "blocks") do
      blocks when is_list(blocks) ->
        values = classic_field_values(params, schema)
        new_blocks = Synthesis.patch_bound_values(blocks, values)

        # A submitted field with NO bound block must still persist (e.g. an
        # image field on a doc whose block list never bound it) — patching
        # bound blocks alone silently dropped it while the editor reported
        # "Saved". Merge those onto content as plain keys with the same
        # semantics as the non-blocks branch (empty string clears the key).
        # Projection only rewrites bound fieldNames + "body", so these
        # survive the project pass.
        bound_names =
          blocks
          |> Enum.map(& &1["fieldName"])
          |> Enum.filter(&(is_binary(&1) and &1 != ""))

        unbound_params = Map.drop(params, bound_names)

        base_content
        |> Map.drop(Map.keys(unbound_params))
        |> Map.drop(["title", "status"])
        |> Map.merge(build_content(unbound_params, schema))
        |> Map.put("blocks", new_blocks)
        |> Projection.project(new_blocks, Labels.render_opts(dataset))

      _ ->
        # Merge over the existing content instead of replacing it: a key
        # PRESENT in the submitted params is form-managed — its new value
        # (or its removal, via build_content/2's empty-string drop) wins.
        # A key ABSENT from params is one the form does not manage — v1
        # "array"/"object" fields render read-only with no input (the task
        # schema's `dependencies`/`claim`), and non-schema keys like the
        # task substrate's `labels`/`papers` never render at all. Those
        # survive a Classic save byte-identical instead of being silently
        # dropped. (The blocks branch above already preserves base_content.)
        base_content
        |> Map.drop(Map.keys(params))
        |> Map.drop(["title", "status"])
        |> Map.merge(build_content(params, schema))
    end
  end

  # The field => submitted-value map a Classic save patches onto bound blocks.
  # Keyed by the SCHEMA's declared field names plus the row-level "title" field
  # (post's layout binds title), so only fields the schema knows about can
  # touch a bound block. "status" lives on the row, never in content, so it is
  # excluded. Values are taken verbatim from the form params; a field absent
  # from params is omitted (its bound block is left untouched).
  defp classic_field_values(params, schema) do
    names =
      case schema do
        %{fields: fields} when is_list(fields) ->
          Enum.map(fields, & &1["name"]) ++ ["title"]

        _ ->
          ["title"]
      end

    names
    |> Enum.uniq()
    |> Enum.reject(&(&1 in [nil, "status"]))
    |> Enum.reduce(%{}, fn name, acc ->
      case Map.fetch(params, name) do
        {:ok, value} -> Map.put(acc, name, value)
        :error -> acc
      end
    end)
  end

  @doc """
  Upsert a draft for the document being edited. Builds attrs from the
  form params + schema, runs informational validation, calls
  `upsert_document/3`, and returns the saved doc together with the
  validation errors map (drafts save with warnings; only publish blocks).

  `opts` is forwarded to `upsert_document/4` so callers can supply
  lifecycle-hook context (`:source`, `:user_id`).

  Returns `{:ok, saved_doc, validation_errors_map}` on success or
  `{:error, term}` on a DB upsert failure. The `{:error, {:halted,
  reason}}` shape from a halting `before_save` hook is passed through
  unchanged. Consolidated in Task #11 WI3 from prior duplicate bodies
  in StudioLive (`handle_event "autosave"`, `handle_info :autosave_form`,
  `save_doc/3`).
  """
  @spec upsert_draft(Document.t(), String.t(), map() | nil, map(), String.t(), keyword()) ::
          {:ok, Document.t(), map()} | {:error, term()}
  def upsert_draft(base_doc, type, schema, params, dataset, opts \\ []) do
    content = classic_save_content(base_doc, params, schema, dataset)
    new_title = Map.get(params, "title", base_doc.title)

    attrs = %{
      "doc_id" => DraftId.draft_id(DraftId.published_id(base_doc.doc_id)),
      "title" => new_title,
      "status" => Map.get(params, "status", base_doc.status),
      "content" => content
    }

    validation_errors =
      case Content.validate_document(type, new_title, content, dataset) do
        {:error, errs} -> errs
        _ -> %{}
      end

    case Content.upsert_document(type, attrs, dataset, opts) do
      {:ok, doc} -> {:ok, doc, validation_errors}
      {:error, _} = err -> err
    end
  end
end
