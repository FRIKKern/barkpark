defmodule Barkpark.Content.Validation do
  @moduledoc """
  Validates document content against schema field definitions.

  Fields can include a "validation" key with rules:
    - "required": true         — field must have a non-empty value
    - "min": 3                 — minimum string length
    - "max": 100               — maximum string length
    - "pattern": "^[a-z-]+$"   — regex pattern the value must match

  Returns {:ok, content} or {:error, errors} where errors is a map of
  field_name => [error_messages].
  """

  @doc "Validate content map against a schema's fields. Returns {:ok, content} or {:error, errors}."
  def validate(content, title, schema) do
    fields = schema.fields || []

    errors =
      fields
      |> Enum.reduce(%{}, fn field, acc ->
        field_name = field["name"]
        rules = field["validation"] || %{}

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

  defp check_min(errors, value, %{"min" => min}, _field) when is_binary(value) and byte_size(value) > 0 do
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

  defp check_pattern(errors, value, %{"pattern" => pattern}) when is_binary(value) and byte_size(value) > 0 do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        if Regex.match?(regex, value) do
          errors
        else
          ["Does not match required format" | errors]
        end
      _ -> errors
    end
  end
  defp check_pattern(errors, _value, _rules), do: errors

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
