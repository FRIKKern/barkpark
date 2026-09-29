defmodule Barkpark.Content.TitleDerivation do
  @moduledoc """
  Gyldendal parity E1.8 (friction 69/70) — the document `title` column for a
  type that declares NO `title` field.

  Sanity derives a document's list title from `preview.select.title`; Barkpark
  stores a `title` column on every row and reads it in the desk rows, the
  editor header, `/v1/data/doc`, search hits and the reference picker's pill.
  A type shaped like the twin's `author` (fields `name`, `slug`, `photo`, `bio`;
  `list_preview.title = "name"`) has no field to fill that column, so every
  surface fell back to "Untitled" or the id.

  This module closes the gap at the ONE write chokepoint every path shares
  (`Writer.create_document/4` and `Writer.upsert_document/4` — the Studio's
  autosave, the API's create family, `patch`, and the publish copy all land
  there): when the write carries no title of its own and the type's schema has
  no `title` field but names one in `list_preview.title`, the column is
  derived from that field's stored value.

  Cost and blast radius, stated: the schema is resolved only when the write's
  title is BLANK and its content is a map — a write that carries a title pays
  nothing and is byte-identical to before. A schema WITH a `title` field, a
  schema without `list_preview.title`, a non-scalar or empty value, or any
  resolution failure all leave `attrs` untouched (the column stays whatever the
  caller sent), so this can only ever move a row from "Untitled" to its name.
  """

  alias Barkpark.Content

  @doc """
  Derive `attrs["title"]` from the schema's `list_preview.title` field when the
  schema declares no `title` field and the write carries no title. Pure.
  """
  @spec derive(map(), map() | struct() | nil) :: map()
  def derive(attrs, nil), do: attrs

  def derive(attrs, schema) when is_map(attrs) do
    with true <- blank?(title_of(attrs)),
         %{} = content <- content_of(attrs),
         nil <- title_field(schema),
         field when is_binary(field) <- preview_title_field(schema),
         value when is_binary(value) and value != "" <- scalar(Map.get(content, field)) do
      Map.put(attrs, "title", value)
    else
      _ -> attrs
    end
  end

  def derive(attrs, _schema), do: attrs

  @doc """
  The write-path entry: resolve the schema (tenant → workspace → global, the
  same resolver `declared_status_field?` uses) ONLY when a derivation could
  apply, then `derive/2`.
  """
  @spec maybe_derive(map(), String.t(), String.t(), keyword()) :: map()
  def maybe_derive(attrs, type, dataset, opts)
      when is_map(attrs) and is_binary(type) and is_binary(dataset) do
    if blank?(title_of(attrs)) and is_map(content_of(attrs)) do
      case Content.resolve_schema(type, dataset, opts) do
        {:ok, schema} -> derive(attrs, schema)
        _ -> attrs
      end
    else
      attrs
    end
  end

  def maybe_derive(attrs, _type, _dataset, _opts), do: attrs

  @doc """
  The value the editor header and a desk row should show for a document whose
  `title` column is blank: the `list_preview.title` field's stored value, or nil.
  Only for a schema WITHOUT a `title` field — a titled type's blank column stays
  blank, exactly as before. Shared by the Studio surfaces so the rule has one
  spelling.
  """
  @spec preview_title(map() | nil, map() | struct() | nil) :: String.t() | nil
  def preview_title(nil, _schema), do: nil
  def preview_title(_doc, nil), do: nil

  def preview_title(doc, schema) do
    with nil <- title_field(schema),
         field when is_binary(field) <- preview_title_field(schema),
         %{} = content <- Map.get(doc, :content) || Map.get(doc, "content"),
         value when is_binary(value) and value != "" <- scalar(Map.get(content, field)) do
      value
    else
      _ -> nil
    end
  end

  @doc "The field `list_preview.title` names (a bare name or `%{\"field\" => name}`), or nil."
  @spec preview_title_field(map() | struct() | nil) :: String.t() | nil
  def preview_title_field(nil), do: nil

  def preview_title_field(schema) do
    preview =
      Map.get(schema, :list_preview) || Map.get(schema, "list_preview") ||
        Map.get(schema, :listPreview) || Map.get(schema, "listPreview") || %{}

    case is_map(preview) && (Map.get(preview, "title") || Map.get(preview, :title)) do
      f when is_binary(f) and f != "" -> f
      %{"field" => f} when is_binary(f) and f != "" -> f
      %{field: f} when is_binary(f) and f != "" -> f
      _ -> nil
    end
  end

  @doc "The schema's declared `title` field, or nil when the type has none."
  @spec title_field(map() | struct() | nil) :: map() | nil
  def title_field(nil), do: nil

  def title_field(schema) do
    fields = Map.get(schema, :fields) || Map.get(schema, "fields") || []

    if is_list(fields) do
      Enum.find(fields, fn
        f when is_map(f) -> Map.get(f, "name") == "title" or Map.get(f, :name) == "title"
        _ -> false
      end)
    end
  end

  defp title_of(attrs), do: Map.get(attrs, "title") || Map.get(attrs, :title)
  defp content_of(attrs), do: Map.get(attrs, "content") || Map.get(attrs, :content)

  defp blank?(nil), do: true
  defp blank?(t) when is_binary(t), do: String.trim(t) == ""
  defp blank?(_), do: false

  defp scalar(v) when is_binary(v), do: String.trim(v)
  defp scalar(v) when is_number(v), do: to_string(v)
  defp scalar(_), do: nil
end
