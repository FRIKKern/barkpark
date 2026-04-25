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
  """

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

      {:error, _} ->
        # Defensive fallback — if a schema fails to parse for some reason,
        # behave like the legacy validator rather than blowing up callers.
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
            Map.get(content || %{}, field.name) ||
              Map.get(content || %{}, to_atom_safe(field.name))
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
          child_value =
            Map.get(value, child.name) ||
              Map.get(value, to_atom_safe(child.name))

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
    Enum.map(msgs, fn m -> {path, m} end)
  end

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

  defp check_min(errors, value, %{"min" => min}, _field)
       when is_binary(value) and byte_size(value) > 0 do
    if String.length(value) < min do
      ["Must be at least #{min} characters" | errors]
    else
      errors
    end
  end

  defp check_min(errors, _value, _rules, _field), do: errors

  defp check_max(errors, value, %{"max" => max}, _field) when is_binary(value) do
    if String.length(value) > max do
      ["Must be at most #{max} characters" | errors]
    else
      errors
    end
  end

  defp check_max(errors, _value, _rules, _field), do: errors

  defp check_pattern(errors, value, %{"pattern" => pattern})
       when is_binary(value) and byte_size(value) > 0 do
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
