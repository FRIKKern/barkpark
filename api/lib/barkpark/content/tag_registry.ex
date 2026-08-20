defmodule Barkpark.Content.TagRegistry do
  @moduledoc """
  The controlled tag vocabulary — `type:tag` DOCUMENTS per dataset — and the
  publish wall's E3 gate over it (authoring-excellence charter D3/D12).

  ## Registry = published tag documents

  A tag is REGISTERED iff a PUBLISHED `type:tag` document whose `doc_id` equals
  the tag string exists in the dataset scope. Registering a tag = publishing a
  tag doc — deliberate, audited, per-dataset, writable through every existing
  document surface. Codelists were rejected as the registry substrate: they are
  global, boot-seeded, plugin-gated, and have no write surface — all four fail
  the fresh-install (plugins-off) invariant.

  ## Core schema registration (D12 — fail-LOUD, outside the swallow)

  The `tag` schema is CORE, not plugin-declared: `register!/1` upserts it
  directly via `Content.upsert_schema/2` and RAISES on failure so boot fails
  CLOSED — a core type that cannot register is a hard bug, never a
  logged-and-ignored one. `Barkpark.SchemaBootstrap.init/1` calls it BEFORE its
  defensive `try/rescue`, so the rescue (which logs and returns `:ignore`) can
  never swallow a failed registration. It is deliberately NOT routed through
  `Plugins.Bootstrap.register_all_schemas/0`, whose `Registry.all()` walk is
  EMPTY under `config :barkpark, :plugins, []`. `upsert_schema/2` is idempotent
  on `(name, dataset)`, so running it every boot is safe.

  ## E3 gate

  `validate_publish/3` runs in the publish wall chain
  (`Content.Lifecycle.publish_document/4`): every weighted `tags[].tag` on the
  draft must resolve to a registered tag, else
  `{:error, {:unknown_tag, payload}}` — rendered 422 `unknown_tag` — carrying
  the unknown names plus the trgm-nearest registered tags as per-name
  suggestions, so a rejected publish costs an authoring agent exactly one
  retry with a machine-readable fix. Only the WEIGHTED label shape
  (`[{tag, strength, rationale}]`) is gated here; legacy flat-string tags and
  untagged documents are the label-spine/exemption gates' business, not E3's.

  ## Legacy import

  `seed_legacy_drafts/2` (driven by `mix barkpark.tags.seed`) imports the
  distinct legacy flat-string tags as DRAFT tag docs for human/curator
  promotion. It never publishes: registering the legacy vocabulary is a
  deliberate act, not a migration side-effect.
  """

  import Ecto.Query

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Scope, SchemaDefinition}
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @tag_type "tag"

  # trgm suggestion tuning: at most 3 candidates per unknown name, and never a
  # candidate below 0.1 similarity — an unrelated vocabulary must yield an
  # EMPTY suggestion list, not a misleading one.
  @suggestion_limit 3
  @suggestion_floor 0.1

  @doc """
  The canonical `tag` schema definition — string-keyed so `upsert_schema/2`
  (which injects the string `"dataset"` key) never produces a mixed-key map.

  Single source of truth: boot registration (`register!/1`) and the
  plugins-off regression bar (`plugin_free_boot_test.exs` reseeds it as the
  9th host schema) both read THIS function, so the two can't drift.
  """
  @spec schema_attrs() :: map()
  def schema_attrs do
    %{
      "name" => @tag_type,
      "title" => "Tag",
      "icon" => "🏷",
      "visibility" => "public",
      "fields" => [
        %{"name" => "title", "title" => "Title", "type" => "string"},
        %{"name" => "description", "title" => "Description", "type" => "text", "rows" => 2}
      ]
    }
  end

  @doc """
  Register the core `tag` schema in `dataset` — RAISES on failure (D12).

  Called by `SchemaBootstrap.init/1` OUTSIDE its defensive rescue: a failed
  core registration must fail the boot closed, not log-and-proceed into a
  system whose publish wall cannot resolve any tag.
  """
  @spec register!(String.t()) :: Barkpark.Content.SchemaDefinition.t()
  def register!(dataset) when is_binary(dataset), do: register_attrs!(schema_attrs(), dataset)

  @doc """
  The fail-loud upsert seam behind `register!/1`, parameterized on `attrs` so
  the raise-on-error contract is directly testable (`register!/1` itself only
  ever feeds it the canonical `schema_attrs/0`).

  ## The pull-provenance guard, on the UPDATE only (PDS-D125/D126)

  This is the SECOND boot-time writer into `schema_definitions` — it runs
  outside `Plugins.Bootstrap`'s registry walk and outside `SchemaBootstrap`'s
  rescue — so it can clobber a pulled row exactly as bootstrap could. It
  clobbers a SMALLER set: `schema_attrs/0` declares five keys and
  `Ecto.Changeset.cast/3` ignores keys absent from params, so a stamped `tag`
  row lost `title`, `icon`, `visibility`, `fields` while `owner_scoped`,
  `cors_origins`, `desk_groups`, `list_preview` survived. Measured, not
  reasoned.

  So: when the row this write would MATCH is pull-provenance-stamped data
  (`Tenancy.pulled_schema_row/2` — the ONE predicate, shared with bootstrap),
  the UPDATE is skipped, the drift is logged, and the pulled row is returned
  unchanged.

  INSERT-WHEN-ABSENT STAYS UNCONDITIONAL, and that asymmetry is the point. D12
  puts this call outside the boot rescue precisely so a missing core `tag`
  schema fails the boot CLOSED rather than booting a system whose publish wall
  can resolve no tag at all. A guard that also skipped the insert would trade a
  clobber bug for a boot-closed-guarantee bug — the predicate returns `nil` when
  there is no row, so the insert simply proceeds.
  """
  @spec register_attrs!(map(), String.t()) :: Barkpark.Content.SchemaDefinition.t()
  def register_attrs!(attrs, dataset) when is_map(attrs) and is_binary(dataset) do
    case Tenancy.pulled_schema_row(attrs["name"], dataset) do
      %SchemaDefinition{} = pulled -> skip_pulled(pulled, dataset)
      nil -> do_register!(attrs, dataset)
    end
  end

  # The sticky skip needs a way out, and the operator gets the literal call —
  # same escape hatch, same wording contract as `Plugins.Bootstrap.skip_pulled/3`.
  defp skip_pulled(%SchemaDefinition{} = pulled, dataset) do
    Logger.warning(
      "TagRegistry: core `tag` schema (dataset=#{inspect(dataset)}) sits in a PULLED " <>
        "workspace/dataset (pull_provenance stamped) — skipping the content update. The " <>
        "local `tag` declaration and the pulled row have DRIFTED. Re-pull to refresh the " <>
        "row, or accept the local version by clearing the stamp from a console: " <>
        "Barkpark.Tenancy.set_pull_provenance(<workspace_id_or_struct>, #{inspect(dataset)}, %{})"
    )

    pulled
  end

  defp do_register!(attrs, dataset) do
    case Content.upsert_schema(attrs, dataset) do
      {:ok, schema} ->
        schema

      {:error, reason} ->
        raise "Barkpark.Content.TagRegistry: core `tag` schema failed to register in " <>
                "dataset #{inspect(dataset)} — boot fails CLOSED (charter D12): " <>
                inspect(reason)
    end
  end

  @doc """
  E3 gate: `:ok`, or `{:error, {:unknown_tag, payload}}` when the draft carries
  weighted `tags` whose names do not all resolve to PUBLISHED `type:tag` docs
  in the dataset scope.

  `payload` is `%{unknown: [name], suggestions: %{name => [nearest]}}` — the
  suggestions are trgm-nearest registered tags (`similarity/2`, pg_trgm), best
  first, empty when nothing registered comes close.

  Deliberately fail-CLOSED: a registry read error propagates (the publish
  fails) rather than waving unknown tags through — the wall is enforcement,
  not a guard rail.
  """
  @spec validate_publish(Document.t(), String.t(), keyword()) ::
          :ok | {:error, {:unknown_tag, map()}}
  def validate_publish(%Document{} = draft, dataset, opts) do
    case weighted_tag_names(draft.content) do
      [] ->
        :ok

      names ->
        registered = registered_subset(names, dataset, opts)

        case Enum.reject(names, &MapSet.member?(registered, &1)) do
          [] ->
            :ok

          unknown ->
            suggestions =
              Map.new(unknown, fn name -> {name, nearest_registered(name, dataset, opts)} end)

            {:error, {:unknown_tag, %{unknown: unknown, suggestions: suggestions}}}
        end
    end
  end

  @doc """
  Import the dataset's DISTINCT tag names as DRAFT tag docs.

  Sweeps every schema type via `Content.search_tags_for_type/5` — the
  DUAL-SHAPE reader (authoring-excellence D19): legacy flat `content.tags`
  strings AND weighted entries' tag NAMES both come back clean, so an
  unregistered weighted vocabulary is drafted for curation too (the third
  consumer, benefiting transitively). Creates one draft `type:tag` doc per
  name that has no tag doc yet (draft or published). Never publishes —
  promotion is a human/curator decision.

  Returns `%{created: [name], skipped: [name]}`.
  """
  @spec seed_legacy_drafts(String.t(), keyword()) :: %{
          created: [String.t()],
          skipped: [String.t()]
        }
  def seed_legacy_drafts(dataset, opts \\ []) when is_binary(dataset) do
    legacy = legacy_distinct_tags(dataset, opts)
    existing = existing_tag_doc_names(legacy, dataset, opts)

    {to_create, skipped} = Enum.split_with(legacy, &(not MapSet.member?(existing, &1)))

    created =
      Enum.filter(to_create, fn name ->
        attrs = %{
          "doc_id" => name,
          "title" => name,
          "content" => %{
            "description" =>
              "Imported from the legacy flat tag vocabulary — review, then publish to register."
          }
        }

        # create_document ALWAYS births a draft (`drafts.<name>`, status
        # coerced) — the "never auto-published" property holds by construction.
        case Content.create_document(@tag_type, attrs, dataset, opts) do
          {:ok, _draft} ->
            true

          {:error, reason} ->
            Logger.warning(
              "TagRegistry.seed_legacy_drafts: skipping #{inspect(name)} — #{inspect(reason)}"
            )

            false
        end
      end)

    %{created: created, skipped: skipped}
  end

  # ── E3 internals ──────────────────────────────────────────────────────────

  # The distinct weighted tag names on a content map: members of a `tags` list
  # that are maps carrying a binary `"tag"`. Legacy flat strings (and any other
  # member shape) are NOT collected — shape validity is the label spine's gate,
  # registration of the weighted vocabulary is this one's.
  defp weighted_tag_names(content) when is_map(content) do
    content
    |> Map.get("tags")
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"tag" => name} when is_binary(name) and name != "" -> [name]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp weighted_tag_names(_), do: []

  # Registered = published tag rows whose doc_id is in `names`, read in the
  # workspace-or-shared-global scope (a workspace publish resolves its own tags
  # PLUS the shared nil-workspace base vocabulary — same semantics as the
  # Studio desk's schema catalog read).
  defp registered_subset(names, dataset, opts) do
    registered_tags_query(dataset, opts)
    |> where([d], d.doc_id in ^names)
    |> select([d], d.doc_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # Trgm-nearest registered tags to an unknown `name`, via the `%` operator so
  # the coarse net rides the PARTIAL GIN index `documents_doc_id_trgm_idx`
  # (migration 20260713130000; authoring-excellence D49/D50 — the D46 `%` +
  # `SET LOCAL` idiom, keyed on doc_id). `registered_tags_query/2` always carries
  # `type='tag' AND status='published'`, exactly the index's partial predicate —
  # keep both literals there or the planner silently drops the index.
  #
  # CLIFF: `@suggestion_floor` (0.1) is BELOW pg_trgm's 0.3 default. The `%`
  # operator reads its threshold from the `pg_trgm.similarity_threshold` GUC, so
  # WITHOUT the `SET LOCAL` below, `%` would silently tighten to 0.3 and drop
  # every 0.1–0.3 gray-zone near-match. `SET LOCAL` is transaction-scoped, so the
  # whole probe runs inside one explicit `Repo.transaction` with the SET FIRST.
  # The literal is interpolated (SET takes no bind params) but sourced from the
  # single `@suggestion_floor` attribute so the operator and the GUC can't drift.
  #
  # Fail-open: a DBConnection error (or any raise) inside the txn degrades to
  # "no suggestions" — an empty list — never a 500 on the publish-rejection path
  # (mirrors `DedupWall.fetch_candidates`).
  defp nearest_registered(name, dataset, opts) do
    query =
      registered_tags_query(dataset, opts)
      |> where([d], fragment("? % ?", d.doc_id, ^name))
      |> order_by([d],
        desc: fragment("similarity(?, ?)", d.doc_id, ^name),
        # doc_id tiebreak so equal-similarity candidates order deterministically.
        asc: d.doc_id
      )
      |> limit(@suggestion_limit)
      |> select([d], d.doc_id)

    Repo.transaction(fn ->
      Repo.query!("SET LOCAL pg_trgm.similarity_threshold = #{@suggestion_floor}")
      Repo.all(query)
    end)
    |> case do
      {:ok, results} -> results
      {:error, _reason} -> []
    end
  rescue
    e ->
      Logger.warning(
        "TagRegistry.nearest_registered fail-open: suggestion probe failed: #{inspect(e)}"
      )

      []
  end

  defp registered_tags_query(dataset, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    Document
    |> where([d], d.type == @tag_type and d.status == "published")
    |> where([d], d.dataset == ^dataset)
    # global-read: registered type:tag vocabulary is deliberately workspace-OR-global (charter D3 — global codelist tags are shared; the E3 publish gate must accept both), so the fail-open _including_global family is the intended read here.
    |> Scope.scope_to_workspace_including_global(workspace_id, project_id)
  end

  # ── legacy seed internals ─────────────────────────────────────────────────

  defp legacy_distinct_tags(dataset, opts) do
    dataset
    |> Content.list_schemas(opts)
    |> Enum.map(& &1.name)
    |> Enum.flat_map(fn type ->
      # Blank query = the full distinct vocabulary; the cap only guards a
      # pathological corpus.
      Content.search_tags_for_type("", type, dataset, opts, 10_000)
    end)
    |> Enum.uniq()
    # Dual-shape read (D19): weighted entries surface as their tag NAMES.
    # Belt-and-braces: a malformed tags array (an object element with no
    # `tag` key) would still surface as JSON-object text — never a name.
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "{"))
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.sort()
  end

  # Tag-doc names that already exist as EITHER variant (draft `drafts.<name>`
  # or published `<name>`) — the seed never overwrites curator work.
  defp existing_tag_doc_names([], _dataset, _opts), do: MapSet.new()

  defp existing_tag_doc_names(names, dataset, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    both_variants = names ++ Enum.map(names, &Content.draft_id/1)

    Document
    |> where([d], d.type == @tag_type and d.dataset == ^dataset)
    |> where([d], d.doc_id in ^both_variants)
    # global-read: registered type:tag vocabulary is deliberately workspace-OR-global (charter D3 — global codelist tags are shared; the E3 publish gate must accept both), so the fail-open _including_global family is the intended read here.
    |> Scope.scope_to_workspace_including_global(workspace_id, project_id)
    |> select([d], d.doc_id)
    |> Repo.all()
    |> Enum.map(&Content.published_id/1)
    |> MapSet.new()
  end
end
