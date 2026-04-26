defmodule BarkparkWeb.ErrorEnvelope do
  @moduledoc """
  Serializes validation outcomes into v1 or v2 JSON error envelopes.

  ## Versions

  * **v1** (default, returned when `Accept-Version` is absent or `1`) —
    the legacy flat shape: `%{"errors" => [string, ...]}`. Existing TUI
    clients and the ad-hoc `curl` workflows in `CLAUDE.md` rely on this.

  * **v2** (opt-in via `Accept-Version: 2`) — hierarchical, structured.
    `%{"errors" => %{path => [violation]}, "warnings" => ..., "infos" => ...}`
    where `path` is a JSON Pointer (e.g. `"/contributors/0/role"`) and
    each `violation` is `%{severity, code, message, rule}`.

  ## Accepted inputs

  Both `serialize_v1/1` and `serialize_v2/1` accept any of:

  * a `validation_result` map produced by the WI1 evaluator —
    `%{errors: [violation], warnings: [violation], infos: [violation]}`
    where `violation = %{severity, code, message, rule_name, path}`;
  * the legacy flat per-field shape `%{field_name => [string, ...]}`
    emitted by `Barkpark.Content.Validation`;
  * a flat list of strings.

  Sniffing happens at the top level so the same envelope module can serve
  pre- and post-WI1 traffic during the transition.
  """

  @type violation :: %{
          required(:severity) => atom() | String.t(),
          required(:code) => atom() | String.t(),
          required(:message) => String.t(),
          required(:rule_name) => String.t() | atom() | nil,
          required(:path) => String.t() | nil
        }

  @type validation_result :: %{
          optional(:errors) => [violation],
          optional(:warnings) => [violation],
          optional(:infos) => [violation]
        }

  @type input :: validation_result | %{optional(any) => any} | [String.t()]

  # ── v1 ──────────────────────────────────────────────────────────────────

  @doc """
  Serialize to the legacy v1 envelope: `%{"errors" => [string, ...]}`.

  v1 collapses violation structure into plain strings so existing clients
  (which only know how to render an error list) keep working.
  """
  @spec serialize_v1(input) :: %{required(String.t()) => [String.t()]}
  def serialize_v1(%{} = result) do
    cond do
      validation_result?(result) ->
        %{"errors" => Enum.map(get_violations(result, :errors), &violation_to_string/1)}

      legacy_field_map?(result) ->
        %{"errors" => flatten_legacy_map(result)}

      true ->
        %{"errors" => []}
    end
  end

  def serialize_v1(list) when is_list(list) do
    %{"errors" => Enum.map(list, &to_string/1)}
  end

  def serialize_v1(_), do: %{"errors" => []}

  # ── v2 ──────────────────────────────────────────────────────────────────

  @doc """
  Serialize to the v2 envelope. Returns a map with `"errors"`, `"warnings"`,
  and `"infos"` keys, each a map keyed by JSON Pointer path, with values
  that are lists of `%{severity, code, message, rule}` maps.
  """
  @spec serialize_v2(input) :: %{required(String.t()) => map()}
  def serialize_v2(%{} = result) do
    cond do
      validation_result?(result) ->
        %{
          "errors" => group_violations(get_violations(result, :errors)),
          "warnings" => group_violations(get_violations(result, :warnings)),
          "infos" => group_violations(get_violations(result, :infos))
        }

      legacy_field_map?(result) ->
        %{
          "errors" => legacy_to_v2(result),
          "warnings" => %{},
          "infos" => %{}
        }

      true ->
        empty_v2()
    end
  end

  def serialize_v2(list) when is_list(list) do
    grouped =
      list
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {msg, idx}, acc ->
        path = "/##{idx}"
        Map.update(acc, path, [legacy_violation(msg)], &(&1 ++ [legacy_violation(msg)]))
      end)

    %{"errors" => grouped, "warnings" => %{}, "infos" => %{}}
  end

  def serialize_v2(_), do: empty_v2()

  # ── helpers ─────────────────────────────────────────────────────────────

  defp empty_v2, do: %{"errors" => %{}, "warnings" => %{}, "infos" => %{}}

  defp validation_result?(map) when is_map(map) do
    Enum.any?([:errors, :warnings, :infos], fn key ->
      case Map.get(map, key) do
        nil -> false
        list when is_list(list) -> Enum.all?(list, &is_map/1)
        _ -> false
      end
    end)
  end

  defp legacy_field_map?(map) when is_map(map) and map_size(map) > 0 do
    Enum.all?(map, fn
      {key, value} ->
        (is_binary(key) or is_atom(key)) and is_list(value) and
          Enum.all?(value, &is_binary/1)
    end)
  end

  defp legacy_field_map?(_), do: false

  defp get_violations(result, key) when is_map(result) do
    Map.get(result, key) || []
  end

  defp violation_to_string(%{message: msg, path: path})
       when is_binary(msg) and is_binary(path) and path != "" and path != "/" do
    "#{path}: #{msg}"
  end

  defp violation_to_string(%{message: msg}) when is_binary(msg), do: msg
  defp violation_to_string(other), do: inspect(other)

  defp flatten_legacy_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.flat_map(fn {field, msgs} ->
      key = to_string(field)
      Enum.map(msgs, fn m -> "#{key}: #{m}" end)
    end)
  end

  defp group_violations(list) when is_list(list) do
    Enum.reduce(list, %{}, fn v, acc ->
      path = path_of(v)
      entry = serialize_violation(v)
      Map.update(acc, path, [entry], &(&1 ++ [entry]))
    end)
  end

  defp path_of(%{path: p}) when is_binary(p) and p != "", do: p
  defp path_of(_), do: "/"

  defp serialize_violation(v) when is_map(v) do
    %{
      "severity" => stringify(Map.get(v, :severity, "error")),
      "code" => stringify(Map.get(v, :code, "unknown")),
      "message" => to_string(Map.get(v, :message, "")),
      "rule" => stringify(Map.get(v, :rule_name) || Map.get(v, :rule))
    }
  end

  defp legacy_to_v2(map) do
    Enum.reduce(map, %{}, fn {field, msgs}, acc ->
      field_name = to_string(field)

      Enum.reduce(msgs, acc, fn msg, inner ->
        {path, message} = parse_legacy_message(field_name, msg)
        entry = legacy_violation(message)
        Map.update(inner, path, [entry], &(&1 ++ [entry]))
      end)
    end)
  end

  # Validation.format_msg/3 produces "/sub/path: msg" for nested errors
  # and bare "msg" for top-level — recover the path here.
  defp parse_legacy_message(field, msg) when is_binary(msg) do
    case String.split(msg, ": ", parts: 2) do
      ["/" <> _ = nested_path, body] -> {nested_path, body}
      _ -> {"/" <> field, msg}
    end
  end

  defp parse_legacy_message(field, msg), do: {"/" <> field, to_string(msg)}

  defp legacy_violation(msg) do
    %{
      "severity" => "error",
      "code" => "legacy",
      "message" => to_string(msg),
      "rule" => nil
    }
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
