defmodule Barkpark.Content.SlugInUse do
  @moduledoc """
  Sanity's slug rule, as the TanStack Studio asks it (`lib/slug-unique.ts`):
  a slug another document of the same type already has, draft or published,
  is in use.

  A slug is stored in either of two shapes: Barkpark's plain string, or
  Sanity's `{_type: "slug", current}` (imported content). Both are the same
  slug, so both are asked for (`lib/slug-shape.ts` `slugQueries`).

  One query per ask: two JSONB containment probes on `documents.content`,
  which the `documents_content_path_idx` GIN index serves, with the type and
  the caller's read scope (`Query.scope_as_id_read/3`: dataset, workspace and
  project, owner rows, grants, visible types). It answers yes or no and
  nothing about the other document, so a caller learns no more than that the
  slug is taken, and only from rows it may read.
  """

  import Ecto.Query

  alias Barkpark.Content.Document
  alias Barkpark.Content.DraftId
  alias Barkpark.Content.Query
  alias Barkpark.Repo

  @doc "The text of a slug value in either shape, or nil for none."
  @spec text(term()) :: String.t() | nil
  def text(value) when is_binary(value) and value != "", do: value
  def text(%{"current" => value}) when is_binary(value) and value != "", do: value
  def text(_value), do: nil

  @doc """
  Whether a document of `type` other than `id` (its draft or published
  version) holds `value` in its `field`, in `dataset` under `opts`'s read
  scope.
  """
  @spec taken?(String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          boolean()
  def taken?(type, field, value, id, dataset, opts)
      when is_binary(type) and is_binary(field) and is_binary(value) and value != "" and
             is_binary(id) and is_binary(dataset) do
    pub = DraftId.published_id(id)
    plain = %{field => value}
    sanity = %{field => %{"current" => value}}

    from(d in Document,
      where: d.type == ^type and d.doc_id not in ^[pub, DraftId.draft_id(pub)],
      where: fragment("? @> ?", d.content, ^plain) or fragment("? @> ?", d.content, ^sanity)
    )
    |> Query.scope_as_id_read(dataset, opts)
    |> Repo.exists?()
  end

  def taken?(_type, _field, _value, _id, _dataset, _opts), do: false
end
