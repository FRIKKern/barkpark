defmodule Barkpark.Content.Codelists do
  @moduledoc """
  Codelist registry — pluggable, plugin-discriminated codelist storage.

  Backed by three tables:

    * `codelists` — list headers, keyed by `(plugin_name, list_id, issue)`
    * `codelist_values` — entries (with optional `parent_id` for hierarchy)
    * `codelist_value_translations` — multi-language labels per entry

  ## Plugin discriminator (Decision 20)

  `plugin_name` is the discriminator. Two plugins may register a list_id like
  `"language"` without collision. The list_id convention is `<plugin>:<name>`
  for grep-ability (e.g. `"onixedit:contributor_role"`). Both halves of the
  identity are stored explicitly: the column is the discriminator, the string
  is the human-friendly ID.

  ## Idempotent registration

  Calling `register/3` twice with the same `(plugin_name, list_id, issue)` is
  idempotent: the codelist row's metadata is upserted, all of its existing
  values + translations are deleted (cascading) and re-inserted from the
  payload. Re-registration with a different `issue` creates a NEW codelist
  row alongside the previous one (history is preserved).

  ## Default-language fallback

  `lookup/3` resolves labels in this order: the languages passed via
  `:languages`, falling back to `["nob", "eng"]`, then any other available
  translation. The first translation matching a language in the chain wins.
  """

  import Ecto.Query

  alias Barkpark.Repo
  alias Barkpark.Content.Codelists.{Codelist, Translation, Value}
  alias Barkpark.Content.SchemaDefinition

  require Logger

  @default_languages ["nob", "eng"]

  # ── Friendly-name alias resolver (Task barkpark-2nw) ─────────────────────
  #
  # The OnixEdit `book` schema declares codelist refs by friendly name
  # (e.g. `"onixedit:contributor_role"`) with a sibling `onix.codelistId: 17`.
  # `Barkpark.Codelists.EDItEUR.parse_xml/1` writes registry rows under the
  # numeric `list_id` (`"onixedit:list_17"`). The alias map closes that gap
  # by walking SchemaDefinition rows once per dataset, building a
  # `friendly => "onixedit:list_<N>"` table, and consulting it from `get/2`
  # whenever the direct lookup misses.
  #
  # Cached in a named ETS table keyed by plugin_name with a TTL — schema
  # upserts at boot don't invalidate the cache themselves; the next call
  # after `@alias_cache_ttl_ms` rebuilds. Boot does a single sweep, then
  # subsequent rebuilds are cheap (one query against schema_definitions,
  # in-memory walk). ETS (not `:persistent_term`) so the per-TTL re-store on
  # the parse read path doesn't trigger a BEAM-wide global GC each time; keys
  # are bounded by plugin_name, so no size cap is needed.

  @alias_cache :barkpark_codelists_alias_cache
  @alias_cache_ttl_ms 60_000

  # Friendly codelist names that declare an `onix.codelistId` value which
  # is NOT a pointer to an EDItEUR ONIX codelist — it's a value from ONIX
  # list 27 (SubjectSchemeIdentifier) naming an *external* scheme. The
  # alias resolver must NOT rewrite these to `onixedit:list_<N>` (which
  # would resolve to an unrelated ONIX list, e.g. value 93 → "Supplier
  # role"). Instead the friendly name is the canonical key — Thema is
  # seeded directly under `onixedit:thema` (see
  # `Barkpark.Codelists.EDItEUR.seed_thema/1`).
  #
  # The qualifier names below are listed even though they aren't yet
  # referenced from `book.json` — they're the documented Thema qualifier
  # lists (place, language, time-period, educational-purpose,
  # interest-age, style) and adding them up front keeps the allowlist
  # complete the moment any future plugin schema declares them.
  @external_scheme_friendlies ~w(
    onixedit:thema
    onixedit:thema_place_qualifier
    onixedit:thema_language_qualifier
    onixedit:thema_time_period_qualifier
    onixedit:thema_educational_purpose_qualifier
    onixedit:thema_interest_age_qualifier
    onixedit:thema_style_qualifier
  )

  @typedoc """
  Input value tree node accepted by `register/3`.

      %{
        code: "A01",
        position: 0,                       # optional
        metadata: %{...},                  # optional
        translations: [
          %{language: "eng", label: "By (author)", description: "..."}
        ],
        children: [%{code: "A01.1", ...}]   # optional
      }
  """
  @type value_input :: %{
          required(:code) => String.t(),
          optional(:position) => integer() | nil,
          optional(:metadata) => map() | nil,
          optional(:translations) => [translation_input()],
          optional(:children) => [value_input()]
        }

  @type translation_input :: %{
          required(:language) => String.t(),
          required(:label) => String.t(),
          optional(:description) => String.t() | nil
        }

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Register a codelist for a plugin.

  `attrs` accepts:

    * `:issue` (required) — pinned issue/version, e.g. `"73"` or `"2024-q1"`
    * `:name` — display name, e.g. `"ONIX Contributor Role 73"`
    * `:description` — long-form description
    * `:values` — list of `t:value_input/0` (may nest via `:children`)

  Returns `{:ok, codelist}` with the persisted `Codelist` (without preloads).
  Re-registration of the same `(plugin_name, list_id, issue)` is idempotent:
  the header row is upserted in place, and all existing values + translations
  are deleted and replaced.
  """
  @spec register(String.t(), String.t(), map()) :: {:ok, %Codelist{}} | {:error, term()}
  def register(plugin_name, list_id, attrs)
      when is_binary(plugin_name) and is_binary(list_id) and is_map(attrs) do
    issue = fetch_issue!(attrs)
    name = Map.get(attrs, :name)
    description = Map.get(attrs, :description)
    values = Map.get(attrs, :values) || []

    # A codelist replacement is a boot-time / operator-shaped write, never a
    # request-path one: the two OnixEdit seeders run it at every boot, and the
    # Thema snapshot alone is ~3,000 nodes whose `replace_values!` DELETE
    # cascades into translations before the chunked INSERTs land. MEASURED on
    # guerrilla 2026-09-02 during a busy campaign hour: the boot-time Thema
    # seed died with ERROR 57014 query_canceled on the role's 60 s
    # statement_timeout — a slot that fails to START because the box is
    # already busy is the incident feeding itself. `config/runtime.exs` now
    # sends a 30 s wall on every pool connection, so this transaction lifts it
    # for its own statements (SET LOCAL — it dies with the transaction, never
    # leaks into the pool). The bound on a seed is "as long as the snapshot
    # takes", exactly like WorkspaceBundle's COPY; see `Barkpark.Repo`'s
    # opt-out inventory.
    Repo.transaction(fn ->
      Repo.set_local_statement_timeout!(:infinity)
      codelist = upsert_codelist!(plugin_name, list_id, issue, name, description)
      written = replace_values!(codelist, values)
      assert_payload_written!(list_id, values, written)
      codelist
    end)
  end

  @doc """
  Get the latest-issue codelist for a plugin's list_id.

  Returns the `Codelist` with `values` and their `translations` preloaded, or
  `nil` if no codelist is registered.

  "Latest" is determined by descending `issue` string ordering, which is
  correct for ONIX-style integer issues padded with leading zeros and for
  ISO-style semantic versions like `"2024-q1"`. Callers wanting an exact
  issue should query the schema modules directly.
  """
  @spec get(String.t(), String.t()) :: %Codelist{} | nil
  def get(plugin_name, list_id) do
    case do_get(plugin_name, list_id) do
      nil ->
        # Friendly-name fallback. `book.json` references codelists by
        # human-readable names (`onixedit:contributor_role`) while the
        # EDItEUR parser writes numeric rows (`onixedit:list_17`). Walk
        # the cached alias table built from schema metadata to resolve.
        case resolve_alias(plugin_name, list_id) do
          nil -> nil
          aliased_list_id -> do_get(plugin_name, aliased_list_id)
        end

      %Codelist{} = codelist ->
        codelist
    end
  end

  defp do_get(plugin_name, list_id) do
    Codelist
    |> where([c], c.plugin_name == ^plugin_name and c.list_id == ^list_id)
    |> order_by([c], desc: c.issue)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      codelist -> Repo.preload(codelist, values: :translations)
    end
  end

  @doc """
  Force-rebuild the friendly-name alias cache.

  Useful right after a schema upsert when you want the new mapping to
  land immediately (the TTL-based rebuild kicks in after
  `#{@alias_cache_ttl_ms}` ms otherwise). Returns the freshly built map.
  """
  @spec rebuild_alias_cache(String.t()) :: map()
  def rebuild_alias_cache(plugin_name) when is_binary(plugin_name) do
    aliases = build_alias_map(plugin_name)
    store_alias_cache(plugin_name, aliases)
    aliases
  end

  @doc """
  Look up a single code in a codelist.

  Returns `%{value: code, label: "...", parent_code: nil | "..."}` for the
  matching code, or `nil` if either the codelist or the code is unknown.

  ## Options

    * `:languages` — preferred language order; defaults to `["nob", "eng"]`.
      The first translation matching a language in the chain wins. If no
      preferred language matches, the first translation by any language is
      used. If the value has no translations at all, `:label` is the code.
  """
  @spec lookup(String.t(), String.t(), String.t(), keyword()) :: map() | nil
  # @canonical capability:codelist-lookup aka:codelist,codelist_value,codelist_label
  def lookup(plugin_name, list_id, code, opts \\ []) do
    languages = Keyword.get(opts, :languages, @default_languages)

    with %Codelist{id: codelist_id} <-
           latest_codelist_id(plugin_name, list_id),
         %Value{} = value <- fetch_value(codelist_id, code) do
      parent_code =
        case value.parent_id do
          nil ->
            nil

          parent_id ->
            Repo.one(from v in Value, where: v.id == ^parent_id, select: v.code)
        end

      %{
        value: value.code,
        label: resolve_label(value, languages),
        parent_code: parent_code
      }
    else
      _ -> nil
    end
  end

  @doc """
  Build the codelist as a nested tree.

  Returns a list of root maps `[%{value, label, children: [...]}]` walking
  from `parent_id IS NULL` downward. Children are ordered by `position`
  ascending (nulls last) then by `code`.

  Implementation: one query for all values, one query for all translations,
  then assembly in memory. Safe to materialize for ~3000-entry trees like
  Thema (codelist 93).
  """
  @spec tree(String.t(), String.t(), keyword()) :: [map()]
  def tree(plugin_name, list_id, opts \\ []) do
    languages = Keyword.get(opts, :languages, @default_languages)

    case latest_codelist_id(plugin_name, list_id) do
      nil ->
        []

      %Codelist{id: codelist_id} ->
        values =
          Value
          |> where([v], v.codelist_id == ^codelist_id)
          |> Repo.all()

        value_ids = Enum.map(values, & &1.id)

        translations =
          Translation
          |> where([t], t.codelist_value_id in ^value_ids)
          |> Repo.all()
          |> Enum.group_by(& &1.codelist_value_id)

        build_tree(values, translations, languages)
    end
  end

  @doc """
  List all codelists registered under a plugin (latest issue per list_id).
  Useful for debugging.
  """
  @spec list(String.t()) :: [%Codelist{}]
  def list(plugin_name) do
    Codelist
    |> where([c], c.plugin_name == ^plugin_name)
    |> order_by([c], asc: c.list_id, desc: c.issue)
    |> Repo.all()
  end

  # ── Internals ────────────────────────────────────────────────────────────

  defp fetch_issue!(%{issue: issue}) when is_binary(issue) and issue != "", do: issue
  defp fetch_issue!(%{issue: issue}) when is_integer(issue), do: Integer.to_string(issue)

  defp fetch_issue!(_),
    do: raise(ArgumentError, "register/3 requires :issue (string or integer)")

  defp upsert_codelist!(plugin_name, list_id, issue, name, description) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.get_by(Codelist,
           plugin_name: plugin_name,
           list_id: list_id,
           issue: issue
         ) do
      nil ->
        %Codelist{}
        |> Codelist.changeset(%{
          plugin_name: plugin_name,
          list_id: list_id,
          issue: issue,
          name: name,
          description: description
        })
        |> Repo.insert!()

      existing ->
        existing
        |> Codelist.changeset(%{name: name, description: description})
        |> Ecto.Changeset.force_change(:updated_at, now)
        |> Repo.update!()
    end
  end

  # ── Bulk value writer ────────────────────────────────────────────────────
  #
  # `register/3` runs the ENTIRE payload inside one `Repo.transaction`, so
  # the statement count is a correctness property, not a tuning knob. The
  # original writer issued one `Repo.insert!` per value AND one per
  # translation: the bundled Thema snapshot (9187 codes, a label each) cost
  # ~18,400 round trips under a single connection deadline. On 2026-08-19 a
  # loaded host overran that deadline and Postgres cancelled the write
  # (`ERROR 57014 (query_canceled)`) — the transaction rolled back, boot
  # carried on, and the registry was left with the codelist ABSENT while the
  # server served 200s. `codelists_bulk_write_test.exs` reproduces the same
  # disconnect with a 1200-row payload.
  #
  # Both tables use `:binary_id` primary keys, so ids are generated here and
  # the whole tree — parents and children alike — goes out in one flat pass
  # with `parent_id` already resolved. No per-level returning round trip.
  #
  # Trade-off, recorded deliberately: `insert_all/2` bypasses the changesets,
  # so a nil `:code` now surfaces as a Postgres NOT NULL violation and a
  # duplicate code as a unique violation, where the per-row writer raised
  # `Ecto.InvalidChangesetError`. Both still raise inside the transaction and
  # both still roll the whole registration back; only the exception struct
  # differs. `Map.fetch!/2` on `:code`, `:language`, and `:label` is kept
  # verbatim, so a payload missing a required key still fails before any SQL.

  # 8 columns per value row; 2_000 rows is 16_000 bind parameters, well under
  # Postgres' 65_535 limit with headroom for the wider translation row.
  @insert_chunk 2_000

  # Returns the row counts Postgres reported writing, as
  # `%{values: n, translations: m}`. It does NOT return a bare `:ok`: a
  # sentinel here would destroy the write's outcome one frame below its
  # caller, and this writer has three distinguishable outcomes — raised and
  # lost, raised and landed, and (the one no error code reports) SUCCEEDED
  # and lost. `register/3` reads the counts back and rolls the transaction
  # back on disagreement.
  defp replace_values!(%Codelist{id: codelist_id}, values) do
    # Cascading FK deletes translations along with values.
    Repo.delete_all(from v in Value, where: v.codelist_id == ^codelist_id)

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {value_rows, translation_rows} =
      flatten_values(values, codelist_id, nil, now, {[], []})

    # Values before translations: the FK on `codelist_value_id` is checked
    # per statement, so the parents must already be on disk. Within the value
    # list, the depth-first order below guarantees a parent precedes its
    # children, satisfying the self-referencing `parent_id` FK too.
    %{
      values: insert_all_chunked!(Value, Enum.reverse(value_rows)),
      translations: insert_all_chunked!(Translation, Enum.reverse(translation_rows))
    }
  end

  # The SECOND instrument, and deliberately not a restatement of the first.
  # `insert_all_chunked!/2` compares what Postgres wrote against what the
  # flattening pass handed it; this compares the persisted totals against an
  # INDEPENDENT recount of the caller's own payload. A bug that dropped a
  # node inside `flatten_values/5` would satisfy the inner check — every row
  # handed over was written — and only this one catches it.
  #
  # Raising inside `Repo.transaction` rolls the whole registration back, so
  # the failure mode is a codelist that stays at its previous state, never a
  # published truncation.
  defp assert_payload_written!(list_id, values, written) do
    {expected_values, expected_translations} = payload_totals(values)

    if {expected_values, expected_translations} != {written.values, written.translations} do
      raise "codelist #{list_id}: registration persisted #{written.values} value(s) and " <>
              "#{written.translations} translation(s), but the payload carried " <>
              "#{expected_values} and #{expected_translations} — rolling back rather than " <>
              "publishing a truncated codelist"
    end

    :ok
  end

  defp payload_totals(values) do
    Enum.reduce(values, {0, 0}, fn value, {value_count, translation_count} ->
      {child_values, child_translations} = payload_totals(Map.get(value, :children, []))

      {value_count + 1 + child_values,
       translation_count + length(Map.get(value, :translations, [])) + child_translations}
    end)
  end

  # Depth-first pre-order walk — the exact visit order the per-row writer
  # produced — accumulating REVERSED lists so each step is a prepend. The
  # caller reverses once.
  defp flatten_values(inputs, codelist_id, parent_id, now, acc) do
    Enum.reduce(inputs, acc, fn input, {values, translations} ->
      id = Ecto.UUID.generate()

      value_row = %{
        id: id,
        codelist_id: codelist_id,
        parent_id: parent_id,
        code: Map.fetch!(input, :code),
        position: Map.get(input, :position),
        metadata: Map.get(input, :metadata),
        inserted_at: now,
        updated_at: now
      }

      translations =
        input
        |> Map.get(:translations, [])
        |> Enum.reduce(translations, fn t, acc ->
          [
            %{
              id: Ecto.UUID.generate(),
              codelist_value_id: id,
              language: Map.fetch!(t, :language),
              label: Map.fetch!(t, :label),
              description: Map.get(t, :description),
              inserted_at: now,
              updated_at: now
            }
            | acc
          ]
        end)

      flatten_values(
        Map.get(input, :children, []),
        codelist_id,
        id,
        now,
        {[value_row | values], translations}
      )
    end)
  end

  # Returns the number of rows Postgres reported writing. With the default
  # `on_conflict: :raise` an `insert_all` either writes every row it was
  # handed or raises, so a short count is an anomaly no error code would
  # surface — the "succeeded and lost" outcome. Raise on it rather than hand
  # the caller a number it has no reason to distrust.
  defp insert_all_chunked!(schema, rows) do
    intended = length(rows)

    written =
      rows
      |> Enum.chunk_every(@insert_chunk)
      |> Enum.reduce(0, fn chunk, acc ->
        {count, nil} = Repo.insert_all(schema, chunk)
        acc + count
      end)

    if written != intended do
      raise "codelist bulk write lost rows: handed #{intended} #{inspect(schema)} row(s), " <>
              "Postgres reported writing #{written}"
    end

    written
  end

  defp latest_codelist_id(plugin_name, list_id) do
    case do_latest_codelist_id(plugin_name, list_id) do
      nil ->
        # Friendly-name fallback, mirroring `get/2`: `book.json` references
        # codelists by human-readable names (`onixedit:contributor_role`)
        # while the EDItEUR parser writes numeric rows (`onixedit:list_17`).
        # Without this, View-mode `codelist_label/3` (which flows through
        # `lookup/4`/`tree/3`) rendered the raw CODE for every numeric-seeded
        # list, while the Edit dropdown (via `get/2`) showed the real label.
        case resolve_alias(plugin_name, list_id) do
          nil -> nil
          aliased_list_id -> do_latest_codelist_id(plugin_name, aliased_list_id)
        end

      %Codelist{} = codelist ->
        codelist
    end
  end

  defp do_latest_codelist_id(plugin_name, list_id) do
    Codelist
    |> where([c], c.plugin_name == ^plugin_name and c.list_id == ^list_id)
    |> order_by([c], desc: c.issue)
    |> limit(1)
    |> Repo.one()
  end

  defp fetch_value(codelist_id, code) do
    Repo.one(
      from v in Value,
        where: v.codelist_id == ^codelist_id and v.code == ^code,
        preload: [:translations]
    )
  end

  defp resolve_label(%Value{translations: translations} = value, languages)
       when is_list(translations) do
    case pick_translation(translations, languages) do
      nil -> value.code
      %Translation{label: label} -> label
    end
  end

  defp resolve_label(%Value{} = value, _languages), do: value.code

  defp pick_translation([], _languages), do: nil

  defp pick_translation(translations, languages) do
    by_language = Map.new(translations, &{&1.language, &1})

    Enum.find_value(languages, fn lang -> Map.get(by_language, lang) end) ||
      List.first(translations)
  end

  defp build_tree(values, translations_by_value, languages) do
    children_by_parent = Enum.group_by(values, & &1.parent_id)

    children_by_parent
    |> Map.get(nil, [])
    |> sort_values()
    |> Enum.map(&assemble_node(&1, children_by_parent, translations_by_value, languages))
  end

  defp assemble_node(%Value{} = value, children_by_parent, translations_by_value, languages) do
    translations = Map.get(translations_by_value, value.id, [])
    label = resolve_label(%{value | translations: translations}, languages)

    children =
      children_by_parent
      |> Map.get(value.id, [])
      |> sort_values()
      |> Enum.map(&assemble_node(&1, children_by_parent, translations_by_value, languages))

    %{value: value.code, label: label, children: children}
  end

  defp sort_values(values) do
    Enum.sort_by(values, fn v ->
      pos = if v.position == nil, do: :infinity, else: v.position
      {pos, v.code}
    end)
  end

  # ── Alias resolver internals ────────────────────────────────────────────

  # Look up `list_id` in the friendly-name alias cache for `plugin_name`.
  # Returns the numeric `list_id` (e.g. `"onixedit:list_17"`) to retry
  # with, or `nil` when no alias exists. Quietly rebuilds the cache when
  # the entry is stale.
  defp resolve_alias(plugin_name, list_id) do
    aliases = get_alias_cache(plugin_name)
    Map.get(aliases, list_id)
  end

  defp get_alias_cache(plugin_name) do
    ensure_alias_cache()

    case :ets.lookup(@alias_cache, plugin_name) do
      [] ->
        rebuild_alias_cache(plugin_name)

      [{^plugin_name, {map, built_at_ms}}] ->
        now = System.monotonic_time(:millisecond)

        if now - built_at_ms > @alias_cache_ttl_ms do
          rebuild_alias_cache(plugin_name)
        else
          map
        end
    end
  rescue
    e ->
      Logger.warning(
        "Codelists.get_alias_cache failed (plugin=#{plugin_name}): #{Exception.message(e)} — returning empty"
      )

      %{}
  end

  defp store_alias_cache(plugin_name, map) do
    ensure_alias_cache()
    :ets.insert(@alias_cache, {plugin_name, {map, System.monotonic_time(:millisecond)}})
    :ok
  end

  defp ensure_alias_cache do
    case :ets.whereis(@alias_cache) do
      :undefined ->
        try do
          :ets.new(@alias_cache, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end

  # Walk every `SchemaDefinition` row in the DB, recursively descend its
  # `:fields` tree, and collect mappings:
  #
  #     "onixedit:contributor_role" => "onixedit:list_17"
  #
  # Fields with both `codelistId == "<plugin>:<friendly>"` AND a sibling
  # `onix.codelistId: <integer>` contribute one entry. The integer is
  # rendered into the canonical numeric list_id format used by the
  # EDItEUR parser. Dataset is not filtered — schemas may live in any
  # dataset, and the OnixEdit `book` schema is in `production` by
  # default, but the alias is plugin-scoped, so any dataset's schema
  # works.
  defp build_alias_map(plugin_name) do
    schemas =
      SchemaDefinition
      |> Repo.all()

    Enum.reduce(schemas, %{}, fn schema, acc ->
      walk_fields_for_aliases(schema.fields || [], plugin_name, acc)
    end)
  rescue
    # In test envs the DB may not be set up; treat as empty cache.
    e ->
      Logger.warning(
        "Codelists.build_alias_map failed (plugin=#{plugin_name}): #{Exception.message(e)} — returning empty"
      )

      %{}
  end

  defp walk_fields_for_aliases(fields, plugin_name, acc) when is_list(fields) do
    Enum.reduce(fields, acc, &walk_field_for_aliases(&1, plugin_name, &2))
  end

  defp walk_fields_for_aliases(_, _plugin_name, acc), do: acc

  defp walk_field_for_aliases(field, plugin_name, acc) when is_map(field) do
    acc = maybe_record_alias(field, plugin_name, acc)

    # Descend into composite, arrayOf, and any other field that carries
    # nested fields. Fields are persisted as plain maps with string keys
    # (the `SchemaDefinition.fields` Ecto type is `{:array, :map}`), but
    # in-memory plugin builds may still hand atom keys — handle both.
    acc =
      case fetch_either(field, "fields", :fields) do
        nil -> acc
        inner -> walk_fields_for_aliases(inner, plugin_name, acc)
      end

    case fetch_either(field, "of", :of) do
      nil ->
        acc

      of when is_map(of) ->
        # `arrayOf` carries one inner field map under `of`; descend it.
        # If `of` carries its own nested `fields` (composite-of-composite),
        # `walk_field_for_aliases` recurses correctly.
        walk_field_for_aliases(of, plugin_name, acc)

      _ ->
        acc
    end
  end

  defp walk_field_for_aliases(_, _plugin_name, acc), do: acc

  defp maybe_record_alias(field, plugin_name, acc) do
    friendly = fetch_either(field, "codelistId", :codelistId)
    onix = fetch_either(field, "onix", :onix)

    with true <- is_binary(friendly),
         true <- String.starts_with?(friendly, plugin_name <> ":"),
         # External-scheme allowlist (e.g. Thema): the field's
         # `onix.codelistId` is an ONIX list 27 value, NOT a pointer
         # to an EDItEUR codelist. Skip alias recording so the direct
         # lookup hits the friendly-keyed registry row.
         false <- friendly in @external_scheme_friendlies,
         %{} = onix_map <- (is_map(onix) && onix) || nil,
         num when is_integer(num) <- fetch_either(onix_map, "codelistId", :codelistId) do
      numeric_list_id = "#{plugin_name}:list_#{num}"

      # Only add when the friendly key differs from the numeric — saves
      # the resolver from doing a no-op retry, and avoids shadowing in
      # the unlikely case schemas use the numeric form directly.
      if friendly == numeric_list_id do
        acc
      else
        Map.put(acc, friendly, numeric_list_id)
      end
    else
      _ -> acc
    end
  end

  defp fetch_either(map, str_key, atom_key) when is_map(map) do
    case Map.fetch(map, str_key) do
      {:ok, v} -> v
      :error -> Map.get(map, atom_key)
    end
  end

  defp fetch_either(_, _, _), do: nil
end
