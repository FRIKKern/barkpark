defmodule Barkpark.Content.Reseal do
  @moduledoc """
  Count, then reseal, plaintext left in `encrypted: true` fields (owner ruling
  #19, task-5aba9d644eb3b40c).

  Before #21221 a scoped write in a non-Default workspace did not find its own
  schema, so a field the schema marks `encrypted: true` was stored as plain
  text. New writes seal; rows written before stay plaintext until their next
  save. This module is the operator's tool for those rows:

    * `census/0` — the read-only SQL census from the task row: per non-Default
      workspace, type and TOP-LEVEL field, the number of rows whose marked
      field holds a non-null value that is not an `_bpenc` envelope.
      `census(:control)` is the positive control (sealed rows in the Default
      workspace).
    * `plan/1` — the per-row walk the census cannot do (composite / arrayOf
      kids, bound block copies): every document of a marked type in a
      non-Default workspace whose content CHANGES under
      `Encryption.encrypt_marked/5` in its own scope. Read-only.
    * `apply/2` — reseals ONE workspace's candidates in batches, sealing each
      named row (draft or published) in place, fenced on its rev. The logical
      value is unchanged, so the rev stays and no event fires. Refuses when the
      box's KEK cannot wrap and unwrap a key: a seal under the wrong key is
      worse than plaintext.

  What it does not touch, stated plainly: the previous plaintext stays in
  `revisions` (and in earlier `mutation_events` and webhook payloads).
  Scrubbing those is a separate owner decision.
  """

  import Ecto.Query, warn: false

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Encryption, SchemaDefinition}
  alias Barkpark.Crypto.KeyProvider
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Workspace

  @census_sql """
  WITH marked AS (
    SELECT s.workspace_id, s.name AS type, s.dataset, f->>'name' AS field
    FROM schema_definitions s, unnest(s.fields) AS f
    WHERE (f->>'encrypted') = 'true' AND s.workspace_id IS NOT NULL
  )
  SELECT w.slug, m.type, m.field, count(*) AS plaintext_rows
  FROM documents d
  JOIN marked m ON m.workspace_id = d.workspace_id AND m.type = d.type AND m.dataset = d.dataset
  JOIN workspaces w ON w.id = d.workspace_id
  WHERE w.is_default IS NOT TRUE
    AND d.content ? m.field
    AND d.content -> m.field <> 'null'::jsonb
    AND NOT (jsonb_typeof(d.content -> m.field) = 'object' AND (d.content -> m.field) ? '_bpenc')
  GROUP BY 1, 2, 3
  ORDER BY 4 DESC, 1, 2, 3
  """

  @control_sql """
  WITH marked AS (
    SELECT s.workspace_id, s.name AS type, s.dataset, f->>'name' AS field
    FROM schema_definitions s, unnest(s.fields) AS f
    WHERE (f->>'encrypted') = 'true' AND s.workspace_id IS NOT NULL
  )
  SELECT w.slug, m.type, m.field, count(*) AS sealed_rows
  FROM documents d
  JOIN marked m ON m.workspace_id = d.workspace_id AND m.type = d.type AND m.dataset = d.dataset
  JOIN workspaces w ON w.id = d.workspace_id
  WHERE w.is_default IS TRUE
    AND d.content ? m.field
    AND (d.content -> m.field) ? '_bpenc'
  GROUP BY 1, 2, 3
  ORDER BY 4 DESC, 1, 2, 3
  """

  @type census_row :: %{
          workspace: String.t(),
          type: String.t(),
          field: String.t(),
          rows: integer()
        }

  @doc "The read-only census (`:plaintext`, default) or its positive control (`:control`)."
  @spec census(:plaintext | :control) :: [census_row()]
  def census(which \\ :plaintext)

  # One literal statement per clause: no SQL text travels in a variable.
  def census(:control),
    do: Repo.query!(@control_sql, [], timeout: :infinity) |> census_rows()

  def census(:plaintext),
    do: Repo.query!(@census_sql, [], timeout: :infinity) |> census_rows()

  defp census_rows(%{rows: rows}) do
    Enum.map(rows, fn [ws, type, field, n] ->
      %{workspace: ws, type: type, field: field, rows: n}
    end)
  end

  @type candidate :: %{
          workspace: String.t(),
          workspace_id: binary(),
          type: String.t(),
          dataset: String.t(),
          doc_id: String.t()
        }

  @doc """
  Every document in a non-Default workspace (optionally one, by slug) whose
  content changes when its marked fields are sealed. Read-only.
  """
  @spec plan(keyword()) :: [candidate()]
  def plan(opts \\ []) do
    opts
    |> marked_types()
    |> Enum.flat_map(fn {ws, type, dataset} ->
      {docs, _} =
        Content.collect_all_documents(type, dataset,
          perspective: :raw,
          workspace_id: ws.id
        )

      docs
      |> Enum.filter(&changes?(&1, type, dataset))
      |> Enum.map(fn d ->
        %{workspace: ws.slug, workspace_id: ws.id, type: type, dataset: dataset, doc_id: d.doc_id}
      end)
    end)
  end

  @doc """
  Reseal ONE workspace (by slug). Returns `{:ok, %{resealed: n, failed: [...]}}`
  or `{:error, reason}` (`:kek_unavailable`, `:workspace_not_found`,
  `:default_workspace`). `:batch_size` (default 100) bounds each pass.
  """
  @spec apply(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def apply(workspace_slug, opts \\ []) when is_binary(workspace_slug) do
    with true <- kek_ready?() || {:error, :kek_unavailable},
         %Workspace{} = ws <-
           Repo.get_by(Workspace, slug: workspace_slug) || {:error, :workspace_not_found},
         true <- not ws.is_default || {:error, :default_workspace} do
      batch = Keyword.get(opts, :batch_size, 100)

      results =
        [workspace: workspace_slug]
        |> plan()
        |> Enum.chunk_every(batch)
        |> Enum.flat_map(fn chunk -> Enum.map(chunk, &reseal_one/1) end)

      failed = for {:error, id, reason} <- results, do: %{doc_id: id, reason: inspect(reason)}
      {:ok, %{resealed: Enum.count(results, &(&1 == :ok)), failed: failed}}
    else
      {:error, _} = err -> err
    end
  end

  @doc """
  Can this box's KEK wrap and unwrap a key right now? A reseal refuses
  without it.
  """
  @spec kek_ready?() :: boolean()
  def kek_ready? do
    probe = :crypto.strong_rand_bytes(32)
    KeyProvider.unwrap(KeyProvider.wrap(probe)) == {:ok, probe}
  rescue
    _ -> false
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # {workspace, type, dataset} for every non-Default workspace schema that
  # marks any field (at any depth) encrypted.
  defp marked_types(opts) do
    ws_filter =
      case Keyword.get(opts, :workspace) do
        slug when is_binary(slug) -> dynamic([s, w], w.slug == ^slug)
        _ -> true
      end

    from(s in SchemaDefinition,
      join: w in Workspace,
      on: w.id == s.workspace_id,
      where: w.is_default != true,
      where: ^ws_filter,
      select: {w, s}
    )
    |> Repo.all()
    |> Enum.filter(fn {_w, s} -> any_encrypted?(s.fields) end)
    |> Enum.map(fn {w, s} -> {w, s.name, s.dataset} end)
    |> Enum.uniq_by(fn {w, t, d} -> {w.id, t, d} end)
  end

  defp any_encrypted?(fields) when is_list(fields), do: Enum.any?(fields, &field_encrypted?/1)
  defp any_encrypted?(_), do: false

  defp field_encrypted?(f) when is_map(f) do
    Map.get(f, "encrypted") in [true, "true"] or any_encrypted?(Map.get(f, "fields")) or
      field_encrypted?(Map.get(f, "of"))
  end

  defp field_encrypted?(_), do: false

  defp changes?(%Document{content: content} = doc, type, dataset) when is_map(content) do
    case Encryption.encrypt_marked(content, type, dataset, doc_scope(doc), doc_id: doc.doc_id) do
      {:ok, sealed} -> sealed != content
      _ -> false
    end
  end

  defp changes?(_doc, _type, _dataset), do: false

  # Seal the EXACT row the plan named, draft or published, in place. A normal
  # `Content.upsert_document/4` save always writes the `drafts.` row, so a
  # published row would have kept its plaintext and grown a draft twin. The
  # logical value does not change (the sealed field decrypts to the same
  # text), so the row keeps its rev and no event is emitted. The update is
  # fenced on the rev the row had when it was read: a row someone saved in
  # between was sealed by that save and is reported, not overwritten.
  defp reseal_one(%{doc_id: id, type: type, dataset: dataset, workspace_id: ws_id}) do
    with %Document{} = doc <-
           Repo.one(
             from(d in Document,
               where:
                 d.doc_id == ^id and d.type == ^type and d.dataset == ^dataset and
                   d.workspace_id == ^ws_id
             )
           ) || :not_found,
         {:ok, sealed} <-
           Encryption.encrypt_marked(doc.content, type, dataset, doc_scope(doc),
             doc_id: doc.doc_id
           ) do
      cond do
        sealed == doc.content ->
          :ok

        true ->
          {n, _} =
            from(d in Document, where: d.id == ^doc.id and d.rev == ^doc.rev)
            |> Repo.update_all(set: [content: sealed, updated_at: DateTime.utc_now()])

          if n == 1, do: :ok, else: {:error, id, :changed_since_read}
      end
    else
      other -> {:error, id, other}
    end
  end

  defp doc_scope(%Document{workspace_id: ws, project_id: proj}) do
    [workspace_id: ws, project_id: proj] |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end
end
