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
  """

  require Logger

  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Content.SchemaDefinition.{Field, Parsed}

  @doc "Validate content map against a schema's fields. Returns {:ok, content} or {:error, errors}."
  def validate(content, title, schema) do
    if flat_mode?(schema) do
      validate_flat(content, title, schema)
    else
      validate_v2(content, title, schema)
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

  # ── flat_mode dispatch ────────────────────────────────────────────────────

  defp flat_mode?(nil), do: true

  defp flat_mode?(schema) do
    SchemaDefinition.flat?(schema)
  rescue
    _ -> true
  end

  # ── flat_mode (legacy v1 — DO NOT TIGHTEN BEHAVIOUR) ──────────────────────

  defp validate_flat(content, title, schema) do
    fields = schema_fields(schema)

    errors =
      fields
      |> Enum.reduce(%{}, fn field, acc ->
        field_name = get_in_field(field, "name")
        rules = get_in_field(field, "validation") || %{}

        # Title field is stored at top level, not in content
        value = if field_name == "title", do: title, else: Map.get(content || %{}, field_name)

        field_errors = validate_field(value, rules, field)

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

  defp schema_fields(nil), do: []

  defp schema_fields(schema) when is_map(schema) do
    Map.get(schema, :fields) || Map.get(schema, "fields") || []
  end

  defp get_in_field(field, key) when is_map(field) do
    Map.get(field, key) || Map.get(field, String.to_atom(key))
  end

  defp get_in_field(_, _), do: nil

  # ── v2 path (recursive) ───────────────────────────────────────────────────

  defp validate_v2(content, title, schema) do
    case SchemaDefinition.parse(schema) do
      {:ok, %Parsed{} = parsed} ->
        validate_parsed(content, title, parsed)

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

        validate_flat(content, title, schema)
    end
  end

  defp validate_parsed(content, title, %Parsed{fields: fields}) do
    errors_by_top =
      Enum.reduce(fields, %{}, fn %Field{} = field, acc ->
        value =
          if field.name == "title" do
            title
          else
            fetch_field(content || %{}, field.name)
          end

        top_path = "/" <> (field.name || "")
        pairs = walk_field(field, value, top_path)

        case pairs do
          [] ->
            acc

          list ->
            msgs = Enum.map(list, fn {p, m} -> format_msg(top_path, p, m) end)
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

  # walk_field returns [{path :: String.t(), msg :: String.t()}]

  # composite — recurse into named subfields
  defp walk_field(%Field{type: "composite", fields: kids} = f, value, path) do
    rules = field_rules(f)

    cond do
      blank?(value) and required?(rules) ->
        [{path, "Required"}]

      is_nil(value) ->
        []

      not is_map(value) ->
        [{path, "expected an object"}]

      true ->
        Enum.flat_map(kids || [], fn %Field{} = child ->
          child_value = fetch_field(value, child.name)

          walk_field(child, child_value, path <> "/" <> (child.name || ""))
        end)
    end
  end

  # arrayOf — iterate elements with index-prefixed paths
  defp walk_field(%Field{type: "arrayOf", of: of} = f, value, path) do
    rules = field_rules(f)

    cond do
      blank?(value) and required?(rules) ->
        [{path, "Required"}]

      is_nil(value) ->
        []

      not is_list(value) ->
        [{path, "expected a list"}]

      is_nil(of) ->
        # Schema lacks an `of` shape descriptor — defer to v2 schema parser
        # (which would reject), so this is a defensive no-op.
        []

      true ->
        value
        |> Enum.with_index()
        |> Enum.flat_map(fn {item, idx} ->
          walk_field(of, item, path <> "/" <> Integer.to_string(idx))
        end)
    end
  end

  # codelist — shape only (string, non-empty, no whitespace). Membership
  # checks against the registry are deferred to the rendering layer (W2.4).
  defp walk_field(%Field{type: "codelist"} = f, value, path) do
    rules = field_rules(f)

    cond do
      blank?(value) and required?(rules) ->
        [{path, "Required"}]

      is_nil(value) ->
        []

      not is_binary(value) ->
        [{path, "codelist value must be a string"}]

      value == "" ->
        [{path, "codelist value cannot be empty"}]

      Regex.match?(~r/\s/, value) ->
        [{path, "codelist value cannot contain whitespace"}]

      true ->
        []
    end
  end

  # localizedText — shape only. fallbackChain enforcement is rendering's
  # concern (W2.4); validator does NOT raise on missing primary translation.
  defp walk_field(
         %Field{type: "localizedText", languages: langs, format: fmt} = f,
         value,
         path
       ) do
    rules = field_rules(f)

    cond do
      blank?(value) and required?(rules) ->
        [{path, "Required"}]

      is_nil(value) ->
        []

      not is_map(value) ->
        [{path, "localizedText must be a map of language → text"}]

      true ->
        Enum.flat_map(value, fn {lang, text} ->
          lang_str = if is_atom(lang), do: Atom.to_string(lang), else: lang
          sub_path = path <> "/" <> to_string(lang_str)

          cond do
            not is_binary(lang_str) ->
              [{path, "language key must be a string"}]

            is_list(langs) and langs != [] and lang_str not in langs ->
              [{sub_path, "language '#{lang_str}' is not in declared languages"}]

            fmt == :rich ->
              cond do
                is_map(text) -> []
                is_binary(text) -> []
                true -> [{sub_path, "rich text must be a map or string"}]
              end

            true ->
              if is_binary(text), do: [], else: [{sub_path, "text must be a string"}]
          end
        end)
    end
  end

  # primitive leaf — apply v1-style rules from raw["validation"]
  defp walk_field(%Field{} = f, value, path) do
    rules = field_rules(f)
    msgs = validate_field(value, rules, f.raw || %{})
    msgs = msgs ++ check_numeric_bounds(value, rules)
    Enum.map(msgs, fn m -> {path, m} end)
  end

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
    if value < min, do: ["Must be at least #{min}" | errors], else: errors
  end

  defp number_min(errors, _value, _rules), do: errors

  defp number_max(errors, value, %{"max" => max}) when is_number(max) do
    if value > max, do: ["Must be at most #{max}" | errors], else: errors
  end

  defp number_max(errors, _value, _rules), do: errors

  defp field_rules(%Field{raw: raw}) when is_map(raw) do
    Map.get(raw, "validation") || Map.get(raw, :validation) || %{}
  end

  defp field_rules(_), do: %{}

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

  defp validate_field(value, rules, field) do
    []
    |> check_required(value, rules)
    |> check_min(value, rules, field)
    |> check_max(value, rules, field)
    |> check_pattern(value, rules)
    |> Enum.reverse()
  end

  defp check_required(errors, value, %{"required" => true}) do
    if blank?(value) do
      ["Required" | errors]
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
      ["Must be at least #{min} characters" | errors]
    else
      errors
    end
  end

  defp check_min(errors, _value, _rules, _field), do: errors

  defp check_max(errors, value, %{"max" => max}, _field)
       when is_binary(value) and is_number(max) do
    if String.length(value) > max do
      ["Must be at most #{max} characters" | errors]
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
          ["Does not match required format" | errors]
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
