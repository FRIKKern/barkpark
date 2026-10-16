defmodule Barkpark.Search.HitPreview do
  @moduledoc """
  A search hit's list preview (task-75cb2cac1e875214): the subtitle,
  description and media its type's `list_preview` declares, the same text a
  Studio desk row shows (`Barkpark.Content.PreviewText`). The reference picker
  asks for it with `?preview=1`, so three editions named "Eventyrnettene" read
  "ISBN · Bok", "ISBN · E-bok" and "ISBN · Lydbok" in the picker as on the desk.

  Each hit gains `_preview: %{"subtitle" => …, "description" => …, "media" => …}`
  (keys without a value are left out; a type with no declaration gets none).
  The hit is the caller's rendered envelope, so a field the caller may not read
  is already gone. The referenced documents a preview reads through load in one
  scoped read and are rendered for the same caller, so they lose the same
  fields. An anonymous caller gets no previews.
  """

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, Envelope, PreviewText}

  @keys ~w(subtitle description media)

  @doc """
  `documents` with `_preview` on every hit whose type declares a list preview.
  `schema_fun` resolves a type to its schema (`nil` when unknown).
  """
  @spec attach([map()], String.t(), keyword(), (String.t() -> map() | nil), term()) :: [map()]
  def attach(documents, dataset, scope_opts, schema_fun, caller_context)

  def attach(documents, _dataset, _scope_opts, _schema_fun, nil), do: documents

  def attach(documents, _dataset, _scope_opts, _schema_fun, %CallerContext{
        principal_type: :anonymous
      }),
      do: documents

  def attach(documents, dataset, scope_opts, schema_fun, caller_context)
      when is_list(documents) do
    specs =
      documents |> Enum.map(&type_of/1) |> Enum.uniq() |> Map.new(&{&1, specs(schema_fun.(&1))})

    ids =
      documents
      |> Enum.flat_map(fn doc ->
        PreviewText.ref_ids(Map.values(Map.get(specs, type_of(doc), %{})), doc)
      end)
      |> Enum.uniq()

    targets = targets(ids, dataset, scope_opts, schema_fun, caller_context)
    deref = &Map.get(targets, &1)

    Enum.map(documents, fn doc ->
      case Map.get(specs, type_of(doc), %{}) do
        spec when map_size(spec) == 0 -> doc
        spec -> put_preview(doc, preview(spec, doc, deref))
      end
    end)
  end

  def attach(documents, _dataset, _scope_opts, _schema_fun, _ctx), do: documents

  defp put_preview(doc, preview) when map_size(preview) == 0, do: doc
  defp put_preview(doc, preview), do: Map.put(doc, "_preview", preview)

  defp preview(spec, doc, deref) do
    for {key, s} <- spec,
        value = text(key, s, doc, deref),
        is_binary(value),
        into: %{},
        do: {key, value}
  end

  defp text("media", spec, doc, deref), do: PreviewText.media(spec, doc, deref)
  defp text(_key, spec, doc, deref), do: PreviewText.format(spec, doc, deref)

  defp specs(%{list_preview: %{} = lp}), do: Map.take(lp, @keys) |> reject_nil()
  defp specs(%{"list_preview" => %{} = lp}), do: Map.take(lp, @keys) |> reject_nil()
  defp specs(_), do: %{}

  defp reject_nil(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

  defp type_of(doc), do: Map.get(doc, "_type") || Map.get(doc, :_type)

  defp targets([], _dataset, _scope_opts, _schema_fun, _ctx), do: %{}

  defp targets(ids, dataset, scope_opts, schema_fun, ctx) do
    found =
      Content.get_documents_by_ids(ids ++ Enum.map(ids, &("drafts." <> &1)), dataset, scope_opts)

    rows = for id <- ids, row = found[id] || found["drafts." <> id], do: row

    rows
    |> Envelope.render_many_by_type(schema_fun, ctx)
    |> Map.new(fn rendered -> {rendered["_publishedId"], rendered} end)
  end
end
