defmodule Barkpark.ApiTestRunner.Asserts do
  @moduledoc """
  Built-in evaluators for the 8 assert tagged-tuples used by api_tests/0 specs.

  Per plan §0 Q2 (barkpark-bsp) — the assert set is fixed in v1:

    {:status, integer}
    {:body_contains, String.t}
    {:body_regex, Regex.t}
    {:json_path, list, (any -> boolean)}
    {:json_keys_include, [String.t]}
    {:header, name, val_or_fn}
    :not_empty
    {:duration_under_ms, non_neg_integer}

  `evaluate/2` receives the assert tuple and the response (a map with
  :status, :body, :headers, :duration_ms), and returns `{:pass, message}`
  or `{:fail, message}`. Errors during evaluation (e.g. body not valid
  JSON when :json_path is used) return `{:fail, "<error>"}` rather
  than raising — keeps the runner's per-test isolation contract intact.
  """

  @type response :: %{
          required(:status) => integer(),
          required(:body) => String.t() | nil,
          required(:headers) => [{String.t(), String.t()}] | %{String.t() => String.t()},
          required(:duration_ms) => non_neg_integer()
        }

  @spec evaluate(Barkpark.Plugin.api_test_assert(), response()) :: {:pass | :fail, String.t()}
  def evaluate({:status, expected}, %{status: actual}) when is_integer(expected) do
    if actual == expected,
      do: {:pass, "status #{actual}"},
      else: {:fail, "expected status #{expected}, got #{actual}"}
  end

  def evaluate({:body_contains, needle}, %{body: body}) when is_binary(needle) do
    cond do
      is_nil(body) -> {:fail, ~s|expected body to contain "#{needle}", but body is nil|}
      String.contains?(body, needle) -> {:pass, ~s|body contains "#{needle}"|}
      true -> {:fail, ~s|body does not contain "#{needle}"|}
    end
  end

  def evaluate({:body_regex, %Regex{} = re}, %{body: body}) do
    cond do
      is_nil(body) -> {:fail, "body is nil — regex not applicable"}
      Regex.match?(re, body) -> {:pass, "body matches #{inspect(re)}"}
      true -> {:fail, "body does not match #{inspect(re)}"}
    end
  end

  def evaluate({:json_path, path, fun}, %{body: body})
      when is_list(path) and is_function(fun, 1) do
    with {:ok, json} <- decode_json(body),
         {:ok, value} <- get_path(json, path) do
      if fun.(value) do
        {:pass, "json_path #{inspect(path)} matched (value=#{inspect(value)})"}
      else
        {:fail, "json_path #{inspect(path)} predicate failed (value=#{inspect(value)})"}
      end
    else
      {:error, reason} -> {:fail, reason}
    end
  end

  def evaluate({:json_keys_include, keys}, %{body: body}) when is_list(keys) do
    case decode_json(body) do
      {:ok, %{} = map} ->
        missing = Enum.reject(keys, &Map.has_key?(map, &1))

        if missing == [] do
          {:pass, "json contains all keys #{inspect(keys)}"}
        else
          {:fail, "json missing keys: #{inspect(missing)}"}
        end

      {:ok, other} ->
        {:fail, "json is not a map: #{inspect(other)}"}

      {:error, reason} ->
        {:fail, reason}
    end
  end

  def evaluate({:header, name, expected}, %{headers: headers}) do
    actual = find_header(headers, name)

    cond do
      is_nil(actual) ->
        {:fail, ~s|header "#{name}" not present|}

      is_binary(expected) and actual == expected ->
        {:pass, ~s|header "#{name}" matches "#{expected}"|}

      is_binary(expected) ->
        {:fail, ~s|header "#{name}" expected "#{expected}", got "#{actual}"|}

      is_function(expected, 1) ->
        if expected.(actual) do
          {:pass, ~s|header "#{name}" predicate passed (value="#{actual}")|}
        else
          {:fail, ~s|header "#{name}" predicate failed (value="#{actual}")|}
        end

      true ->
        {:fail, "invalid expected for :header — must be String.t or arity-1 fn"}
    end
  end

  def evaluate(:not_empty, %{body: body}) do
    case body do
      nil -> {:fail, "body is nil"}
      "" -> {:fail, "body is empty"}
      _ -> {:pass, "body has content (#{byte_size(body)} bytes)"}
    end
  end

  def evaluate({:duration_under_ms, ceiling}, %{duration_ms: actual})
      when is_integer(ceiling) do
    if actual <= ceiling do
      {:pass, "duration #{actual}ms <= #{ceiling}ms"}
    else
      {:fail, "duration #{actual}ms exceeds #{ceiling}ms"}
    end
  end

  def evaluate(unknown, _response) do
    {:fail, "unknown assert tag: #{inspect(unknown)}"}
  end

  # ---- helpers ----

  defp decode_json(nil), do: {:error, "body is nil"}

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json} ->
        {:ok, json}

      {:error, %Jason.DecodeError{} = e} ->
        {:error, "json decode failed: #{Exception.message(e)}"}
    end
  end

  defp get_path(value, []), do: {:ok, value}

  defp get_path(map, [key | rest]) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, v} ->
        get_path(v, rest)

      :error ->
        {:error, "json_path: missing key #{inspect(key)} (have #{inspect(Map.keys(map))})"}
    end
  end

  defp get_path(list, [idx | rest]) when is_list(list) and is_integer(idx) do
    case Enum.at(list, idx) do
      nil -> {:error, "json_path: index #{idx} out of bounds (len=#{length(list)})"}
      v -> get_path(v, rest)
    end
  end

  defp get_path(value, [step | _]),
    do: {:error, "json_path: cannot traverse #{inspect(value)} via #{inspect(step)}"}

  defp find_header(headers, name) when is_map(headers) do
    Map.get(headers, name) || Map.get(headers, String.downcase(name))
  end

  defp find_header(headers, name) when is_list(headers) do
    name_d = String.downcase(name)
    Enum.find_value(headers, fn {k, v} -> if String.downcase(to_string(k)) == name_d, do: v end)
  end
end
