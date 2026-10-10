defmodule Barkpark.Content.Validation do
  @moduledoc """
  Validates document content against schema field definitions.

  ## Two execution modes

  This module dispatches on `Barkpark.Content.SchemaDefinition.flat?/1`:

    * **`flat_mode` (legacy v1 path)** — preserves the original v1 validator
      verbatim: walks the top-level `fields` list, applies the per-field
      `"validation"` rule map (`required`, `min`, `max`, `pattern`). No
      recursion. Every existing seed schema (post, author, page, …) takes this
      path and round-trips byte-identically.

      `flat_mode` is the **permanent name** for this branch — it is NOT a
      deprecation gate. Migration of existing v1 schemas to v2 shape is a v2
      follow-up, not part of Phase 0.

    * **v2 path** — `flat?` returns false when the schema declares any
      `composite | arrayOf | codelist | localizedText` field OR a non-empty
      top-level `validations` slot. v2 mode parses the schema via
      `SchemaDefinition.parse/1` and recursively walks the resulting `%Field{}`
      tree. Errors carry a JSON-Pointer-ish path (`/contributors/2/role`) folded
      into the message; the top-level error envelope keying remains flat
      (`%{top_level_field => [msg_with_path, ...]}`) for v1-envelope callers.
      Path-aware error envelope v2 is Phase 3 — out of scope here.

  ## v1 rule shape (still honored on primitive leaves in both modes)

      "validation": {
        "required": true,
        "min": 3,
        "max": 100,
        "pattern": "^[a-z-]+$"
      }

  ## What this module deliberately does NOT do (Phase 0)

    * Codelist membership checks against the registry — shape-only here; the
      registry lookup belongs to the rendering layer (W2.4 typeahead) and the
      cross-field DSL (Phase 3).
    * `localizedText` `fallbackChain` enforcement — rendering concern (W2.4).
    * Top-level `validations: [...]` slot evaluation — the cross-field rule
      evaluator is Phase 3. The slot is reserved but inert in this phase;
      `validates_validations_slot_is_inert_in_phase_0` test guards that.

  ## The mutate-path mount — ADVISE by default, ENFORCE per dataset (task-41a740fd6701ec28)

  Until 2026-09-05 this module was never called on the HTTP mutate path: a
  create whose content violated its own schema's `required` rule answered 200
  and persisted. `Barkpark.Content.Writer.check_document_schema/3` now runs it
  at the write chokepoint for every create-family verb and the update/upsert
  path.

  The RULING (main, 2026-09-05, on task-41a740fd6701ec28's `disposition_reason`)
  is that the mount ships **ADVISE first**:

    * **ADVISE (the default, every dataset)** — findings ride the mutate SUCCESS
      envelope as `warnings` (`Barkpark.Content.Warnings`, charter D5) under the
      code `schema_validation`, one entry per offending field naming the field
      and the rule it broke. The write LANDS. Status and stored bytes are
      byte-identical to the pre-mount behaviour.
    * **ENFORCE (opt-in, per dataset)** — the write is refused
      `{:error, {:schema_validation_failed, errors}}` → 422 `validation_failed`
      with the per-field errors in `details`, matching the `unknown_fields`
      shape already on that door. Nothing is written.

  Flipping the DEFAULT to enforce is the owner's call, not a builder's.

  ### The flag

      config :barkpark, Barkpark.Content.Validation,
        enforce_datasets: ["production"]   # or :all

  Defaults to `[]` — no dataset enforces. `runtime.exs` maps
  `BARKPARK_SCHEMA_ENFORCE_DATASETS` (comma-separated slugs, or `all`) over it,
  so an operator opts a dataset in without a deploy of new code. There is NO
  migration and no new column: the flag is deployment configuration, not
  content, and a dataset that never appears in the list behaves exactly as it
  did before this mount existed.

  ### Migration story for rows already stored in violation

  Documents written before this mount stay exactly as they are — nothing is
  rewritten, nothing is deleted, no backfill runs. The mount is a WRITE-time
  check only; a loose row is never re-validated at rest or on read.

  The path from here, in order:

    1. **Report-only period (now, every dataset).** Loose writes land with a
       `schema_validation` warning. Operators harvest the warning codes from
       mutate responses to size their own corpus — the advisory names the type,
       the document id, the field and the rule, which is exactly the input a
       clean-up needs.
    2. **Per-dataset opt-in.** When a dataset's warning stream goes quiet, its
       owner adds the slug to `enforce_datasets`. From that moment new and
       edited documents in that dataset must satisfy their schema; rows never
       touched again are still untouched.
    3. **A grandfathered row is edited.** Under ENFORCE its next write is
       refused 422 naming the field — the caller fixes the field or the dataset
       owner removes the slug from the list. This is a consequence the owner
       opts into per dataset, not one that arrives with an upgrade.

  Flipping the default to `:all` is a separate, announced decision with its own
  row.

  ## Stable finding codes (task-a842b831fd6285d7)

  Every finding this module can produce also carries a `code` (an atom from
  `@known_codes`, below) and a `params` map of whatever varies in that
  finding's wording (a `min`/`max` bound, a language key, an allowed-values
  list, …) — purely ADDITIVE: `validate/3`, `check/3` and `check_tree/3` are
  byte-identical to before, still returning the generated English sentence
  and nothing else. `check_findings/3` is the new door: the SAME walk, as a
  flat list of `%{path:, message:, code:, params:}` maps, for a caller that
  wants to render its own sentence per code (Studio's gettext pass) instead
  of trusting the English text.

  The code is assigned to the UNDERLYING check that fired, before a
  schema-authored `"message"` override (if any) replaces the wording — an
  override collapses the fired check(s) into ONE finding under the code
  `:custom`, the same way it already collapses them into one sentence.
  """

  require Logger

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Content.SchemaDefinition.{Field, Parsed}

  @typedoc "One finding, ready for a caller that renders its own sentence per code."
  @type finding :: %{path: String.t(), message: String.t(), code: atom(), params: map()}

  # The closed set a `check_findings/3` caller (and this module's own census
  # test) can rely on — every finding this module can ever emit carries one
  # of these, never a surprise atom. `:custom` is the schema-author-override
  # escape hatch (a `"message"` rule key collapses the fired check(s) into
  # one finding under this code, since no single generated-check code would
  # honestly describe caller-written text).
  @known_codes ~w(
    required pattern_mismatch expected_object expected_list
    codelist_not_string codelist_empty codelist_has_whitespace
    localized_text_shape language_key_not_string language_not_declared
    rich_text_shape text_not_string image_shape file_shape
    rect_shape rect_out_of_range missing_type unknown_type
    block_fields_invalid not_in_list list_too_short list_too_long
    list_not_unique number_too_small number_too_large
    string_too_short string_too_long portable_text_not_portabledoc custom
    cross_validation
  )a

  @doc "The fixed set of codes `check_findings/3` can ever emit. See the moduledoc."
  @spec known_codes() :: [atom()]
  def known_codes, do: @known_codes

  @doc """
  Validate content map against a schema's fields. Returns {:ok, content} or
  {:error, errors}. Only ERROR-level rules can produce an error — a rule map
  (or list entry) carrying `"level": "warning"` never reaches this verdict; read
  those through `check/3`.
  """
  def validate(content, title, schema) do
    case run(content, title, schema, :error) do
      errors when errors == %{} -> {:ok, content}
      errors -> {:error, errors}
    end
  end

  @doc """
  Both verdicts at once — Sanity's error/warning validation levels (Gyldendal
  parity E1.6, task-cd8e10ca44ccb932 criterion 3).

  A field's `"validation"` is a rule MAP or a LIST of rule maps. Each map
  carries the v1 checks (`required`, `min`, `max`, `pattern`) plus, optionally:

    * `"level": "warning"` — the map's findings are WARNINGS: surfaced
      inline and in the publish bar, never blocking a save or a publish.
      Absent or anything else means `error`, byte-identical to before.
    * `"message": "…"` — replaces the generated wording of every finding the
      map produces (Sanity's `.warning("…")` / `.error("…")` argument).
    * `"unique": true` — on an array: two items that point at the same document
      (by `_ref`) or hold the same value (a row's `_key` aside) are one finding,
      «Items must be unique» unless `"message"` says otherwise (Sanity's
      `Rule.unique()`).

  Sanity's `shortDescription` → `{"max": 200, "level": "warning", "message":
  "Over 200 tegn blir klippet på kortet."}`; a required field that also warns
  past a length → `[{"required": true}, {"max": 200, "level": "warning"}]`.

  Returns `%{errors: %{field => [msg]}, warnings: %{field => [msg]}}`. The
  `errors` half is exactly what `validate/3` reports.
  """
  @spec check(map() | nil, String.t() | nil, map() | nil) :: %{
          errors: map(),
          warnings: map()
        }
  def check(content, title, schema) do
    %{
      errors: run(content, title, schema, :error),
      warnings: run(content, title, schema, :warning)
    }
  end

  @doc """
  The same walk as `check/3`, read as a TREE (Gyldendal parity E1.11,
  task-34ea5ee00dfb7a99): keyed by top-level field, then by subfield name or
  row index, with `:__self__` for a node's own findings — the shape the
  composite and array components index by, so a rule on `seo.description` or
  `banners[1].title` renders under THAT input instead of as a JSON-pointer
  under the top-level field.

      %{"seo" => %{"description" => ["Beskrivelsen bør være under 300 tegn."]},
        "banners" => %{1 => %{"title" => ["Required"]}, __self__: ["Maks 3 kort tillatt."]},
        "title" => ["Required"]}

  A top-level leaf is a plain list, byte-identical to `check/3`. A flat
  (legacy) schema answers exactly `check/3`. The wire shape of `validate/3`
  and `check/3` is untouched — the API's 422 `details` and the advisories keep
  the flat `%{field => ["/path: msg"]}` keying.
  """
  @spec check_tree(map() | nil, String.t() | nil, map() | nil) :: %{
          errors: map(),
          warnings: map()
        }
  def check_tree(content, title, schema) do
    %{
      errors: run_tree(content, title, schema, :error),
      warnings: run_tree(content, title, schema, :warning)
    }
  end

  @doc """
  Every finding this module can produce, as a FLAT list of `finding()` maps —
  `%{path:, message:, code:, params:}` — instead of the field-keyed string
  tree `check/3` answers. Same walk, same generated English `message`
  (byte-identical to `check/3`'s), with `code` + `params` riding alongside
  for a caller that renders its own sentence per code (task-a842b831fd6285d7).

  `code` is always one of `known_codes/0`; `:custom` is what a
  schema-authored `"message"` rule key collapses to (see the moduledoc).
  """
  @spec check_findings(map() | nil, String.t() | nil, map() | nil) :: %{
          errors: [finding()],
          warnings: [finding()]
        }
  def check_findings(content, title, schema) do
    %{
      errors: run_findings(content, title, schema, :error),
      warnings: run_findings(content, title, schema, :warning)
    }
  end

  @doc """
  The schema's `cross_validations` (task-9754deb160e95a80), as findings split
  by level: `%{errors: [finding()], warnings: [finding()]}` with code
  `:cross_validation`. They are built from `CrossValidator.violations/2`, the
  list the Studio banner renders, so the write door and the banner always
  agree. A rule that cannot be evaluated (malformed, unknown operator, a
  field the schema does not declare) yields no finding and a log line: it
  never fails a write. Warning-level rules are warnings, so they never
  refuse, even on an enforcing dataset.

  Kept out of `check/3` and `check_findings/3`: the Studio shows these rules
  in its banner, not under a field, so folding them in would show each twice.
  """
  @spec cross_findings(map() | nil, String.t() | nil, map() | nil) :: %{
          errors: [finding()],
          warnings: [finding()]
        }
  def cross_findings(content, title, schema) do
    case Barkpark.Content.CrossValidator.partition(schema) do
      {[], []} ->
        %{errors: [], warnings: []}

      {_ok, bad} ->
        Enum.each(bad, fn {rule, reason} ->
          name = if is_map(rule), do: rule["name"] || rule[:name], else: nil

          Logger.warning(
            "[Validation] cross_validation #{inspect(name)} on schema " <>
              "#{inspect(schema_name(schema))} cannot be evaluated (#{reason}); no finding"
          )
        end)

        doc = Map.put_new(content || %{}, "title", title)
        Barkpark.Content.CrossValidator.findings(schema, doc)
    end
  end

  defp schema_name(%{name: n}), do: n
  defp schema_name(%{"name" => n}), do: n
  defp schema_name(_), do: nil

  @doc """
  Every finding in a `check_tree/3` half (or a flat `check/3` half), counted —
  the publish bar's number.
  """
  @spec leaf_count(map() | list() | nil) :: non_neg_integer()
  def leaf_count(list) when is_list(list), do: length(list)

  def leaf_count(map) when is_map(map),
    do: map |> Map.values() |> Enum.map(&leaf_count/1) |> Enum.sum()

  def leaf_count(_), do: 0

  defp run_tree(content, title, schema, level) do
    schema = schema_map(schema)

    if flat_mode?(schema) do
      run(content, title, schema, level)
    else
      case SchemaDefinition.parse(schema) do
        {:ok, %Parsed{fields: fields}} ->
          Enum.reduce(fields, %{}, fn %Field{} = field, acc ->
            value =
              if field.name == "title", do: title, else: fetch_field(content || %{}, field.name)

            top_path = "/" <> (field.name || "")

            case walk_field(field, value, top_path, level) do
              [] ->
                acc

              quads ->
                Enum.reduce(quads, acc, fn {path, msg, _code, _params}, acc ->
                  segments = tree_segments(top_path, path)
                  Map.put(acc, field.name, put_finding(Map.get(acc, field.name), segments, msg))
                end)
            end
          end)

        {:error, _} ->
          # Same fallback `validate_v2/4` takes (and logs) — flat verdicts.
          run(content, title, schema, level)
      end
    end
  end

  # "/banners/1/title" under "/banners" → [1, "title"]; the top path itself → [].
  defp tree_segments(top_path, path) do
    path
    |> String.replace_prefix(top_path, "")
    |> String.split("/", trim: true)
    |> Enum.map(fn seg ->
      case Integer.parse(seg) do
        {i, ""} -> i
        _ -> seg
      end
    end)
  end

  defp put_finding(nil, [], msg), do: [msg]
  defp put_finding(list, [], msg) when is_list(list), do: list ++ [msg]

  defp put_finding(map, [], msg) when is_map(map),
    do: Map.update(map, :__self__, [msg], &(&1 ++ [msg]))

  defp put_finding(node, [seg | rest], msg) do
    map =
      case node do
        nil -> %{}
        list when is_list(list) -> %{__self__: list}
        map when is_map(map) -> map
      end

    Map.put(map, seg, put_finding(Map.get(map, seg), rest, msg))
  end

  # One pass of the (flat or v2) walker at ONE level. The walkers below take
  # the level and read only the rule maps declared at it, so a warning-level
  # `required` warns and an error-level `required` blocks, from the same
  # field, in two independent passes.
  defp run(content, title, schema, level) do
    schema = schema_map(schema)

    result =
      if flat_mode?(schema) do
        validate_flat(content, title, schema, level)
      else
        validate_v2(content, title, schema, level)
      end

    case result do
      {:ok, _} -> %{}
      {:error, errors} -> errors
    end
  end

  # `check_findings/3`'s own pass — mirrors `run/4` exactly, but flattens to
  # `finding()` maps instead of collapsing into the field-keyed string tree.
  defp run_findings(content, title, schema, level) do
    schema = schema_map(schema)

    if flat_mode?(schema) do
      flat_findings(content, title, schema, level)
    else
      case SchemaDefinition.parse(schema) do
        {:ok, %Parsed{fields: fields}} ->
          Enum.flat_map(fields, fn %Field{} = field ->
            value =
              if field.name == "title", do: title, else: fetch_field(content || %{}, field.name)

            top_path = "/" <> (field.name || "")

            field
            |> walk_field(value, top_path, level)
            |> Enum.map(fn {path, msg, code, params} ->
              %{path: path, message: format_msg(top_path, path, msg), code: code, params: params}
            end)
          end)

        {:error, _} ->
          flat_findings(content, title, schema, level)
      end
    end
  end

  defp flat_findings(content, title, schema, level) do
    schema
    |> schema_fields()
    |> Enum.flat_map(fn field ->
      field_name = get_in_field(field, "name")
      rules = rules_at(get_in_field(field, "validation"), level)
      value = if field_name == "title", do: title, else: Map.get(content || %{}, field_name)
      top_path = "/" <> to_string(field_name)

      own =
        value
        |> validate_field(rules, field)
        |> Enum.map(fn {msg, code, params} ->
          %{path: top_path, message: msg, code: code, params: params}
        end)

      # task-2d96f71d3fe52ee7 — see `flat_portable_text_messages/3`'s
      # comment above `validate_flat/4`: same check, this path's finding
      # shape (`check_findings/3` wants code + params, not just a message).
      pt =
        if get_in_field(field, "type") == "richText" do
          value
          |> richtext_blocks()
          |> portable_text_findings(top_path, level)
          |> Enum.map(fn {path, msg, code, params} ->
            %{path: path, message: msg, code: code, params: params}
          end)
        else
          []
        end

      own ++ pt
    end)
  end

  @doc """
  The rule map for `level` (`:error` | `:warning`) out of a field's raw
  `"validation"` value. A single map belongs to its own level (default
  `:error`); a list is split by each entry's level and the entries at the
  requested level are merged (a later entry's key wins). Anything else is `%{}`.
  """
  @spec rules_at(any(), :error | :warning) :: map()
  def rules_at(rules, level) when is_map(rules) do
    if rule_level(rules) == level, do: rules, else: %{}
  end

  def rules_at(rules, level) when is_list(rules) do
    rules
    |> Enum.filter(&(is_map(&1) and rule_level(&1) == level))
    |> Enum.reduce(%{}, &Map.merge(&2, stringify_keys(&1)))
  end

  def rules_at(_, _), do: %{}

  # Sanity's third level, `info`, never blocks: it is surfaced with the warnings
  # (task-b183e15684138399). Before, anything not "warning" read as an error.
  defp rule_level(%{} = rules) do
    case Map.get(rules, "level") || Map.get(rules, :level) do
      l when l in ["warning", "warn", "info", :warning, :warn, :info] -> :warning
      _ -> :error
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # A `{message, code, params}` triple — the internal currency every check
  # below builds, BEFORE a path is known (`pair/2` adds it) and before a
  # schema-authored `"message"` override, if any, replaces the wording
  # (`apply_message/2`).
  defp f(message, code, params \\ %{}), do: {message, code, params}

  # Promotes a `{message, code, params}` triple to a path-qualified finding
  # `{path, message, code, params}` — the shape `walk_field/4` and
  # `validate_field/3`'s callers pass around.
  defp pair(path, {message, code, params}), do: {path, message, code, params}

  # `"message"` on a rule map replaces every generated finding the map produced
  # with that one sentence (one finding, not one per check — Sanity's chain
  # argument names the field's problem, not each predicate). The replacement
  # finding's code is `:custom` — no single generated-check code would
  # honestly describe caller-written text, and an override can collapse
  # SEVERAL different checks (required + min + pattern) into one sentence.
  defp apply_message([], _rules), do: []

  defp apply_message(findings, rules) when is_list(findings) do
    case Map.get(rules, "message") || Map.get(rules, :message) do
      m when is_binary(m) and m != "" -> [f(m, :custom)]
      _ -> findings
    end
  end

  @doc """
  Whether `dataset` has OPTED IN to enforcement (422) rather than the default
  advisory (`warnings` in the success envelope). See the moduledoc.

  Reads `config :barkpark, Barkpark.Content.Validation, enforce_datasets: …`,
  which accepts a list of dataset slugs or the atom `:all`. Absent, malformed
  or empty configuration means ADVISE — the flag fails OPEN by construction,
  because ADVISE is the pre-existing behaviour and a config typo must not
  silently start 422ing a publisher's writes.
  """
  @spec enforce?(String.t() | nil) :: boolean()
  def enforce?(dataset) do
    case Application.get_env(:barkpark, __MODULE__, [])[:enforce_datasets] do
      :all -> true
      list when is_list(list) and is_binary(dataset) -> dataset in list
      _ -> false
    end
  end

  # A stored `%SchemaDefinition{}` (what `Content.get_schema/2` and the
  # Studio's `editor_schema` carry) is read as the plain map the parser
  # expects. Before this (Gyldendal parity E1.11) the struct reached
  # `SchemaDefinition.parse/1`, which raised on its Ecto metadata, and the
  # `rescue` in `flat_mode?/1` answered TRUE — so every v2 schema was
  # validated FLAT from the Studio and the API door, and no rule inside a
  # composite or an arrayOf row ever ran there.
  defp schema_map(%SchemaDefinition{} = schema) do
    %{
      "name" => schema.name,
      "kind" => schema.kind,
      "fields" => schema.fields || [],
      "validations" => Map.get(schema, :validations) || []
    }
  end

  defp schema_map(schema), do: schema

  # ── flat_mode dispatch ────────────────────────────────────────────────────

  defp flat_mode?(nil), do: true

  defp flat_mode?(schema) do
    SchemaDefinition.flat?(schema)
  rescue
    _ -> true
  end

  # ── flat_mode (legacy v1 — DO NOT TIGHTEN BEHAVIOUR) ──────────────────────

  defp validate_flat(content, title, schema, level) do
    fields = schema_fields(schema)

    errors =
      fields
      |> Enum.reduce(%{}, fn field, acc ->
        field_name = get_in_field(field, "name")
        rules = rules_at(get_in_field(field, "validation"), level)

        # Title field is stored at top level, not in content
        value = if field_name == "title", do: title, else: Map.get(content || %{}, field_name)

        field_errors =
          value
          |> validate_field(rules, field)
          |> Enum.map(fn {msg, _code, _params} -> msg end)
          |> Kernel.++(flat_portable_text_messages(field, value, level))

        if field_errors == [] do
          acc
        else
          Map.put(acc, field_name, field_errors)
        end
      end)

    if errors == %{} do
      {:ok, content}
    else
      {:error, errors}
    end
  end

  # task-2d96f71d3fe52ee7 — a PLAIN richText field (no custom `blocks.of`
  # vocabulary) is classified `flat_mode?` (`SchemaDefinition.v2_shape?/1`
  # only flags richText when it declares custom object blocks), so
  # `walk_field/4`'s richText clause — where the SAME Portable Text check
  # also lives, for a v2-shaped richText field — never runs for it. Checked
  # here too, independent of the flat/v2 split, rather than widening
  # `v2_shape?/1` to cover every richText field: that would flip every
  # SCHEMA holding one (not just the richText field itself — `flat_mode?`
  # is whole-schema) onto the heavier v2 walker for every OTHER field in it
  # too, a much wider behavior change than this task asks for.
  defp flat_portable_text_messages(field, value, level) do
    if get_in_field(field, "type") == "richText" do
      value
      |> richtext_blocks()
      |> Enum.filter(&portable_text_block?/1)
      |> Enum.map(fn _ ->
        "Sanity Portable Text block (_type/children/markDefs), not a PortableDoc block"
      end)
      |> then(&shape(level, &1))
    else
      []
    end
  end

  defp schema_fields(nil), do: []

  defp schema_fields(schema) when is_map(schema) do
    Map.get(schema, :fields) || Map.get(schema, "fields") || []
  end

  # The v1 `String.to_atom` on a schema-declared field key — waived INLINE so
  # the waiver binds by AST adjacency and survives line moves; the baseline
  # row it replaces (`validation.ex:286`) went stale the first time a function
  # was added above it (E1.11).
  # sobelow_skip ["DOS.StringToAtom"]
  defp get_in_field(field, key) when is_map(field) do
    Map.get(field, key) || Map.get(field, String.to_atom(key))
  end

  defp get_in_field(_, _), do: nil

  # ── v2 path (recursive) ───────────────────────────────────────────────────

  defp validate_v2(content, title, schema, level) do
    case SchemaDefinition.parse(schema) do
      {:ok, %Parsed{} = parsed} ->
        validate_parsed(content, title, parsed, level)

      {:error, reason} ->
        # Defensive fallback — if a schema fails to parse for some reason,
        # behave like the legacy validator rather than blowing up callers.
        # This SILENTLY disables all composite/arrayOf/localizedText checks, so
        # make it observable: a v2-shaped schema that reaches here is a bug in
        # the schema (or the parser), not a normal code path.
        Logger.warning(
          "Validation: v2 schema failed to parse (#{inspect(reason)}); " <>
            "falling back to flat_mode — composite/arrayOf/localizedText checks are DISABLED"
        )

        validate_flat(content, title, schema, level)
    end
  end

  defp validate_parsed(content, title, %Parsed{fields: fields}, level) do
    errors_by_top =
      Enum.reduce(fields, %{}, fn %Field{} = field, acc ->
        value =
          if field.name == "title" do
            title
          else
            fetch_field(content || %{}, field.name)
          end

        top_path = "/" <> (field.name || "")
        quads = walk_field(field, value, top_path, level)

        case quads do
          [] ->
            acc

          list ->
            msgs = Enum.map(list, fn {p, m, _code, _params} -> format_msg(top_path, p, m) end)
            Map.update(acc, field.name, msgs, &(&1 ++ msgs))
        end
      end)

    if errors_by_top == %{} do
      {:ok, content}
    else
      {:error, errors_by_top}
    end
  end

  defp format_msg(top_path, path, msg) when top_path == path, do: msg
  defp format_msg(_top_path, path, msg), do: "#{path}: #{msg}"

  # walk_field returns [{path :: String.t(), msg :: String.t(), code :: atom(), params :: map()}]

  # composite — recurse into named subfields
  defp walk_field(%Field{type: "composite", fields: kids} = f, value, path, level) do
    rules = field_rules(f, level)

    cond do
      blank?(value) and required?(rules) ->
        Enum.map(apply_message([f("Required", :required)], rules), &pair(path, &1))

      is_nil(value) ->
        []

      not is_map(value) ->
        shape(level, [{path, "expected an object", :expected_object, %{}}])

      true ->
        Enum.flat_map(kids || [], fn %Field{} = child ->
          child_value = fetch_field(value, child.name)

          walk_field(child, child_value, path <> "/" <> (child.name || ""), level)
        end)
    end
  end

  # arrayOf — iterate elements with index-prefixed paths. `of_types`
  # (task-b3ebbd3ab1575e2a: several NAMED member types, mutually exclusive
  # with `of` — SchemaDefinition sets exactly one) discriminates each item by
  # its own `"_type"` key instead of walking every item against one shape.
  defp walk_field(%Field{type: "arrayOf", of: of, of_types: of_types} = f, value, path, level) do
    rules = field_rules(f, level)
    typed? = is_map(of_types) and map_size(of_types) > 0

    cond do
      blank?(value) and required?(rules) ->
        Enum.map(apply_message([f("Required", :required)], rules), &pair(path, &1))

      is_nil(value) ->
        []

      not is_list(value) ->
        shape(level, [{path, "expected a list", :expected_list, %{}}])

      is_nil(of) and not typed? ->
        # Schema lacks an `of`/`of_types` shape descriptor — defer to v2
        # schema parser (which would reject), so this is a defensive no-op.
        []

      true ->
        # The array's OWN length rule (Sanity's `Rule.max(3)` on an array —
        # Gyldendal parity E1.11: «Maks 3 kort tillatt.»), then every row.
        own =
          Enum.map(apply_message(check_list_bounds(value, rules), rules), &pair(path, &1))

        rows =
          value
          |> Enum.with_index()
          |> Enum.flat_map(fn {item, idx} ->
            item_path = path <> "/" <> Integer.to_string(idx)

            if typed? do
              walk_typed_array_item(of_types, item, item_path, level)
            else
              walk_field(of, item, item_path, level)
            end
          end)

        own ++ rows
    end
  end

  # codelist — shape only (string, non-empty, no whitespace). Membership
  # checks against the registry are deferred to the rendering layer (W2.4).
  defp walk_field(%Field{type: "codelist"} = f, value, path, level) do
    rules = field_rules(f, level)

    cond do
      blank?(value) and required?(rules) ->
        Enum.map(apply_message([f("Required", :required)], rules), &pair(path, &1))

      is_nil(value) ->
        []

      not is_binary(value) ->
        shape(level, [{path, "codelist value must be a string", :codelist_not_string, %{}}])

      value == "" ->
        shape(level, [{path, "codelist value cannot be empty", :codelist_empty, %{}}])

      Regex.match?(~r/\s/, value) ->
        shape(level, [
          {path, "codelist value cannot contain whitespace", :codelist_has_whitespace, %{}}
        ])

      true ->
        []
    end
  end

  # localizedText — shape, then the field's own rules (task-63ce1db795a67a04).
  # `pattern`/`min`/`max` apply to EVERY locale's text uniformly, each finding
  # at `/field/<lang>`; `required` means at least one locale holds text, so a
  # `%{}` or all-blank map is reported once at `/field`. No locale is required
  # on its own: fallbackChain enforcement is rendering's concern (W2.4), and
  # the validator does NOT raise on a missing primary translation.
  defp walk_field(
         %Field{type: "localizedText", languages: langs, format: fmt} = f,
         value,
         path,
         level
       ) do
    rules = field_rules(f, level)

    cond do
      (blank?(value) or (is_map(value) and not localized_filled?(value))) and required?(rules) ->
        Enum.map(apply_message([f("Required", :required)], rules), &pair(path, &1))

      is_nil(value) ->
        []

      not is_map(value) ->
        shape(level, [
          {path, "localizedText must be a map of language → text", :localized_text_shape, %{}}
        ])

      true ->
        shape(level, localized_shape_findings(value, langs, fmt, path)) ++
          localized_rule_findings(value, rules, f.raw || %{}, path)
    end
  end

  # image with declared subfields or `options.hotspot` (task-f0f51946d2de672d).
  # The value is a URL string (legacy) or an object: `asset: {_ref}` (or the
  # older `url`/`assetId`), optional `hotspot` {x,y,height,width} and `crop`
  # {top,bottom,left,right}, each a number from 0 to 1, plus the declared
  # subfields (`alt`, …) as siblings, walked like a composite's. A URL string
  # has no subfields, so a required `alt` is reported on it. An image with
  # neither declaration stays the leaf below, byte for byte.
  defp walk_field(%Field{type: "image"} = f, value, path, level) do
    if structured_image?(f),
      do: walk_image(f, value, path, level),
      else: walk_leaf(f, value, path, level)
  end

  # file (task-681df8da723386b8) — same split as image above: a leaf unless
  # it declares subfields. No image-only concept (hotspot/crop) applies, so
  # walk_file/4 is the same cond minus the rect validation, with wording that
  # says "file" instead of "image".
  defp walk_field(%Field{type: "file"} = f, value, path, level) do
    if structured_file?(f),
      do: walk_file(f, value, path, level),
      else: walk_leaf(f, value, path, level)
  end

  # richText whose block vocabulary declares custom object blocks
  # (task-152cacba913a4724): every block of such a type has its declared
  # fields checked. Other blocks, and the field's own rules, are unchanged.
  #
  # task-839f9bebf5628c03 — `level` rides all the way into each block's own
  # field walk now, instead of a blanket `shape(level, &1)` around the whole
  # block. The blanket gate used to pass `:error` to the CHILD walk no matter
  # what `level` this call was made with, then discard the (ALWAYS
  # error-shaped) result entirely whenever `level` wasn't `:error` — so a
  # block field's OWN `"level": "warning"` rule could never surface on
  # EITHER pass: not on the error run (its rule isn't error-level, so nothing
  # was found under `:error`), and not on the warning run (the gate discarded
  # the block's findings outright). Threading `level` through makes a block
  # field obey its own declared level exactly like an ordinary composite
  # subfield already does (see the "composite" clause above, which passes
  # `level` the same way with no gate at all).
  defp walk_field(%Field{type: "richText", raw: raw} = f, value, path, level) do
    # task-2d96f71d3fe52ee7 — a Sanity Portable Text array stores silently
    # and renders broken in Studio (PortableDoc blocks only). Scanned
    # unconditionally, before the object-block-vocabulary branch below:
    # a PT block is never a declared custom object block (PT's own `_type`
    # vocabulary — "block", "image", … — has no relation to this field's
    # `blocks.of` names), so it would otherwise fall through BOTH arms'
    # `_ -> []` catch-alls and find nothing, in either case.
    pt_findings = portable_text_findings(richtext_blocks(value), path, level)

    case object_block_types(raw) do
      objects when map_size(objects) == 0 ->
        walk_leaf(f, value, path, level) ++ pt_findings

      objects ->
        blocks = richtext_blocks(value)

        walk_leaf(f, value, path, level) ++
          pt_findings ++
          (blocks
           |> Enum.with_index()
           |> Enum.flat_map(fn
             {%{"type" => t} = block, idx} when is_map_key(objects, t) ->
               object_block_findings(Map.fetch!(objects, t), block, "#{path}/#{idx}", level)

             _ ->
               []
           end))
    end
  end

  # primitive leaf — apply v1-style rules from raw["validation"]
  defp walk_field(%Field{} = f, value, path, level), do: walk_leaf(f, value, path, level)

  # A richText field's block array, found whichever of its two LIVE shapes
  # `value` is holding (task-839f9bebf5628c03 — found live: barkpark-studio's
  # PATCH on a published post, through the real "editor":"blocks" write
  # path, produced zero findings for an out-of-vocabulary block because this
  # was `if is_list(value), do: value, else: []` — a bare list ONLY). Kept
  # OUT of the `walk_field/4` clause group above, same reason
  # `walk_typed_array_item/4` below is kept out of it: so those clauses stay
  # contiguous.
  #
  #   * a bare list — what every pre-existing test here constructs by hand,
  #     and what a direct API write (set the field to an array) stores.
  #   * `%{"blocks" => [...], "html" => ...}` — what the Studio block-editor
  #     ACTUALLY stores once a field has gone through
  #     `Papers.BlockOps.apply_field_block_ops/6`
  #     (`Projection.project_body/2`'s output shape), and what a `patch` that
  #     `set`s the field to that same shape stores verbatim since a generic
  #     "set" patch has no field-specific unwrapping.
  #
  # Deliberately NOT `Papers.BlockOps.field_blocks/1`: that function ALSO
  # turns a plain string into one synthesized paragraph block, a v1-legacy
  # convenience that belongs to the write path, not to validation reading
  # back whatever is already stored — a string value here falls through to
  # `[]`, unchanged from before this fix (validation never fabricates a
  # block to check).
  defp richtext_blocks(list) when is_list(list), do: list
  defp richtext_blocks(%{"blocks" => list}) when is_list(list), do: list
  defp richtext_blocks(_), do: []

  # task-2d96f71d3fe52ee7 — one finding per Portable Text block, so a field
  # holding a MIX (a partial migration) names every offending block, not
  # just the first. `shape/2` is the same error/warning gate every other
  # structural finding in this walker uses.
  defp portable_text_findings(blocks, path, level) do
    blocks
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, idx} ->
      if portable_text_block?(block) do
        shape(level, [
          {"#{path}/#{idx}",
           "Sanity Portable Text block (_type/children/markDefs), not a PortableDoc block",
           :portable_text_not_portabledoc, %{index: idx}}
        ])
      else
        []
      end
    end)
  end

  # Sanity's Portable Text block shape: `_type: "block"` plus at least one of
  # its other signature keys (`children`, `markDefs`, `listItem`) — never all
  # three required, since a minimal/empty PT block can lack `markDefs` or
  # `listItem`. PortableDoc's OWN block convention keys on `"type"` (no
  # underscore; see `walk_field/4`'s object-block-vocabulary clause above),
  # so a genuine PortableDoc block never has a `"_type"` key at all — no
  # overlap, no false positive on an ordinary block this field's own
  # vocabulary declares.
  defp portable_text_block?(%{"_type" => "block"} = block) do
    Map.has_key?(block, "children") or Map.has_key?(block, "markDefs") or
      Map.has_key?(block, "listItem")
  end

  defp portable_text_block?(_), do: false

  # One item of a several-named-member-types `arrayOf` (task-b3ebbd3ab1575e2a) —
  # the typed branch of the "arrayOf" `walk_field/4` clause above, kept out of
  # that clause group so the `walk_field/4` clauses themselves stay contiguous.
  # Sanity's own object-array convention: the item names its member type with
  # a `"_type"` key, looked up against the schema's declared member names.
  defp walk_typed_array_item(_of_types, item, path, level) when not is_map(item),
    do: shape(level, [{path, "expected an object", :expected_object, %{}}])

  defp walk_typed_array_item(of_types, item, path, level) do
    case Map.get(item, "_type") do
      type_name when is_binary(type_name) and type_name != "" ->
        case Map.get(of_types, type_name) do
          %Field{} = member_shape ->
            walk_field(member_shape, item, path, level)

          nil ->
            shape(level, [
              {path, "unknown _type #{inspect(type_name)}", :unknown_type,
               %{type_name: type_name}}
            ])
        end

      _ ->
        shape(level, [{path, "missing _type", :missing_type, %{}}])
    end
  end

  defp walk_leaf(%Field{} = f, value, path, level) do
    rules = field_rules(f, level)
    findings = validate_field(value, rules, f.raw || %{})
    findings = apply_message(findings ++ check_numeric_bounds(value, rules), rules)
    Enum.map(findings, &pair(path, &1))
  end

  @doc """
  The custom object blocks a richText field's vocabulary declares, as
  `%{name => fields}`: the `{name, fields}` entries of `blocks.of`
  (task-152cacba913a4724). String entries are built-in block types and are
  not listed.
  """
  @spec object_block_types(map() | nil) :: %{String.t() => [map()]}
  def object_block_types(%{"blocks" => %{"of" => of}}) when is_list(of) do
    for %{"name" => name} = entry <- of, is_binary(name), into: %{} do
      {name, Enum.filter(List.wrap(entry["fields"]), &is_map/1)}
    end
  end

  def object_block_types(_), do: %{}

  @doc """
  Findings for ONE custom object block against its declared `fields`, as
  `[{path, message, code, params}]`. Each field is walked like a composite's
  subfield (so `validation` rules and nested shapes apply, AT THE GIVEN
  `level` — task-839f9bebf5628c03), and a string value must be in the
  field's `options.list` when one is declared (Sanity's list shape: strings
  or `{title, value}`). The not-in-list check carries no `"level"` of its
  own (it is driven by `options.list`, not a `validation` rule), so it stays
  an ERROR-level-only finding regardless of `level` — unchanged from before
  this function took a level at all, and exactly how `Content.Validation`'s
  moduledoc already describes `options.list` elsewhere.

  `level` defaults to `:error` for `FieldVocabulary.validate/2` (the
  block-op write path), which only ever wants the hard refusal shape and
  never called this with a level before.
  """
  @spec object_block_findings([map()], map(), String.t(), atom()) :: [
          {String.t(), String.t(), atom(), map()}
        ]
  def object_block_findings(fields, block, path, level \\ :error)
      when is_list(fields) and is_map(block) do
    case SchemaDefinition.parse(%{"name" => "block", "fields" => fields}) do
      {:ok, parsed} ->
        Enum.flat_map(parsed.fields, fn %Field{} = child ->
          value = fetch_field(block, child.name)
          child_path = path <> "/" <> (child.name || "")

          walk_field(child, value, child_path, level) ++
            shape(level, list_option_findings(child, value, child_path))
        end)

      {:error, reason} ->
        shape(level, [
          {path, "the block's declared fields do not parse: #{inspect(reason)}",
           :block_fields_invalid, %{reason: inspect(reason)}}
        ])
    end
  end

  defp list_option_findings(%Field{raw: %{"options" => %{"list" => list}}}, value, path)
       when is_list(list) and is_binary(value) do
    allowed =
      Enum.map(list, fn
        %{"value" => v} -> v
        v -> v
      end)

    if value in allowed,
      do: [],
      else: [
        {path, "must be one of #{Enum.map_join(allowed, ", ", &to_string/1)}", :not_in_list,
         %{allowed: allowed}}
      ]
  end

  defp list_option_findings(_field, _value, _path), do: []

  defp structured_image?(%Field{fields: [_ | _]}), do: true
  defp structured_image?(%Field{raw: %{"options" => %{"hotspot" => true}}}), do: true
  defp structured_image?(_), do: false

  @image_rects %{
    "hotspot" => ~w(x y height width),
    "crop" => ~w(top bottom left right)
  }

  defp walk_image(%Field{} = f, value, path, level) do
    rules = field_rules(f, level)

    cond do
      blank?(value) and required?(rules) ->
        Enum.map(apply_message([f("Required", :required)], rules), &pair(path, &1))

      is_nil(value) ->
        []

      is_binary(value) ->
        walk_image_fields(f, %{}, path, level)

      not is_map(value) ->
        shape(level, [
          {path, "expected an image URL or an image object", :image_shape, %{}}
        ])

      true ->
        rects =
          Enum.flat_map(@image_rects, fn {key, sides} ->
            image_rect_findings(Map.get(value, key), sides, path <> "/" <> key)
          end)

        shape(level, rects) ++ walk_image_fields(f, value, path, level)
    end
  end

  defp walk_image_fields(%Field{fields: kids}, value, path, level) do
    Enum.flat_map(kids || [], fn %Field{} = child ->
      walk_field(child, fetch_field(value, child.name), path <> "/" <> (child.name || ""), level)
    end)
  end

  defp image_rect_findings(nil, _sides, _path), do: []

  defp image_rect_findings(rect, sides, path) when is_map(rect) do
    Enum.flat_map(sides, fn side ->
      case Map.get(rect, side) do
        n when is_number(n) and n >= 0 and n <= 1 ->
          []

        _ ->
          [
            {path <> "/" <> side, "must be a number from 0 to 1", :rect_out_of_range,
             %{min: 0, max: 1}}
          ]
      end
    end)
  end

  defp image_rect_findings(_rect, sides, path),
    do: [
      {path, "expected an object with #{Enum.join(sides, ", ")}", :rect_shape, %{sides: sides}}
    ]

  # file (task-681df8da723386b8) — a bare leaf has no shape to check beyond
  # the generic v1 rules (walk_leaf); a `file` with declared subfields walks
  # them exactly like image's own composite subfields, no rect validation
  # (no hotspot/crop concept for a non-image asset).
  defp structured_file?(%Field{fields: [_ | _]}), do: true
  defp structured_file?(_), do: false

  defp walk_file(%Field{} = f, value, path, level) do
    rules = field_rules(f, level)

    cond do
      blank?(value) and required?(rules) ->
        Enum.map(apply_message([f("Required", :required)], rules), &pair(path, &1))

      is_nil(value) ->
        []

      is_binary(value) ->
        walk_image_fields(f, %{}, path, level)

      not is_map(value) ->
        shape(level, [{path, "expected a file URL or a file object", :file_shape, %{}}])

      true ->
        walk_image_fields(f, value, path, level)
    end
  end

  # The array's own length rule (v2 walker only; flat mode is frozen).
  defp check_list_bounds(list, rules) when is_list(list) do
    n = length(list)

    []
    |> then(fn acc ->
      case rules do
        %{"min" => min} when is_number(min) and n < min ->
          [f("Must have at least #{min} items", :list_too_short, %{min: min}) | acc]

        _ ->
          acc
      end
    end)
    |> then(fn acc ->
      case rules do
        %{"max" => max} when is_number(max) and n > max ->
          [f("Must have at most #{max} items", :list_too_long, %{max: max}) | acc]

        _ ->
          acc
      end
    end)
    |> then(fn acc ->
      # Sanity's `Rule.unique()` on an array (task-bd4b556125fe702e): opt-in, so
      # no schema without `"unique": true` sees a new finding.
      if match?(%{"unique" => true}, rules) and duplicate_items?(list),
        do: [f("Items must be unique", :list_not_unique) | acc],
        else: acc
    end)
    |> Enum.reverse()
  end

  # Two items are the same when they point at the same document (a reference, by
  # `_ref` or `ref`) or carry the same value; a row's `_key` is its identity in the
  # list, not its content, so it is left out of the comparison.
  defp duplicate_items?(list) do
    keys = Enum.map(list, &unique_key/1)
    length(Enum.uniq(keys)) < length(keys)
  end

  defp unique_key(%{} = item) do
    case Map.get(item, "_ref") || Map.get(item, "ref") do
      ref when is_binary(ref) and ref != "" -> {:ref, ref}
      _ -> {:value, Map.delete(item, "_key")}
    end
  end

  defp unique_key(item), do: {:value, item}

  defp localized_shape_findings(value, langs, fmt, path) do
    Enum.flat_map(value, fn {lang, text} ->
      lang_str = if is_atom(lang), do: Atom.to_string(lang), else: lang
      sub_path = path <> "/" <> to_string(lang_str)

      cond do
        not is_binary(lang_str) ->
          [{path, "language key must be a string", :language_key_not_string, %{}}]

        is_list(langs) and langs != [] and lang_str not in langs ->
          [
            {sub_path, "language '#{lang_str}' is not in declared languages",
             :language_not_declared, %{lang: lang_str}}
          ]

        fmt == :rich ->
          cond do
            is_map(text) ->
              []

            is_binary(text) ->
              []

            true ->
              [{sub_path, "rich text must be a map or string", :rich_text_shape, %{}}]
          end

        true ->
          if is_binary(text),
            do: [],
            else: [{sub_path, "text must be a string", :text_not_string, %{}}]
      end
    end)
  end

  # The field's `pattern`/`min`/`max` against each locale's text. `required`
  # is dropped here (the caller judges it once, over the whole map), so an
  # empty locale beside a filled one is not a finding. Non-string text (rich
  # maps, shape errors) no-ops: every check below is `is_binary`-guarded.
  defp localized_rule_findings(value, rules, raw, path) do
    rules = Map.drop(rules, ["required", :required])

    value
    |> Enum.filter(fn {_lang, text} -> is_binary(text) end)
    |> Enum.flat_map(fn {lang, text} ->
      validate_field(text, rules, raw) |> Enum.map(&pair(path <> "/" <> to_string(lang), &1))
    end)
  end

  defp localized_filled?(value) do
    Enum.any?(value, fn
      {_lang, text} when is_binary(text) -> text != ""
      {_lang, text} when is_map(text) -> map_size(text) > 0
      _ -> false
    end)
  end

  # A malformed VALUE (a list where an object was declared, a codelist that
  # is not a string) is a shape finding, not a rule: it belongs to the error
  # pass only, so the warning pass never duplicates it.
  defp shape(:error, findings), do: findings
  defp shape(_level, _findings), do: []

  # v2-ONLY numeric min/max. The shared `check_min`/`check_max` below are
  # `is_binary`-guarded (they measure String.length), so a NUMBER leaf never
  # gets range-checked on the flat_mode path — and that frozen v1 path must NOT
  # change. This enforces min/max as a *numeric* bound, and only from the v2
  # recursive walker's primitive branch. Malformed rule values (null, string)
  # are no-ops via the `is_number` guards.
  defp check_numeric_bounds(value, rules) when is_number(value) do
    []
    |> number_min(value, rules)
    |> number_max(value, rules)
    |> Enum.reverse()
  end

  defp check_numeric_bounds(_value, _rules), do: []

  defp number_min(errors, value, %{"min" => min}) when is_number(min) do
    if value < min,
      do: [f("Must be at least #{min}", :number_too_small, %{min: min}) | errors],
      else: errors
  end

  defp number_min(errors, _value, _rules), do: errors

  defp number_max(errors, value, %{"max" => max}) when is_number(max) do
    if value > max,
      do: [f("Must be at most #{max}", :number_too_large, %{max: max}) | errors],
      else: errors
  end

  defp number_max(errors, _value, _rules), do: errors

  defp field_rules(%Field{raw: raw}, level) when is_map(raw) do
    rules_at(Map.get(raw, "validation") || Map.get(raw, :validation), level)
  end

  defp field_rules(_, _level), do: %{}

  defp required?(%{"required" => true}), do: true
  defp required?(%{required: true}), do: true
  defp required?(_), do: false

  defp to_atom_safe(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp to_atom_safe(_), do: nil

  # Presence-aware field lookup: `Map.get || Map.get` collapses the falsy values
  # `false` and `0` to nil, making a required boolean=false or number=0 look
  # absent. Map.fetch distinguishes "present but falsy" from "missing".
  defp fetch_field(map, name) do
    case Map.fetch(map, name) do
      {:ok, v} ->
        v

      :error ->
        case to_atom_safe(name) do
          nil -> nil
          atom -> Map.get(map, atom)
        end
    end
  end

  # ── per-field rule checks (shared by flat_mode and v2 primitive leaves) ───

  # Returns `[{message, code, params}]` — a path is not yet known here (the
  # flat_mode caller's "path" is just the field name, added by it directly;
  # the v2 caller pairs these with a real path via `pair/2`).
  defp validate_field(value, rules, field) do
    value = unwrap_slug(value, field)

    []
    |> check_required(value, rules)
    |> check_min(value, rules, field)
    |> check_max(value, rules, field)
    |> check_pattern(value, rules)
    |> Enum.reverse()
    |> apply_message(rules)
  end

  # task-bb7c45fe5e501d76 — Sanity's slug object shape, `{_type: "slug",
  # current: "my-slug"}` (the shape Studio's own slug input stores), vs. the
  # bare-string shape `"my-slug"` a direct API write can send for the same
  # field. `check_required/3`, `check_min/4`, `check_max/4` and
  # `check_pattern/2` above are ALL `is_binary(value)`-guarded leaf checks —
  # against the wrapping map they silently no-op, so a slug field's
  # `pattern`/`min`/`max` rule never ran on this shape at all (found live,
  # studio-parity/e2e-freeform advisory dataset: `slug: {_type:"slug",
  # current:"Bad Slug"}` produced NO finding where `slug: "Bad Slug"` did).
  # Unwrapped here, once, for every rule check at once — gated on the FIELD's
  # own declared type (not the value's self-reported `_type`, which a
  # caller could spoof on an unrelated field to dodge that field's own
  # rules), so nothing changes for a field that isn't actually `"slug"`.
  # `current` missing or non-string unwraps to `nil`, which `blank?/1`
  # below correctly treats as empty for `required` (the "required-non-
  # empty" half of the gap) and which every binary-guarded check already
  # no-ops on safely.
  defp unwrap_slug(value, field) when is_map(value) do
    if get_in_field(field, "type") == "slug" do
      case Map.get(value, "current") do
        current when is_binary(current) -> current
        _ -> nil
      end
    else
      value
    end
  end

  defp unwrap_slug(value, _field), do: value

  defp check_required(errors, value, %{"required" => true}) do
    if blank?(value) do
      [f("Required", :required) | errors]
    else
      errors
    end
  end

  defp check_required(errors, _value, _rules), do: errors

  # `is_number(min)` guards a malformed rule (`"min": null` or a JSON string):
  # without it, `String.length(value) < min` fires via Elixir term ordering
  # (a number is always < an atom/binary) and the field rejects ALL content
  # with a confusing 422. A mistyped rule must be a no-op, not a reject-all.
  # Non-tightening on both paths.
  defp check_min(errors, value, %{"min" => min}, _field)
       when is_binary(value) and byte_size(value) > 0 and is_number(min) do
    if String.length(value) < min do
      [f("Must be at least #{min} characters", :string_too_short, %{min: min}) | errors]
    else
      errors
    end
  end

  defp check_min(errors, _value, _rules, _field), do: errors

  defp check_max(errors, value, %{"max" => max}, _field)
       when is_binary(value) and is_number(max) do
    if String.length(value) > max do
      [f("Must be at most #{max} characters", :string_too_long, %{max: max}) | errors]
    else
      errors
    end
  end

  defp check_max(errors, _value, _rules, _field), do: errors

  defp check_pattern(errors, value, %{"pattern" => pattern})
       when is_binary(value) and byte_size(value) > 0 and is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        if Regex.match?(regex, value) do
          errors
        else
          [f("Does not match required format", :pattern_mismatch) | errors]
        end

      _ ->
        errors
    end
  end

  defp check_pattern(errors, _value, _rules), do: errors

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
