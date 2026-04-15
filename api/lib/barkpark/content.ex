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
  alias Barkpark.Content.{Document, Envelope, Revision, SchemaDefinition, Validation}

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
    - `:perspective`  — `:published`, `:drafts`, or `:raw` (default `:raw`)
    - `:filter_map`   — map of field=>value filters, e.g. `%{"status" => "draft"}`
    - `:limit`        — max rows returned (default 100, max 1000, min 1)
    - `:offset`       — rows to skip (default 0)
    - `:order`        — `:updated_at_desc` (default), `:updated_at_asc`,
                        `:created_at_desc`, `:created_at_asc`

  NOTE: `maybe_merge_drafts/2` runs after limit/offset, so the `:drafts`
  perspective may return fewer rows than requested. This is a known limitation
  (tracked for Phase 8).
  """
  def list_documents(type, dataset, opts \\ []) do
    perspective = Keyword.get(opts, :perspective, :raw)
    filter_map = Keyword.get(opts, :filter_map, %{})
    limit = opts |> Keyword.get(:limit, 100) |> min(1000) |> max(1)
    offset = opts |> Keyword.get(:offset, 0) |> max(0)
    order = Keyword.get(opts, :order, :updated_at_desc)

    Document
    |> where([d], d.type == ^type and d.dataset == ^dataset)
    |> apply_perspective(perspective)
    |> apply_filter_map(filter_map)
    |> apply_order(order)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> maybe_merge_drafts(perspective)
  end

  defp apply_perspective(query, :published) do
    prefix = @drafts_prefix <> "%"
    where(query, [d], not like(d.doc_id, ^prefix))
  end

  defp apply_perspective(query, _), do: query

  defp apply_filter_map(query, map) when map_size(map) == 0, do: query
  defp apply_filter_map(query, map) do
    Enum.reduce(map, query, fn
      {field, %{} = ops}, q -> apply_field_ops(q, field, ops)
      {field, value}, q -> apply_field_op(q, field, "eq", value)
    end)
  end

  defp apply_field_ops(query, field, ops) do
    Enum.reduce(ops, query, fn {op, value}, q ->
      apply_field_op(q, field, op, value)
    end)
  end

  defp apply_field_op(query, "title", "eq", v), do: where(query, [d], d.title == ^v)
  defp apply_field_op(query, "title", "in", vs) when is_list(vs), do: where(query, [d], d.title in ^vs)
  defp apply_field_op(query, "title", "contains", v), do: where(query, [d], ilike(d.title, ^"%#{v}%"))
  defp apply_field_op(query, "title", "gt", v), do: where(query, [d], d.title > ^v)
  defp apply_field_op(query, "title", "gte", v), do: where(query, [d], d.title >= ^v)
  defp apply_field_op(query, "title", "lt", v), do: where(query, [d], d.title < ^v)
  defp apply_field_op(query, "title", "lte", v), do: where(query, [d], d.title <= ^v)

  defp apply_field_op(query, "status", "eq", v), do: where(query, [d], d.status == ^v)
  defp apply_field_op(query, "status", "in", vs) when is_list(vs), do: where(query, [d], d.status in ^vs)

  defp apply_field_op(query, field, "eq", v),
    do: where(query, [d], fragment("?->>? = ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "in", vs) when is_list(vs),
    do: where(query, [d], fragment("?->>? = ANY(?)", d.content, ^field, ^vs))

  defp apply_field_op(query, field, "contains", v),
    do: where(query, [d], fragment("?->>? ILIKE ?", d.content, ^field, ^"%#{v}%"))

  defp apply_field_op(query, field, "gt", v),
    do: where(query, [d], fragment("?->>? > ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "gte", v),
    do: where(query, [d], fragment("?->>? >= ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "lt", v),
    do: where(query, [d], fragment("?->>? < ?", d.content, ^field, ^v))

  defp apply_field_op(query, field, "lte", v),
    do: where(query, [d], fragment("?->>? <= ?", d.content, ^field, ^v))

  defp apply_field_op(query, _field, _op, _value), do: query

  defp apply_order(q, :updated_at_desc), do: order_by(q, [d], desc: d.updated_at)
  defp apply_order(q, :updated_at_asc), do: order_by(q, [d], asc: d.updated_at)
  defp apply_order(q, :created_at_desc), do: order_by(q, [d], desc: d.inserted_at)
  defp apply_order(q, :created_at_asc), do: order_by(q, [d], asc: d.inserted_at)
  defp apply_order(q, _), do: order_by(q, [d], desc: d.updated_at)

  defp maybe_merge_drafts(docs, :drafts) do
    # Group by published_id, prefer draft, preserve SQL-level order.
    # (Dropping the final Enum.sort_by would destabilize ordering across
    # grouped pairs; we track the first index of each pid and re-sort by it.)
    docs
    |> Enum.with_index()
    |> Enum.group_by(fn {doc, _} -> published_id(doc.doc_id) end)
    |> Enum.map(fn {_pid, versions} ->
      {_first_doc, first_idx} = hd(versions)
      best =
        case Enum.find(versions, fn {d, _} -> draft?(d.doc_id) end) do
          {draft, _} -> draft
          nil -> elem(hd(versions), 0)
        end

      {best, first_idx}
    end)
    |> Enum.sort_by(fn {_, i} -> i end)
    |> Enum.map(fn {doc, _} -> doc end)
  end

  defp maybe_merge_drafts(docs, _), do: docs

  def get_document(doc_id, type, dataset) do
    Document
    |> where([d], d.doc_id == ^doc_id and d.type == ^type and d.dataset == ^dataset)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      doc -> {:ok, doc}
    end
  end

  @doc "Validate document content against its schema. Returns {:ok, content} or {:error, errors_map}."
  def validate_document(type, title, content, dataset) do
    case get_schema(type, dataset) do
      {:ok, schema} -> Validation.validate(content, title, schema)
      _ -> {:ok, content}
    end
  end

  @doc "Create or update a document. New docs are always created as drafts."
  def create_document(type, attrs, dataset) do
    attrs = from_envelope(attrs)
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
        |> tap_broadcast(dataset, type, "update", existing.rev)

      _ ->
        %Document{}
        |> Document.changeset(attrs)
        |> Repo.insert()
        |> tap_broadcast(dataset, type, "create", nil)
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

        {pub_result, prev_pub_rev} =
          case get_document(pid, type, dataset) do
            {:ok, existing} ->
              {existing |> Document.changeset(pub_attrs) |> Repo.update(), existing.rev}

            _ ->
              {%Document{} |> Document.changeset(pub_attrs) |> Repo.insert(), nil}
          end

        case pub_result do
          {:ok, published} ->
            # Delete the draft
            Repo.delete(draft)
            tap_broadcast({:ok, published}, dataset, type, "publish", prev_pub_rev)

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

        {draft_result, prev_draft_rev} =
          case get_document(did, type, dataset) do
            {:ok, existing} ->
              {existing |> Document.changeset(draft_attrs) |> Repo.update(), existing.rev}

            _ ->
              {%Document{} |> Document.changeset(draft_attrs) |> Repo.insert(), nil}
          end

        case draft_result do
          {:ok, draft} ->
            Repo.delete(pub)
            tap_broadcast({:ok, draft}, dataset, type, "unpublish", prev_draft_rev)

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
        prev_rev = draft.rev
        Repo.delete(draft)
        |> tap_broadcast(dataset, type, "discardDraft", prev_rev)

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
      |> Enum.map(fn {:ok, doc} -> {Repo.delete(doc), doc.rev} end)

    case results do
      [] ->
        {:error, :not_found}

      [{first_result, prev_rev} | _] ->
        tap_broadcast(first_result, dataset, type, "delete", prev_rev)
    end
  end

  @doc """
  Apply a batch of mutations atomically. Returns `{:ok, {transaction_id, results}}`
  or `{:error, reason}` with rollback on any failure.

  PubSub broadcasts queued inside the transaction are flushed AFTER a
  successful commit, and discarded on rollback — no ghost events on
  the SSE stream when a batch fails partway through.
  """
  def apply_mutations(mutations, dataset) when is_list(mutations) do
    # Initialise the deferred-broadcast queue for this process so
    # tap_broadcast/5 knows to queue instead of broadcast immediately.
    Process.put(:barkpark_deferred_broadcasts, [])

    try do
      result =
        Repo.transaction(fn ->
          tx_id = generate_rev()

          results =
            Enum.map(mutations, fn m ->
              case apply_one(m, dataset) do
                {:ok, doc, op} -> %{id: doc.doc_id, operation: op, document: Envelope.render(doc)}
                {:error, reason} -> Repo.rollback(reason)
              end
            end)

          {tx_id, results}
        end)

      case result do
        {:ok, _} ->
          flush_deferred_broadcasts()
          result

        _ ->
          clear_deferred_broadcasts()
          result
      end
    rescue
      e ->
        clear_deferred_broadcasts()
        reraise(e, __STACKTRACE__)
    end
  end

  defp apply_one(%{"create" => attrs}, dataset) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    # A create must NOT overwrite an existing draft
    case id && get_document(draft_id(id), type, dataset) do
      {:ok, _existing} ->
        {:error, :conflict}

      _ ->
        with {:ok, doc} <- create_document(type, attrs, dataset), do: {:ok, doc, "create"}
    end
  end

  defp apply_one(%{"createOrReplace" => attrs}, dataset) do
    type = attrs["_type"] || attrs["type"]
    with {:ok, doc} <- create_document(type, attrs, dataset), do: {:ok, doc, "createOrReplace"}
  end

  defp apply_one(%{"createIfNotExists" => attrs}, dataset) do
    type = attrs["_type"] || attrs["type"]
    id = attrs["_id"] || attrs["doc_id"]

    case id && get_document(draft_id(id), type, dataset) do
      {:ok, existing} -> {:ok, existing, "noop"}
      _ ->
        with {:ok, doc} <- create_document(type, attrs, dataset), do: {:ok, doc, "create"}
    end
  end

  defp apply_one(%{"publish" => %{"id" => id, "type" => type}}, dataset) do
    with {:ok, doc} <- publish_document(id, type, dataset), do: {:ok, doc, "publish"}
  end

  defp apply_one(%{"unpublish" => %{"id" => id, "type" => type}}, dataset) do
    with {:ok, doc} <- unpublish_document(id, type, dataset), do: {:ok, doc, "unpublish"}
  end

  defp apply_one(%{"discardDraft" => %{"id" => id, "type" => type}}, dataset) do
    with {:ok, doc} <- discard_draft(id, type, dataset), do: {:ok, doc, "discardDraft"}
  end

  defp apply_one(%{"delete" => %{"id" => id, "type" => type}}, dataset) do
    with {:ok, doc} <- delete_document(id, type, dataset), do: {:ok, doc, "delete"}
  end

  defp apply_one(%{"patch" => %{"id" => id, "type" => type, "set" => fields} = patch}, dataset) do
    with {:ok, existing} <- get_document(id, type, dataset),
         :ok <- ensure_rev(existing, patch["ifRevisionID"]) do
      merged =
        Map.merge(
          existing.content || %{},
          Map.drop(fields, ~w(title status _id _type _rev))
        )

      attrs = %{
        "doc_id" => id,
        "title" => fields["title"] || existing.title,
        "content" => merged
      }

      with {:ok, doc} <- upsert_document(type, attrs, dataset), do: {:ok, doc, "update"}
    end
  end

  defp apply_one(_, _), do: {:error, :malformed}

  defp ensure_rev(_doc, nil), do: :ok
  defp ensure_rev(_doc, ""), do: :ok
  defp ensure_rev(%{rev: r}, r), do: :ok
  defp ensure_rev(_, _), do: {:error, :rev_mismatch}

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
          prev_rev = doc.rev
          doc
          |> Document.changeset(%{"content" => updated_content, "rev" => generate_rev()})
          |> Repo.update()
          |> tap_broadcast(dataset, type, "update", prev_rev)
        _ -> :ok
      end
    end)
  end

  @reserved_in ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt doc_id type dataset rev title status content)

  defp from_envelope(attrs) do
    cond do
      # Already legacy shape — pass through unchanged
      Map.has_key?(attrs, "content") and is_map(Map.get(attrs, "content")) ->
        attrs

      true ->
        id = Map.get(attrs, "_id") || Map.get(attrs, "doc_id")
        title = Map.get(attrs, "title")
        status = Map.get(attrs, "status", "draft")
        content = Map.drop(attrs, @reserved_in)

        %{
          "doc_id" => id,
          "title" => title,
          "status" => status,
          "content" => content
        }
    end
  end

  defp generate_id(type) do
    "#{type}-#{:rand.uniform(999_999)}"
  end

  defp generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # ── Legacy upsert (for backward compat) ───────────────────────────────────

  def upsert_document(type, attrs, dataset) do
    attrs = from_envelope(attrs)
    raw_id = Map.get(attrs, "doc_id") || Map.get(attrs, :doc_id)
    doc_id = raw_id && draft_id(raw_id)

    attrs =
      attrs
      |> Map.put("doc_id", doc_id)
      |> Map.put("type", type)
      |> Map.put("dataset", dataset)
      |> Map.put_new("status", "draft")
      |> Map.put("rev", generate_rev())

    case doc_id && get_document(doc_id, type, dataset) do
      {:ok, existing} ->
        existing
        |> Document.changeset(attrs)
        |> Repo.update()
        |> tap_broadcast(dataset, type, "update", existing.rev)

      _ ->
        %Document{}
        |> Document.changeset(attrs)
        |> Repo.insert()
        |> tap_broadcast(dataset, type, "create", nil)
    end
  end

  # ── Schema Definitions ────────────────────────────────────────────────────

  @doc """
  Return all datasets known to the system, sorted alphabetically.
  Always includes `"production"` so a brand-new DB still has something to show.
  """
  def list_datasets do
    from_schemas =
      from(s in SchemaDefinition, select: s.dataset, distinct: true)
      |> Repo.all()

    from_docs =
      from(d in Document, select: d.dataset, distinct: true)
      |> Repo.all()

    (from_schemas ++ from_docs ++ ["production"])
    |> Enum.uniq()
    |> Enum.sort()
  end

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
  #
  # Broadcasts are DEFERRED when we're inside an Ecto transaction (e.g.
  # apply_mutations/2). They land in the process dict and are flushed by
  # flush_deferred_broadcasts/0 after the transaction commits. If the
  # transaction rolls back, clear_deferred_broadcasts/0 discards them
  # (no ghost events on the SSE stream). Direct writes outside a
  # transaction broadcast immediately — same behaviour as before.

  defp tap_broadcast(result, dataset, type, action, prev_rev \\ nil) do
    case result do
      {:ok, doc} ->
        save_revision(doc, type, dataset, action)
        ev = save_event(doc, type, dataset, action, prev_rev)

        msg = %{
          event_id: ev.id,
          type: type,
          mutation: action,
          action: :mutate,
          doc_id: doc.doc_id,
          rev: doc.rev,
          previous_rev: prev_rev,
          document: Envelope.render(doc),
          doc: %{
            doc_id: doc.doc_id,
            title: doc.title,
            status: doc.status,
            content: doc.content,
            updated_at: doc.updated_at
          },
          sender: self()
        }

        global_topic = "documents:#{dataset}"
        doc_topic = "doc:#{dataset}:#{type}:#{published_id(doc.doc_id)}"

        maybe_broadcast(global_topic, {:document_changed, msg})
        maybe_broadcast(doc_topic, {:doc_updated, msg})

        {:ok, doc}

      error ->
        error
    end
  end

  # Defer if we're inside a transaction; broadcast immediately otherwise.
  defp maybe_broadcast(topic, msg) do
    if Repo.in_transaction?() do
      queue = Process.get(:barkpark_deferred_broadcasts, [])
      Process.put(:barkpark_deferred_broadcasts, [{topic, msg} | queue])
    else
      Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, msg)
    end
  end

  # Flush broadcasts queued during a successful transaction, preserving
  # their original order (the queue is built by prepending).
  defp flush_deferred_broadcasts do
    queue = Process.delete(:barkpark_deferred_broadcasts) || []

    queue
    |> Enum.reverse()
    |> Enum.each(fn {topic, msg} ->
      Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, msg)
    end)
  end

  defp clear_deferred_broadcasts do
    Process.delete(:barkpark_deferred_broadcasts)
    :ok
  end

  defp save_event(doc, type, dataset, action, prev_rev) do
    alias Barkpark.Content.MutationEvent

    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: dataset,
      type: type,
      doc_id: doc.doc_id,
      mutation: action,
      rev: doc.rev,
      previous_rev: prev_rev,
      document: Envelope.render(doc),
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
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
