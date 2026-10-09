defmodule Barkpark.Content.Envelope do
  @moduledoc """
  Canonical v1 document envelope. Flat map with reserved `_`-prefixed keys.

  Reserved keys: _id, _type, _rev, _draft, _publishedId, _createdAt, _updatedAt.
  All other keys come from the document's stored content plus `title`.
  User content cannot override reserved keys.

  `title` is the ONE emitted key sourced from a COLUMN rather than from content,
  so it is the one key a caller's own content field can collide with. The column
  wins whenever it holds a value; a content field named `title` is emitted only
  when the column is blank — where the key would otherwise carry nothing while
  the stored value was destroyed on the way out. The derivation, the rejected
  alternatives and the residual case live at `emitted_title/2` below.

  ## Field visibility (Phase 3, core-auth)

  `render/3` is the SINGLE output chokepoint where per-field visibility is
  enforced — every read surface (REST query, search, share-link, history, and
  reference expansion) threads its caller through here so a `private` /
  `owner_only` / allowlisted field is DROPPED before it can leave the system.

  The contract FAILS CLOSED — a nil/anonymous caller is the MOST restrictive,
  never a bypass:

    * `caller_context == nil` ⇒ treated as the anonymous PUBLIC-ONLY principal —
      every `private` / `owner_only` / `readable_by` / encrypted field is
      dropped. A nil caller is NEVER an "internal full-content" signal (that was
      the WS-B bug: media payloads and the legacy dump passed nil and leaked the
      whole document). Internal/writer paths that legitimately carry the FULL
      document (the mutation-result echo, the broadcast payload, the stored
      `mutation_event` snapshot that is re-redacted per-subscriber downstream)
      pass the explicit `:internal` sentinel — never nil.
    * `caller_context == :internal` ⇒ NO redaction (the explicit full-content
      sentinel). Read it as UNFORGEABLE INPUT — never as "the bytes stay in the
      process".

      This bullet used to end "not reachable from any request path". That was
      FALSE, and false in the direction a reader acts on. All three `:internal`
      renders in `lib/` live in `Content.Broadcast` (broadcast.ex :69 immediate
      broadcast, :133 deferred flush, :319 the stored `mutation_events`
      snapshot), and `tap_broadcast/5` executes INSIDE the mutating request —
      `POST /v1/data/mutate` → `Content.apply_mutations/2` → writer/lifecycle.
      The unredacted map then leaves the node on EXACTLY TWO seams:

        1. `BarkparkWeb.ListenController.live_result/4`, which forwards
           `msg.document` verbatim to an `is_admin: true` SSE subscriber on
           `GET /v1/data/listen/:dataset` — the ONE seam that reaches a
           REQUESTER; and
        2. `Barkpark.Webhooks.Dispatcher.build_payload/6`, which ships the same
           map to the workspace-configured endpoint (also via the admin
           `POST …/webhooks/:id/replay/:event_id`).

      Both are SOUND, and for a structural reason rather than a promise: the
      `%CallerContext{is_admin: true}` clause below returns the envelope
      UNCHANGED — byte-identical to the `:internal` clause — so neither
      recipient receives anything it could not already read through the normal
      redaction path. The residual difference is freshness, documented at
      `live_result/4`'s own comment block.

      What IS true and load-bearing: nothing outside the writer can SUPPLY the
      sentinel. `CallerContext.from_conn/1` (caller_context.ex) returns a
      `%CallerContext{}` or `CallerContext.anonymous()` — never the bare atom —
      so no header, token, param or share link can hand a caller the bypass.
      That is now pinned by
      `test/barkpark/content/envelope_internal_sentinel_test.exs`. The other
      dangerous widening — relaxing `live_result/4`'s fast path from
      `is_admin: true` to any `%CallerContext{}` — is already tripwired:
      `test/barkpark_web/controllers/listen_controller_test.exs` reds with
      `"ssn" => "111-22-3333"` visible in the forwarded map.
    * `caller_context.is_admin` ⇒ NO redaction (admins see all; note ciphertext
      is still NOT decrypted here — decryption stays the explicit
      `Content.reveal_fields/4` API).
    * Any other caller ⇒ encrypted-ciphertext fields are dropped (they default
      to PRIVATE regardless of schema, preserving the Phase 2 invariant), and —
      when a `schema` is supplied — `private` / `visibility` / `readable_by`
      fields are dropped unless the caller is authorized.

  With no encrypted values and no visibility metadata declared, the output is
  byte-identical to the legacy `render/1` — even for an anonymous/nil caller
  (no private fields ⇒ nothing to redact).
  """

  alias Barkpark.Content
  alias Barkpark.Content.{CallerContext, SchemaDefinition}
  alias Barkpark.Crypto.FieldCipher
  alias Barkpark.PortableDoc.Projection

  @reserved ~w(_id _type _rev _draft _publishedId _createdAt _updatedAt)

  # @canonical capability:visibility-redaction aka:redact,render,private-field,field-visibility,owner_only doc:docs/auth-user-sessions.md
  def render(doc, schema \\ nil, caller_context \\ nil) do
    content = doc.content || %{}

    user_fields =
      content
      |> Map.drop(@reserved)
      |> Map.put("title", emitted_title(doc.title, content))

    {user_fields, derived_from_body?} = promote_paper_blocks(user_fields, doc.type)

    Map.merge(user_fields, %{
      "_id" => doc.doc_id,
      "_type" => doc.type,
      "_rev" => doc.rev,
      "_draft" => Content.draft?(doc.doc_id),
      "_publishedId" => Content.published_id(doc.doc_id),
      "_createdAt" => to_iso8601(doc.inserted_at),
      "_updatedAt" => to_iso8601(doc.updated_at)
    })
    |> redact_by_field_visibility(schema, caller_context, doc_owner_id(doc))
    |> maybe_drop_orphaned_promotion(derived_from_body?)
  end

  defp promote_paper_blocks(fields, "paper") do
    case Projection.read_blocks(fields) do
      blocks when is_list(blocks) ->
        {Map.put(fields, "blocks", blocks), not is_list(fields["blocks"])}

      _ ->
        {fields, false}
    end
  end

  defp promote_paper_blocks(fields, _type), do: {fields, false}

  defp maybe_drop_orphaned_promotion(fields, true) do
    if Map.has_key?(fields, "body"), do: fields, else: Map.delete(fields, "blocks")
  end

  defp maybe_drop_orphaned_promotion(fields, false), do: fields

  # [title-collision] gh-13711 — the READ-path sibling of gh-6291 (`content`)
  # and gh-6292 (`status`), both fixed on the WRITE path in PR #13706.
  #
  # This used to be an unconditional `Map.put("title", doc.title)`. A document
  # written through the CONTENT-PRESENT branch of `Writer.from_envelope/1` —
  # `{"content": {"title": "…", …}}` with no top-level `title` — stores that
  # field intact in the row and then had it overwritten here by a NULL column on
  # the way out. The value was then unreadable by any means: `render/3` is the
  # single field-visibility chokepoint, so REST query, search, share-link,
  # history and reference expansion lost it identically. It is a REACHABLE
  # shape, not a hypothetical — the mixed-shape refusal's own message
  # (`Writer.refuse_orphan_top_level_keys/1`) tells callers to "Move them INSIDE
  # `content`", which walks a type with its own `title` field straight into it.
  #
  # DECISION — THE COLUMN WINS WHENEVER IT HOLDS A VALUE; a content field named
  # `title` is emitted only when the column would otherwise emit nothing.
  # Rejected alternatives, and why:
  #
  #   * `Map.put_new` ("content wins whenever the key is present") is WRONG, and
  #     wrong on live data. `PortableDoc.Projection.project_bound_fields/3` is
  #     the SOLE writer of `content[fieldName]` and does a verbatim
  #     `Map.put(acc, fieldName, projected_value(block))`; `projected_value/1`
  #     documents that a bound block with no `"value"` projects `nil`. So a
  #     bound title block on a blocks-bearing document leaves `"title"` PRESENT
  #     with a `nil` value. `put_new` keys on presence, so every such document
  #     would start rendering `title: nil` while its column holds the real
  #     title.
  #   * "Content always wins" also manufactures divergence against everything
  #     that addresses the COLUMN: `Content.Query` filters (`apply_field_op/4`)
  #     and orders (`apply_order/2`) on `d.title`, `field_readable?/3` lists
  #     `title` in `@system_filterable` so it is filterable for every caller,
  #     `Search.Highlighter.document_field_text/2` highlights `doc.title`, and
  #     `Lifecycle.ensure_bound_title_agrees/1` exists precisely BECAUSE the
  #     column and a bound title block can move independently — it refuses only
  #     at publish, and only for bound blocks, so diverged drafts, papers and
  #     imports are already on disk.
  #   * "Both, under distinct keys" would mint a new reserved `_title` that every
  #     SDK, CLI, Studio and scaffold reader must learn, to serve a field-name
  #     collision. Not worth a vocabulary change.
  #
  # When the column is blank the emitted key carries NO information today — it
  # is `nil`. Emitting the stored value there disagrees with nothing (a filter
  # on `title` matches nothing against a NULL column either) and is strictly
  # more than the destroyed value. Only a non-blank BINARY is taken, so the
  # `title`-is-a-string assumption consumers rely on (`internal/apiclient`'s
  # `scalarString`, `@barkpark/core`'s non-nullable `title`) survives a bound
  # block whose value is a map or a list.
  #
  # RESIDUAL, on purpose: with the column set, a colliding `content["title"]` is
  # still not readable. Making THAT case loud belongs on the WRITE door beside
  # `Writer.refuse_colliding_status/1` — a different blast radius, to be filed
  # rather than smuggled in here.
  defp emitted_title(column, content) when is_map(content) do
    if blank_title?(column) do
      case Map.get(content, "title") do
        value when is_binary(value) -> if blank_title?(value), do: column, else: value
        _ -> column
      end
    else
      column
    end
  end

  defp emitted_title(column, _content), do: column

  defp blank_title?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_title?(_value), do: true

  def render_many(docs, schema \\ nil, caller_context \\ nil),
    do: Enum.map(docs, &render(&1, schema, caller_context))

  @doc """
  Variant of `render_many/3` for MULTI-TYPE result sets — the search surfaces
  (multi-type REST search, federated search, live search channel) where no
  single schema applies. `schema_fun` resolves a `doc.type` to its
  `%SchemaDefinition{}` (or nil); the result is memoised per distinct type
  across the set, mirroring `Content.Export`'s per-type schema cache.

  Without this, those surfaces render with `schema == nil`, so a non-encrypted
  `private` / `visibility` / `owner_only` / `readable_by` field has no schema
  entry and leaks to a non-authorized caller — the schema-free guard only
  catches encrypted ciphertext. Resolving each doc's own schema closes the leak
  exactly as single-type search already does.
  """
  def render_many_by_type(docs, schema_fun, caller_context) when is_function(schema_fun, 1) do
    {rendered, _cache} =
      Enum.map_reduce(docs, %{}, fn doc, cache ->
        {schema, cache} = resolve_schema_cached(cache, doc.type, schema_fun)
        {render(doc, schema, caller_context), cache}
      end)

    rendered
  end

  defp resolve_schema_cached(cache, type, schema_fun) do
    case Map.fetch(cache, type) do
      {:ok, schema} ->
        {schema, cache}

      :error ->
        schema = schema_fun.(type)
        {schema, Map.put(cache, type, schema)}
    end
  end

  @doc """
  Content source map (task-f18edb4599e06308, candidate 1) — a `{result path
  -> source document + field}` map for click-to-edit, computed from an
  ALREADY-RENDERED envelope rather than by re-deriving field visibility: a
  key present in `rendered` already survived `render/3`'s redaction (a
  `private`/`owner_only`/encrypted field was deleted from the map, never
  merely hidden), so iterating `rendered`'s own keys gets "a redacted field
  never appears in the map" for free — no separate visibility check, no risk
  of the two decisions drifting apart.

  FLAT FIELDS ONLY (scope cut, recorded on the task row): a nested
  object/array value's OWN sub-fields are not walked — the whole value is one
  mapping entry naming its top-level key. Provenance through `?expand=`
  (a different source document), computed fields (no single source to name)
  and aggregate/derived views each need their own rule, filed separately as
  task-0e0cb2167c6fcdea rather than guessed at here.

  Returns `nil` for a non-document result (nothing to map) or a `rendered`
  with no user-content keys at all.

  Shape mirrors `@sanity/client`'s `resultSourceMap` loosely (documents/paths/
  mappings, JSON-Pointer-ish result keys) — NOT byte-compatible, since
  Barkpark has no stega/visual-editing client to match today; the shape is
  chosen to be obviously extensible toward that if it is ever built.

  Third arg `expanded` (task-0e0cb2167c6fcdea) — the SAME document's envelope
  AFTER `Expand.expand/4` ran, if the caller asked for `?expand=`. `nil`
  (the default) keeps this byte-identical to the flat-fields-only version
  this function shipped as originally.

  Expand provenance is computed by DIFFING `rendered` (pre-expand) against
  `expanded` (post-expand) field by field — never by asking the schema which
  fields are references. `Expand.put_expanded/3` only ever REPLACES a field's
  value (with the resolved reference's own already-rendered, already-redacted
  envelope) or leaves it untouched (unresolved ref, non-ref field, or a field
  redacted away before expansion ever ran); a changed value that is itself a
  map carrying `"_id"` — or a list containing one — is an expanded reference,
  and anything else (an ordinary nested object/array field the caller wrote)
  never changes shape between the two calls, so it can never be mistaken for
  one. This is the same "walk what render already decided, never re-derive
  visibility" posture `source_map/2` itself was built on — applied to a
  second render pass instead of the first.

  Each expanded sub-document gets its OWN entry appended to `documents`
  (after the root document at index 0) and its own flat-field mappings,
  addressed by the result path INTO the parent — `$["author"]["name"]` for a
  single reference, `$["authors"][1]["name"]` for the second element of an
  array-of-references. A sub-document's own fields are walked exactly like
  `source_map/2` walks the root (flat only — one more level of `?expand=`
  nesting is out of scope here, same as `Expand.expand/4` itself never
  recurses). Redaction is already correct for free: `expanded`'s sub-document
  values were rendered through `Envelope.render/3` with the SAME
  `caller_context` before `Expand` ever swapped them in.
  """
  @spec source_map(Content.Document.t(), map(), map() | nil) :: map() | nil
  def source_map(doc, rendered, expanded \\ nil)

  def source_map(%{doc_id: doc_id, type: type}, rendered, expanded) when is_map(rendered) do
    case rendered |> Map.keys() |> Enum.reject(&(&1 in @reserved)) |> Enum.sort() do
      [] ->
        nil

      keys ->
        {mappings, table} =
          Enum.reduce(keys, {%{}, path_table_new()}, fn key, {m_acc, table} ->
            {idx, table} = path_table_index(table, result_path(key))

            {Map.put(m_acc, result_path(key), %{
               "source" => %{"document" => 0, "path" => idx},
               "type" => "value"
             }), table}
          end)

        {expand_mappings, expand_docs, _next_doc_idx, table} =
          expand_source_map(rendered, expanded, 1, &result_path/1, table)

        %{
          "documents" => [%{"_id" => doc_id, "_type" => type} | expand_docs],
          "paths" => path_table_to_list(table),
          "mappings" => Map.merge(mappings, expand_mappings)
        }
    end
  end

  def source_map(_doc, _rendered, _expanded), do: nil

  @doc """
  List-result sibling of `source_map/2` (task-b54d854d43769266). A list page
  (home-page cards, a title+author listing) reads `/v1/data/query`, which
  answers no source map, so a click-to-edit overlay could only mark up a
  list's rows with one doc-get per row. Same rule as `source_map/2` — walk
  an ALREADY-RENDERED envelope, never re-derive visibility — applied once
  per ROW instead of once per document.

  `docs` and `rendered_list` must be the SAME LENGTH, in the SAME ORDER
  `Envelope.render_many/3` produced: the ROW INDEX is what addresses a
  mapping's `"document"` entry, so `documents[i]` is always row `i`'s
  source, 1:1 and NEVER deduped — two rows that happen to share a document
  still get two independent addresses, so an edit anchored to one row can
  never alias the other's. A row with no visible user-content field still
  gets a `documents` entry (keeping the index correspondence intact for
  every later row) but contributes no mapping.

  Flat fields only, same scope cut as `source_map/2` — see that function's
  doc for what is deliberately NOT covered here (computed fields, aggregate
  views — `?expand=` is now covered, via the optional third arg below).
  Returns `nil` when no row has a single visible field at all (an empty
  result set, or every row fully redacted).

  Third arg `expanded_list \\ nil` (task-0e0cb2167c6fcdea) — `rendered_list`'s
  sibling AFTER `Expand.expand/4` ran, same length/order, or `nil` (the
  default) for byte-identical flat-only behaviour. Each row's expanded
  reference fields get their OWN `documents` entries, appended AFTER every
  row's own slot (`documents[0..length(docs)-1]` stay the rows, so the
  existing "row index == document index" contract is untouched) and
  addressed by a row-qualified result path — `$[3]["author"]["name"]` for
  row 3's expanded `author` reference. See `source_map/3`'s doc for how the
  diff against `rendered_list` detects an expansion and why it needs no
  schema lookup.
  """
  @spec source_map_many([Content.Document.t()], [map()], [map()] | nil) :: map() | nil
  def source_map_many(docs, rendered_list, expanded_list \\ nil)

  def source_map_many(docs, rendered_list, expanded_list)
      when is_list(docs) and is_list(rendered_list) do
    expanded_list = expanded_list || List.duplicate(nil, length(rendered_list))

    {documents, mappings, expand_documents, _next_doc_idx, table, any_mapped?} =
      [docs, rendered_list, expanded_list]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.reduce(
        {[], %{}, [], length(docs), path_table_new(), false},
        &reduce_row_source_map/2
      )

    if any_mapped? do
      %{
        "documents" => Enum.reverse(documents) ++ expand_documents,
        "paths" => path_table_to_list(table),
        "mappings" => mappings
      }
    end
  end

  def source_map_many(_docs, _rendered_list, _expanded_list), do: nil

  defp reduce_row_source_map(
         {{%{doc_id: doc_id, type: type}, rendered, expanded}, row_idx},
         {docs_acc, mappings_acc, expand_docs_acc, next_doc_idx, table, any_mapped?}
       )
       when is_map(rendered) do
    doc_entry = %{"_id" => doc_id, "_type" => type}

    {row_mappings, table, row_mapped?} =
      case rendered |> Map.keys() |> Enum.reject(&(&1 in @reserved)) |> Enum.sort() do
        [] ->
          {%{}, table, false}

        keys ->
          {m, table} =
            Enum.reduce(keys, {%{}, table}, fn key, {m_acc, table} ->
              {idx, table} = path_table_index(table, result_path(key))

              {Map.put(m_acc, row_result_path(row_idx, key), %{
                 "source" => %{"document" => row_idx, "path" => idx},
                 "type" => "value"
               }), table}
            end)

          {m, table, true}
      end

    {expand_mappings, row_expand_docs, next_doc_idx, table} =
      expand_source_map(rendered, expanded, next_doc_idx, &row_result_path(row_idx, &1), table)

    {
      [doc_entry | docs_acc],
      mappings_acc |> Map.merge(row_mappings) |> Map.merge(expand_mappings),
      expand_docs_acc ++ row_expand_docs,
      next_doc_idx,
      table,
      any_mapped? or row_mapped? or expand_mappings != %{}
    }
  end

  # A row whose document/rendered/expanded triple doesn't match the expected
  # shape (it should never happen — render_many/3 always returns one map per
  # input doc, and the caller passes expanded_list the same length — but this
  # function takes lists a CALLER zips, not ones it derives itself) contributes
  # no entry rather than raising, same fail-soft posture `source_map/2`'s own
  # no-match clause takes.
  defp reduce_row_source_map(_pair, acc), do: acc

  # Shared by `source_map/3` and `source_map_many/3`. `field_prefix_fun` turns
  # a top-level field key into ITS OWN result-path prefix in the caller's
  # outer context (row-qualified for `source_map_many/3`, bare for
  # `source_map/3`); everything below the field — a sub-document's own flat
  # keys, and an array-reference's element index — is addressed the same way
  # regardless of which caller is walking.
  #
  # Detects an expansion by DIFFING `base_rendered` (pre-expand) against
  # `expanded` (post-expand), never by asking the schema which fields are
  # references: `Expand.put_expanded/3` only ever REPLACES a reference
  # field's value with the resolved target's own already-rendered envelope
  # (always carrying `_id` + `_type`) or leaves it byte-identical (unresolved,
  # non-reference, or redacted away before expansion ran) — so "changed, and
  # now shaped like a rendered document" can only ever BE one.
  defp expand_source_map(_base_rendered, nil, next_doc_idx, _field_prefix_fun, table),
    do: {%{}, [], next_doc_idx, table}

  defp expand_source_map(base_rendered, expanded, next_doc_idx, field_prefix_fun, table)
       when is_map(expanded) do
    {mappings, docs_rev, final_doc_idx, table} =
      expanded
      |> Map.keys()
      |> Enum.reject(&(&1 in @reserved))
      |> Enum.sort()
      |> Enum.reduce({%{}, [], next_doc_idx, table}, fn key,
                                                        {mappings_acc, docs_acc, doc_idx, table} ->
        base_val = Map.get(base_rendered, key)
        exp_val = Map.get(expanded, key)

        case diff_expanded_field(base_val, exp_val) do
          :unchanged ->
            {mappings_acc, docs_acc, doc_idx, table}

          {:single, sub_doc} ->
            {sub_mappings, sub_entry, table} =
              sub_document_source_map(sub_doc, field_prefix_fun.(key), doc_idx, table)

            {Map.merge(mappings_acc, sub_mappings), [sub_entry | docs_acc], doc_idx + 1, table}

          {:array, elements} ->
            Enum.reduce(elements, {mappings_acc, docs_acc, doc_idx, table}, fn {el_idx, sub_doc},
                                                                               {m_acc, d_acc,
                                                                                cur_idx, table} ->
              prefix = field_prefix_fun.(key) <> "[#{el_idx}]"

              {sub_mappings, sub_entry, table} =
                sub_document_source_map(sub_doc, prefix, cur_idx, table)

              {Map.merge(m_acc, sub_mappings), [sub_entry | d_acc], cur_idx + 1, table}
            end)
        end
      end)

    {mappings, Enum.reverse(docs_rev), final_doc_idx, table}
  end

  defp expand_source_map(_base_rendered, _expanded, next_doc_idx, _field_prefix_fun, table),
    do: {%{}, [], next_doc_idx, table}

  # A value Expand left byte-identical — not a reference field, an
  # unresolvable reference, or a field redacted away before expansion ran.
  # `===` (not `==`) so a raw `1` field never spuriously "unchanges" against
  # a `1.0` Expand happened to produce — the strict form every other
  # raw-term comparison in this module already uses.
  defp diff_expanded_field(base, exp) when base === exp, do: :unchanged

  # A single reference field, resolved: Expand swapped the raw pointer for
  # the target's own rendered envelope.
  defp diff_expanded_field(_base, %{"_id" => _, "_type" => _} = exp_doc), do: {:single, exp_doc}

  # An array-of-references field: each element that changed AND now looks
  # like a rendered document is one resolved member; an element Expand left
  # untouched (unresolved) is skipped, same as the single-ref nil case.
  defp diff_expanded_field(base, exp) when is_list(exp) do
    base_list = if is_list(base), do: base, else: []

    elements =
      exp
      |> Enum.with_index()
      |> Enum.filter(fn {el, i} ->
        is_map(el) and Map.has_key?(el, "_id") and Map.has_key?(el, "_type") and
          Enum.at(base_list, i) !== el
      end)
      |> Enum.map(fn {el, i} -> {i, el} end)

    if elements == [], do: :unchanged, else: {:array, elements}
  end

  defp diff_expanded_field(_base, _exp), do: :unchanged

  # An expanded sub-document's own flat-field mapping, exactly the same walk
  # `source_map/3` does for the root — one more level of `?expand=` nesting
  # is out of scope (same as `Expand.expand/4` itself never recursing).
  defp sub_document_source_map(
         %{"_id" => sub_id, "_type" => sub_type} = sub_doc,
         prefix,
         doc_index,
         table
       ) do
    keys = sub_doc |> Map.keys() |> Enum.reject(&(&1 in @reserved)) |> Enum.sort()

    {mappings, table} =
      Enum.reduce(keys, {%{}, table}, fn key, {m_acc, table} ->
        {idx, table} = path_table_index(table, result_path(key))

        {Map.put(m_acc, append_path(prefix, key), %{
           "source" => %{"document" => doc_index, "path" => idx},
           "type" => "value"
         }), table}
      end)

    {mappings, %{"_id" => sub_id, "_type" => sub_type}, table}
  end

  defp result_path(key), do: "$[#{inspect(key)}]"

  # One more `[...]` segment onto an EXISTING result-path prefix — never a
  # new leading `$`, unlike `result_path/1`. `field_prefix_fun` callers
  # (`result_path/1`, `row_result_path/2`) already produced the one-and-only
  # `$`; appending `result_path(key)` again here would double it
  # (`$["author"]$["name"]` instead of `$["author"]["name"]`).
  defp append_path(prefix, key), do: prefix <> "[#{inspect(key)}]"

  defp row_result_path(row_idx, key), do: "$[#{row_idx}][#{inspect(key)}]"

  # THE PATH TABLE (task-d0c2bd670e2d8a87) — a single, shared, deduplicated
  # list of BARE in-document path strings (`result_path/1`'s own output,
  # e.g. `$["title"]`, never row- or ref-prefixed), built once across every
  # row and every expanded sub-document a `source_map/3` or
  # `source_map_many/3` call walks. Every mapping's `"source" => %{"path" =>
  # idx}` indexes THIS table, never a per-row or per-sub-document-local
  # count: two different rows (or a row and its own expanded sub-document)
  # that both carry a "title" field correctly reuse the SAME slot, and two
  # different field names always get two different slots, regardless of
  # alphabetical sort order or which row/document introduced the name
  # first. Before this, `path_idx` for a sub-document's or a row's fields
  # was an index into THAT ONE document's own locally-sorted key list, while
  # the emitted `"paths"` array was built from a totally different
  # enumeration (`Map.keys(expand_mappings)`, or a global alphabetical sort
  # of every row's RESULT-side mapping keys) — the two numberings had no
  # relationship, so `paths[path_idx]` could — and in a live query with
  # `?expand=`, did — name the wrong field entirely.
  defp path_table_new, do: {[], %{}, 0}

  defp path_table_index({list_rev, index_of, next_idx} = table, bare_path) do
    case Map.fetch(index_of, bare_path) do
      {:ok, idx} ->
        {idx, table}

      :error ->
        {next_idx, {[bare_path | list_rev], Map.put(index_of, bare_path, next_idx), next_idx + 1}}
    end
  end

  defp path_table_to_list({list_rev, _index_of, _next_idx}), do: Enum.reverse(list_rev)

  @doc """
  Redact an ALREADY-rendered envelope map under a subscriber's caller context —
  the same single chokepoint as `render/3`, but for the rare path that holds a
  frozen envelope snapshot rather than a live `%Document{}`.

  The SSE replay path uses this for a *delete* event: the live document is gone,
  so it cannot be re-rendered, but the stored `mutation_events.document` snapshot
  must still be redacted before it reaches a non-authorized subscriber. `owner_id`
  is the document's owner for `owner_only` checks (nil when unknown ⇒ `owner_only`
  conservatively drops). A `nil` caller FAILS CLOSED — redacted as the anonymous
  PUBLIC-ONLY principal, matching `render/3`; it is NEVER a full-content bypass.
  A trusted internal full-content path passes the explicit `:internal` sentinel.
  """
  def redact(envelope, schema \\ nil, caller_context \\ nil, owner_id \\ nil)

  def redact(envelope, schema, caller_context, owner_id) when is_map(envelope),
    do: redact_by_field_visibility(envelope, schema, caller_context, owner_id)

  # Non-map payload (e.g. a delete event with no stored snapshot) — pass through.
  def redact(envelope, _schema, _caller_context, _owner_id), do: envelope

  # ── field-visibility redaction (the single chokepoint) ────────────────────

  # No caller context => FAIL CLOSED. A nil caller is the most restrictive
  # anonymous principal: redact every private / owner_only / readable_by /
  # encrypted field (public-only). This closes the WS-B leak paths that passed
  # nil and dumped full content. Internal/writer paths that must carry the FULL
  # document pass the explicit `:internal` sentinel below — NEVER nil.
  defp redact_by_field_visibility(envelope, schema, nil, owner_id),
    do: redact_by_field_visibility(envelope, schema, %CallerContext{}, owner_id)

  # Explicit internal/full-content sentinel — the mutation-result echo, the
  # broadcast payload, and the stored mutation_event snapshot (re-redacted
  # per-subscriber downstream) ride this.
  #
  # This comment used to end "Not reachable from any request path." That was
  # FALSE: Content.Broadcast.tap_broadcast/5 runs inside POST /v1/data/mutate,
  # and the unredacted map egresses on EXACTLY TWO seams — ListenController's
  # `live_result/4` admin fast path (the only one reaching a REQUESTER) and
  # Webhooks.Dispatcher.build_payload/6. Both are sound because the
  # `%CallerContext{is_admin: true}` clause just below returns the envelope
  # UNCHANGED, byte-identical to this clause. The true, load-bearing property is
  # that `:internal` is UNFORGEABLE INPUT — CallerContext.from_conn/1 never
  # yields the bare atom — pinned by
  # test/barkpark/content/envelope_internal_sentinel_test.exs. See the moduledoc
  # for the full derivation.
  defp redact_by_field_visibility(envelope, _schema, :internal, _owner_id), do: envelope

  # Admins see everything. Ciphertext is still NOT decrypted (that is the
  # explicit Content.reveal_fields/4 API) — an admin simply sees the envelope.
  defp redact_by_field_visibility(envelope, _schema, %CallerContext{is_admin: true}, _owner_id),
    do: envelope

  defp redact_by_field_visibility(envelope, schema, %CallerContext{} = ctx, owner_id) do
    fields = raw_fields(schema)

    envelope
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      cond do
        # Reserved system keys (_id, _type, …) are never user data — always kept.
        key in @reserved ->
          Map.put(acc, key, value)

        drop_field?(key, value, fields, ctx, owner_id) ->
          acc

        true ->
          Map.put(acc, key, redact_nested(value, find_raw_field(fields, key), ctx, owner_id, 1))
      end
    end)
    |> redact_preview_manifest(fields, ctx, owner_id)
  end

  # THE DERIVED COPY (task-84c95acb380f41e4). `content["preview"]` is stamped at
  # WRITE time by `Barkpark.Preview.project/3` over the full content, so its
  # `description` / `extensions.*` entries are copies of fields this function
  # just dropped. Drop each entry whose source field (`Preview.derived_from/0`)
  # is DECLARED and not visible to this caller. Conservative on purpose: a
  # `description` that could also have come from the public lead paragraph is
  # dropped when the declared excerpt/description/summary field is hidden.
  defp redact_preview_manifest(%{"preview" => %{} = preview} = rendered, fields, ctx, owner_id) do
    hidden? = fn source ->
      case find_raw_field(fields, source) do
        nil -> false
        field -> not field_visible?(field, ctx, owner_id)
      end
    end

    preview =
      Enum.reduce(Barkpark.Preview.derived_from(), preview, fn {path, sources}, acc ->
        if Enum.any?(sources, hidden?), do: drop_in(acc, path), else: acc
      end)

    Map.put(rendered, "preview", preview)
  end

  defp redact_preview_manifest(rendered, _fields, _ctx, _owner_id), do: rendered

  defp drop_in(map, [key]) when is_map(map), do: Map.delete(map, key)

  defp drop_in(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      %{} = inner -> Map.put(map, key, drop_in(inner, rest))
      _ -> map
    end
  end

  defp drop_in(other, _path), do: other

  # ── NESTED declarations (task-777b7903d79fb32e) ───────────────────────────
  #
  # A schema can declare visibility on a field INSIDE another field: a
  # `composite`/object field's `fields` kids (parsed by
  # `SchemaDefinition.parse_field/2`, which copies `private` onto every kid),
  # or the item shape of an `arrayOf`/array field (`of`). This chokepoint used
  # to look at TOP-level keys only, so a visible parent passed every private,
  # owner_only or readable_by kid straight through to an anonymous reader —
  # and `field_readable?/3` judged a dotted filter path by its first segment
  # alone, so the same kid was a filter/order value oracle.
  #
  # The walk follows the DECLARED shape only: a value with no declared kids is
  # left exactly as it was (undeclared ⇒ public, the legacy rule at every
  # depth). It is bounded at `@max_nested_depth` levels so a self-referencing
  # or pathologically deep schema cannot recurse without end; below the bound
  # nothing more is walked, which only ever matters for a schema nested more
  # than 32 levels deep.
  @max_nested_depth 32

  defp redact_nested(value, _field, _ctx, _owner_id, depth) when depth > @max_nested_depth,
    do: value

  defp redact_nested(value, field, ctx, owner_id, depth) when is_map(value) do
    case nested_kids(field) do
      [] ->
        value

      kids ->
        Enum.reduce(value, %{}, fn {key, v}, acc ->
          if drop_field?(key, v, kids, ctx, owner_id) do
            acc
          else
            Map.put(
              acc,
              key,
              redact_nested(v, find_raw_field(kids, key), ctx, owner_id, depth + 1)
            )
          end
        end)
    end
  end

  defp redact_nested(value, field, ctx, owner_id, depth) when is_list(value) do
    case item_field(field) do
      nil -> value
      item -> Enum.map(value, &redact_nested(&1, item, ctx, owner_id, depth + 1))
    end
  end

  defp redact_nested(value, _field, _ctx, _owner_id, _depth), do: value

  # Does this declaration carry ANY visibility restriction? Used to put the
  # restrictive twin first when two array member shapes declare the same kid.
  defp restricted?(field) do
    truthy?(get_attr(field, "private")) or
      get_attr(field, "visibility") in ["private", "owner_only"] or
      list_attr(get_attr(field, "readable_by")) != []
  end

  # The declared kids of an object/composite field (its `fields`), or of the
  # item shape when the field is an array whose items are objects.
  defp nested_kids(nil), do: []

  defp nested_kids(field) do
    case get_attr(field, "fields") do
      kids when is_list(kids) -> kids
      _ -> []
    end
  end

  # The item shape of an array field: `arrayOf`'s single `of` map, or a
  # Sanity-style `of` LIST of member shapes, folded into one pseudo-field whose
  # kids are the union of every member's kids (a kid private in ANY member
  # shape is redacted — the conservative reading of an ambiguous item).
  defp item_field(nil), do: nil

  defp item_field(field) do
    case get_attr(field, "of") do
      %{} = of ->
        of

      members when is_list(members) ->
        kids =
          members
          |> Enum.filter(&is_map/1)
          |> Enum.flat_map(&nested_kids/1)
          |> Enum.sort_by(&if(restricted?(&1), do: 0, else: 1))

        if kids == [], do: nil, else: %{"fields" => kids}

      _ ->
        nil
    end
  end

  defp drop_field?(key, value, fields, ctx, owner_id) do
    cond do
      # Encrypted ciphertext defaults to PRIVATE for every non-admin caller,
      # independent of schema — this holds even when no schema is supplied, so
      # a marked field can never leak (as ciphertext) on any read surface.
      FieldCipher.encrypted?(value) ->
        true

      true ->
        case find_raw_field(fields, key) do
          # Unknown / undeclared field => public (legacy parity).
          nil -> false
          field -> not field_visible?(field, ctx, owner_id)
        end
    end
  end

  # System fields that are always filterable / orderable — real columns or
  # reserved keys, never carriers of per-field visibility metadata.
  @system_filterable ~w(title status doc_id)

  @doc """
  May this caller reference `field_name` in a FILTER or ORDER clause?

  The filter/order query oracle (WS-B MEDIUM-4): a WHERE/ORDER built over a
  field the caller cannot SEE lets them binary-search or sort by its hidden
  value even though `render/3` redacts it from the response body. The read
  surface calls this to REJECT such a clause before it reaches the query layer.

  Fail-closed and consistent with `render/3`'s visibility rules:

    * `:internal` caller and admins ⇒ unrestricted (internal/system reads;
      their output still rides the `render/3` redaction boundary). A `nil`
      caller FAILS CLOSED — the most restrictive anonymous principal, mirroring
      `render/3`'s nil clause; it is NEVER an "unrestricted" signal.
    * reserved (`_id`…) and promoted (`title`/`status`/`doc_id`) fields ⇒ always
      allowed.
    * a declared `private` / `owner_only` / `readable_by` field ⇒ allowed ONLY
      when the caller is authorized (owner_only with no doc in hand ⇒ denied for
      non-admins — conservative).
    * an UNDECLARED field (nil schema or not in `fields`) ⇒ public (legacy
      parity). Encrypted-marked fields are already immune (stored ciphertext
      never matches a plaintext probe).
  """
  # No caller context => FAIL CLOSED. A nil caller is the most restrictive
  # anonymous principal: a declared private / owner_only / readable_by field is
  # NEVER filterable/orderable by it. This mirrors `render/3`'s nil clause
  # (the nil clause of `redact_by_field_visibility/4`) — a nil caller is the
  # anonymous PUBLIC-ONLY principal, never
  # an "internal full-content" signal. Internal/writer paths that must reference
  # a private field in a WHERE/ORDER clause pass the explicit `:internal`
  # sentinel below — NEVER nil. (Every production caller already threads a
  # %CallerContext{}; this fail-closed default is defence in depth.)
  def field_readable?(_schema, _field_name, nil), do: false

  # Explicit internal/full-content sentinel — internal/system reads whose output
  # still rides the `render/3` redaction boundary.
  #
  # Unlike the `render/3` sentinel clause above, this one is genuinely unused:
  # NO in-tree caller passes `:internal` here at all. Every production call site
  # threads an explicit context — `CallerContext.anonymous()` in tasks/board.ex,
  # tasks/query.ex and the tasks board_live peek; the requester's own
  # `%CallerContext{}` in query_controller.ex, legacy_controller.ex and
  # search/highlighter.ex. Only envelope_test.exs exercises this clause. It
  # exists for symmetry with `render/3`, not because a caller needs it.
  def field_readable?(_schema, _field_name, :internal), do: true
  def field_readable?(_schema, _field_name, %CallerContext{is_admin: true}), do: true

  def field_readable?(schema, field_name, %CallerContext{} = ctx) when is_binary(field_name) do
    top = field_top_segment(field_name)

    cond do
      top in @reserved ->
        true

      top in @system_filterable ->
        true

      true ->
        path_readable?(field_segments(field_name), raw_fields(schema), ctx, 1)
    end
  end

  # Any other caller shape => FAIL CLOSED (mirrors `render/3`'s redaction default
  # — an unrecognized principal is the most restrictive, never a bypass).
  def field_readable?(_schema, _field_name, _ctx), do: false

  # Walk EVERY segment of a dotted filter/order path against the declared shape
  # (task-777b7903d79fb32e). The first undeclared segment ends the walk as
  # public (legacy parity); any declared segment the caller cannot see makes
  # the whole path unreadable — `meta.secret` is judged by `secret`, not only by
  # `meta`. A numeric segment (`items.0.name`) addresses an array element and
  # is skipped onto the item shape. Bounded like the redaction walk.
  defp path_readable?(_segments, _fields, _ctx, depth) when depth > @max_nested_depth, do: true
  defp path_readable?([], _fields, _ctx, _depth), do: true

  defp path_readable?([seg | rest], fields, ctx, depth) do
    case find_raw_field(fields, seg) do
      nil ->
        true

      field ->
        field_visible?(field, ctx, nil) and
          path_readable?(drop_index_segment(rest), kids_for_path(field, rest), ctx, depth + 1)
    end
  end

  # The kids the NEXT segment is judged against: an array field's item kids,
  # otherwise the field's own declared kids.
  defp kids_for_path(field, _rest) do
    case item_field(field) do
      nil -> nested_kids(field)
      item -> nested_kids(item)
    end
  end

  defp drop_index_segment([seg | rest]) do
    if seg =~ ~r/\A\d+\z/, do: rest, else: [seg | rest]
  end

  defp drop_index_segment([]), do: []

  defp field_segments(field) do
    field |> String.replace_prefix("content.", "") |> String.split(".")
  end

  # Top-level segment of a (possibly nested / `content.`-prefixed) filter path —
  # `content.meta.seo` and `meta.seo` both resolve their visibility against the
  # declared `meta` parent field.
  defp field_top_segment(field) do
    field |> String.replace_prefix("content.", "") |> String.split(".") |> hd()
  end

  defp field_visible?(field, %CallerContext{} = ctx, owner_id) do
    private = truthy?(get_attr(field, "private"))
    visibility = get_attr(field, "visibility")
    readable_by = list_attr(get_attr(field, "readable_by"))

    cond do
      # An explicit allowlist match always GRANTS access, overriding other flags.
      in_readable_by?(readable_by, ctx) -> true
      private -> false
      visibility == "private" -> false
      visibility == "owner_only" -> owner_match?(ctx, owner_id)
      # A non-empty allowlist with no match is restricted (deny by default).
      readable_by != [] -> false
      true -> true
    end
  end

  defp owner_match?(%CallerContext{user_id: uid}, owner_id)
       when is_binary(uid) and is_binary(owner_id),
       do: uid == owner_id

  defp owner_match?(_ctx, _owner_id), do: false

  defp in_readable_by?(readable_by, %CallerContext{user_id: uid, token_id: tid})
       when is_list(readable_by) do
    (is_binary(uid) and uid in readable_by) or (is_binary(tid) and tid in readable_by)
  end

  defp in_readable_by?(_readable_by, _ctx), do: false

  # The document owner for `owner_only` checks. Phase 4 lands a first-class
  # `owner_id`; until then this is conservatively nil (=> non-owner is dropped),
  # read safely off the struct without assuming the field exists.
  defp doc_owner_id(doc), do: Map.get(doc, :owner_id)

  # Field-metadata source. Both call sites pass a `%SchemaDefinition{}`, whose
  # `fields` are the raw string-keyed JSON maps; the `%Parsed{}` / raw-map shapes
  # are supported defensively. Parse-free on purpose — robust against schemas
  # carrying plugin-namespaced fields that would fail a strict parse.
  defp raw_fields(%SchemaDefinition{fields: f}) when is_list(f), do: f
  defp raw_fields(%SchemaDefinition.Parsed{raw: %{"fields" => f}}) when is_list(f), do: f
  defp raw_fields(%{"fields" => f}) when is_list(f), do: f
  defp raw_fields(_), do: []

  defp find_raw_field(fields, key) when is_list(fields) do
    Enum.find(fields, fn f -> get_attr(f, "name") == key end)
  end

  defp find_raw_field(_fields, _key), do: nil

  # Accept either a string-keyed raw map or an atom-keyed struct/map.
  defp get_attr(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, atomize(key))
  defp get_attr(_map, _key), do: nil

  defp atomize("private"), do: :private
  defp atomize("visibility"), do: :visibility
  defp atomize("readable_by"), do: :readable_by
  defp atomize("name"), do: :name
  defp atomize("fields"), do: :fields
  defp atomize("of"), do: :of
  defp atomize(_), do: :__unknown__

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp list_attr(l) when is_list(l), do: l
  defp list_attr(_), do: []

  defp to_iso8601(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
    |> String.replace_suffix("+00:00", "Z")
  end

  defp to_iso8601(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_iso8601()
    |> String.replace_suffix("+00:00", "Z")
  end

  defp to_iso8601(nil), do: nil

  # ── field projection ──────────────────────────────────────────────────────
  # The system identity/versioning keys every projected hit keeps regardless of
  # the allowlist — a hit must stay addressable and cache-comparable.
  @projection_always ~w(_id _type _draft _publishedId _rev _createdAt _updatedAt)

  @doc """
  Project rendered documents down to a caller-supplied comma-separated field
  ALLOWLIST (plus the system keys) — pure SUBTRACTION after `render`, so it can
  never expose anything the render itself did not.

  Why: the finder surfaces request `limit=100` per keystroke, and a rendered
  paper envelope carries ~37KB of `body_html` the finder never reads — 15MB of
  JSON per keystroke (seconds of wall time; live-caught at 10s on a slow link).
  `?fields=title,description,slug,…` cuts the same reply to ~100KB.

  `nil`/empty/whitespace-only field lists are a no-op (the full envelopes), so
  every existing caller is byte-identical without the param.
  """
  @spec project([map()], String.t() | nil) :: [map()]
  def project(docs, fields) when is_binary(fields) do
    keys =
      fields
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case keys do
      [] ->
        docs

      keys ->
        take = MapSet.new(keys ++ @projection_always)
        Enum.map(docs, &Map.filter(&1, fn {k, _v} -> MapSet.member?(take, k) end))
    end
  end

  def project(docs, _fields), do: docs
end
