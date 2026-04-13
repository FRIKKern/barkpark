defmodule Barkpark.Content do
  @moduledoc """
  Context for documents and schema definitions.

  ## Draft/Published model

  Follows Sanity's convention: drafts and published are separate document rows.

    - Published document: `doc_id = "p1"`
    - Draft of same:      `doc_id = "drafts.p1"`

  Creating a document always creates a draft (`drafts.{id}`).
  Publishing copies the draft to the published ID and removes the draft.
  Editing a published doc creates a new draft alongside it.

  ## Perspectives

    - `:published` — only documents without `drafts.` prefix (public-facing)
    - `:drafts`    — prefers draft over published when both exist (studio view)
    - `:raw`       — all documents including both drafts and published
  """

  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Content.{Document, Revision, SchemaDefinition}

  @drafts_prefix "drafts."

  # ── Draft/Published helpers ────────────────────────────────────────────────

  def draft_id(published_id) do
    if String.starts_with?(published_id, @drafts_prefix) do
      published_id
    else
      @drafts_prefix <> published_id
    end
  end

  def published_id(doc_id) do
    String.replace_prefix(doc_id, @drafts_prefix, "")
  end

  def draft?(doc_id), do: String.starts_with?(doc_id, @drafts_prefix)

  # ── Documents ──────────────────────────────────────────────────────────────

  @doc """
  List documents by type and dataset.

  Options:
    - `:perspective` — `:published`, `:drafts`, or `:raw` (default `:raw`)
    - `:filter` — "field=value" filter string
  """
  def list_documents(type, dataset, opts \\ []) do
    perspective = Keyword.get(opts, :perspective, :raw)
    filter = Keyword.get(opts, :filter)

    Document
    |> where([d], d.type == ^type and d.dataset == ^dataset)
    |> apply_perspective(perspective)
    |> maybe_filter(filter)
    |> order_by([d], desc: d.updated_at)
    |> Repo.all()
    |> maybe_merge_drafts(perspective)
  end

  defp apply_perspective(query, :published) do
    prefix = @drafts_prefix <> "%"
    where(query, [d], not like(d.doc_id, ^prefix))
  end

  defp apply_perspective(query, _), do: query

  defp maybe_merge_drafts(docs, :drafts) do
    # Group by published_id, prefer draft over published
    docs
    |> Enum.group_by(fn doc -> published_id(doc.doc_id) end)
    |> Enum.map(fn {_pub_id, versions} ->
      Enum.find(versions, fn d -> draft?(d.doc_id) end) || hd(versions)
    end)
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  defp maybe_merge_drafts(docs, _), do: docs

  defp maybe_filter(query, nil), do: query
  defp maybe_filter(query, ""), do: query

  defp maybe_filter(query, filter_string) do
    case String.split(filter_string, "=", parts: 2) do
      [field, value] ->
        case field do
          "status" ->
            where(query, [d], d.status == ^value)

          _ ->
            where(query, [d], fragment("?->>? = ?", d.content, ^field, ^value))
        end

      _ ->
        query
    end
  end

  def get_document(doc_id, type, dataset) do
    Document
    |> where([d], d.doc_id == ^doc_id and d.type == ^type and d.dataset == ^dataset)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  @doc "Create or update a document. New docs are always created as drafts."
  def create_document(type, attrs, dataset) do
    raw_id = Map.get(attrs, "doc_id") || Map.get(attrs, :doc_id) || generate_id(type)
    doc_id = draft_id(raw_id)

    attrs =
      attrs
      |> Map.put("doc_id", doc_id)
      |> Map.put("type", type)
      |> Map.put("dataset", dataset)
      |> Map.put_new("status", "draft")
      |> Map.put("rev", generate_rev())

    case get_document(doc_id, type, dataset) do
      {:ok, existing} ->
        existing
        |> Document.changeset(attrs)
        |> Repo.update()
        |> tap_broadcast(dataset, type, "update")

      _ ->
        %Document{}
        |> Document.changeset(attrs)
        |> Repo.insert()
        |> tap_broadcast(dataset, type, "create")
    end
  end

  @doc """
  Publish a document: copy draft content to published ID, delete draft.
  If no draft exists, returns error.
  """
  def publish_document(published_doc_id, type, dataset) do
    did = draft_id(published_doc_id)
    pid = published_id(published_doc_id)

    case get_document(did, type, dataset) do
      {:ok, draft} ->
        # Upsert the published version with draft's content
        pub_attrs = %{
          "doc_id" => pid,
          "type" => type,
          "dataset" => dataset,
          "title" => draft.title,
          "status" => "published",
          "content" => draft.content,
          "rev" => generate_rev()
        }

        pub_result =
          case get_document(pid, type, dataset) do
            {:ok, existing} ->
              existing |> Document.changeset(pub_attrs) |> Repo.update()

            _ ->
              %Document{} |> Document.changeset(pub_attrs) |> Repo.insert()
          end

        case pub_result do
          {:ok, published} ->
            # Delete the draft
            Repo.delete(draft)
            tap_broadcast({:ok, published}, dataset, type, "publish")

          error ->
            error
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc "Unpublish: move published doc back to draft, delete published version."
  def unpublish_document(published_doc_id, type, dataset) do
    pid = published_id(published_doc_id)
    did = draft_id(published_doc_id)

    case get_document(pid, type, dataset) do
      {:ok, pub} ->
        # Create draft with published content
        draft_attrs = %{
          "doc_id" => did,
          "type" => type,
          "dataset" => dataset,
          "title" => pub.title,
          "status" => "draft",
          "content" => pub.content,
          "rev" => generate_rev()
        }

        draft_result =
          case get_document(did, type, dataset) do
            {:ok, existing} ->
              existing |> Document.changeset(draft_attrs) |> Repo.update()

            _ ->
              %Document{} |> Document.changeset(draft_attrs) |> Repo.insert()
          end

        case draft_result do
          {:ok, draft} ->
            Repo.delete(pub)
            tap_broadcast({:ok, draft}, dataset, type, "unpublish")

          error ->
            error
        end

      error ->
        error
    end
  end

  @doc "Discard a draft without publishing. Published version (if any) remains."
  def discard_draft(published_doc_id, type, dataset) do
    did = draft_id(published_doc_id)

    case get_document(did, type, dataset) do
      {:ok, draft} ->
        Repo.delete(draft)
        |> tap_broadcast(dataset, type)

      error ->
        error
    end
  end

  def delete_document(doc_id, type, dataset) do
    pid = published_id(doc_id)
    did = draft_id(doc_id)

    # Delete both draft and published
    results =
      [pid, did]
      |> Enum.map(fn id -> get_document(id, type, dataset) end)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, doc} -> Repo.delete(doc) end)

    case results do
      [] -> {:error, :not_found}
      [first | _] -> tap_broadcast(first, dataset, type)
    end
  end

  @doc "Find all documents that reference a given document ID."
  def find_referencing_docs(doc_id, dataset) do
    pub_id = published_id(doc_id)
    schemas = list_schemas(dataset)

    # Find all schema fields that are references
    ref_fields = for schema <- schemas,
                     field <- schema.fields,
                     field["type"] == "reference",
                     do: {schema.name, field["name"]}

    # Search each type for docs that reference this ID
    Enum.flat_map(ref_fields, fn {type_name, field_name} ->
      list_documents(type_name, dataset, perspective: :raw)
      |> Enum.filter(fn doc ->
        val = get_in(doc.content || %{}, [field_name])
        val == pub_id
      end)
      |> Enum.map(fn doc ->
        %{doc_id: doc.doc_id, type: type_name, title: doc.title, field: field_name}
      end)
    end)
  end

  @doc "Remove all references to a document ID from other documents."
  def disconnect_references(doc_id, dataset) do
    pub_id = published_id(doc_id)
    refs = find_referencing_docs(doc_id, dataset)

    Enum.each(refs, fn %{doc_id: ref_doc_id, type: type, field: field} ->
      case get_document(ref_doc_id, type, dataset) do
        {:ok, doc} ->
          updated_content = Map.delete(doc.content || %{}, field)
          doc
          |> Document.changeset(%{"content" => updated_content, "rev" => generate_rev()})
          |> Repo.update()
          |> tap_broadcast(dataset, type)
        _ -> :ok
      end
    end)
  end

  defp generate_id(type) do
    "#{type}-#{:rand.uniform(999_999)}"
  end

  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # ── Legacy upsert (for backward compat) ───────────────────────────────────

  def upsert_document(type, attrs, dataset) do
    doc_id = Map.get(attrs, "doc_id") || Map.get(attrs, :doc_id)

    attrs =
      attrs
      |> Map.put("type", type)
      |> Map.put("dataset", dataset)
      |> Map.put_new("status", "draft")
      |> Map.put("rev", generate_rev())

    case doc_id && get_document(doc_id, type, dataset) do
      {:ok, existing} ->
        existing
        |> Document.changeset(attrs)
        |> Repo.update()
        |> tap_broadcast(dataset, type)

      _ ->
        %Document{}
        |> Document.changeset(attrs)
        |> Repo.insert()
        |> tap_broadcast(dataset, type)
    end
  end

  # ── Schema Definitions ────────────────────────────────────────────────────

  def list_schemas(dataset) do
    SchemaDefinition
    |> where([s], s.dataset == ^dataset)
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  def get_schema(name, dataset) do
    SchemaDefinition
    |> where([s], s.name == ^name and s.dataset == ^dataset)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      schema -> {:ok, schema}
    end
  end

  def upsert_schema(attrs, dataset) do
    name = Map.get(attrs, "name") || Map.get(attrs, :name)
    attrs = Map.put(attrs, "dataset", dataset)

    case name && get_schema(name, dataset) do
      {:ok, existing} ->
        existing
        |> SchemaDefinition.changeset(attrs)
        |> Repo.update()

      _ ->
        %SchemaDefinition{}
        |> SchemaDefinition.changeset(attrs)
        |> Repo.insert()
    end
  end

  def delete_schema(name, dataset) do
    case get_schema(name, dataset) do
      {:ok, schema} -> Repo.delete(schema)
      error -> error
    end
  end

  def schema_public?(type, dataset) do
    case get_schema(type, dataset) do
      {:ok, %{visibility: "public"}} -> true
      _ -> false
    end
  end

  # ── PubSub ────────────────────────────────────────────────────────────────

  defp tap_broadcast(result, dataset, type, action \\ "update") do
    case result do
      {:ok, doc} ->
        # Save revision
        save_revision(doc, type, dataset, action)

        msg = %{
          type: type,
          doc_id: doc.doc_id,
          action: :mutate,
          doc: %{
            doc_id: doc.doc_id,
            title: doc.title,
            status: doc.status,
            content: doc.content,
            updated_at: doc.updated_at
          },
          sender: self()
        }

        # Broadcast to global topic (for doc lists, dashboard counts)
        Phoenix.PubSub.broadcast(Barkpark.PubSub, "documents:#{dataset}", {:document_changed, msg})

        # Broadcast to doc-specific topic (for editors viewing this doc)
        pub_id = published_id(doc.doc_id)
        Phoenix.PubSub.broadcast(Barkpark.PubSub, "doc:#{dataset}:#{type}:#{pub_id}", {:doc_updated, msg})

        {:ok, doc}

      error ->
        error
    end
  end

  defp save_revision(doc, type, dataset, action) do
    %Revision{}
    |> Revision.changeset(%{
      doc_id: published_id(doc.doc_id),
      type: type,
      dataset: dataset,
      title: doc.title,
      status: doc.status,
      content: doc.content,
      action: action
    })
    |> Repo.insert()
  end

  # ── Revision queries ──────────────────────────────────────────────────────

  @doc "List revisions for a document, newest first."
  def list_revisions(doc_id, type, dataset, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Revision
    |> where([r], r.doc_id == ^published_id(doc_id) and r.type == ^type and r.dataset == ^dataset)
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Get a single revision by ID."
  def get_revision(id) do
    case Repo.get(Revision, id) do
      nil -> {:error, :not_found}
      rev -> {:ok, rev}
    end
  end

  @doc "Restore a document to a specific revision."
  def restore_revision(revision_id, type, dataset) do
    with {:ok, rev} <- get_revision(revision_id) do
      attrs = %{
        "doc_id" => draft_id(rev.doc_id),
        "title" => rev.title,
        "status" => rev.status,
        "content" => rev.content
      }
      upsert_document(type, attrs, dataset)
    end
  end
end
