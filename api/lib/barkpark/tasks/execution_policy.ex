defmodule Barkpark.Tasks.ExecutionPolicy do
  @moduledoc """
  Strict, advisory execution hints carried by a Task.

  Version 1 deliberately exposes only routing and capacity hints. It cannot
  carry commands, environment, working directories, credentials, permissions,
  or other security-sensitive runtime controls.
  """

  @version 1
  @fields ~w(agent_type model reasoning_effort resource_class)
  @allowed_fields ["version" | @fields]
  @reasoning_efforts ~w(minimal low medium high xhigh)
  @resource_classes ~w(light standard heavy)
  @sources ~w(explicit task session provider)

  @type policy :: %{String.t() => term()}

  @doc "Validate an optional Task policy without returning its normalized form."
  @spec validate(nil | map()) :: :ok | {:error, map()}
  def validate(policy) do
    case sanitize(policy) do
      {:ok, _} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  @doc "Validate and normalize an optional version-1 policy."
  @spec sanitize(nil | map()) :: {:ok, nil | policy()} | {:error, map()}
  def sanitize(nil), do: {:ok, nil}

  def sanitize(policy) when is_map(policy) do
    with {:ok, normalized} <- normalize_keys(policy),
         :ok <- reject_unknown_fields(normalized),
         :ok <- validate_version(normalized),
         :ok <- validate_string(normalized, "agent_type", 64),
         :ok <- validate_string(normalized, "model", 128),
         :ok <- validate_enum(normalized, "reasoning_effort", @reasoning_efforts),
         :ok <- validate_enum(normalized, "resource_class", @resource_classes) do
      {:ok, sanitize_values(normalized)}
    end
  end

  def sanitize(other),
    do: {:error, %{"execution_policy" => ["must be a map when set, got #{inspect(other)}"]}}

  @doc """
  Resolve a frozen policy snapshot with per-field precedence:
  explicit override > Task > session/user > provider.

  Every layer is independently sanitized before any value is selected. The
  returned snapshot contains only safe resolved values, deterministic field
  provenance, and advisory override notices.
  """
  @spec resolve(nil | map(), nil | map(), nil | map(), nil | map()) ::
          {:ok, nil | map()} | {:error, map()}
  def resolve(explicit, task, session, provider) do
    raw_sources = [explicit, task, session, provider]

    with {:ok, policies} <- sanitize_sources(raw_sources) do
      if Enum.all?(policies, &is_nil/1) do
        {:ok, nil}
      else
        {resolved, provenance, notices} = resolve_fields(policies)

        {:ok,
         %{
           "version" => @version,
           "resolved" => resolved,
           "sources" => provenance,
           "notices" => notices
         }}
      end
    end
  end

  defp normalize_keys(policy) do
    Enum.reduce_while(policy, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      normalized_key =
        case key do
          key when is_binary(key) -> key
          key when is_atom(key) -> Atom.to_string(key)
          _ -> nil
        end

      cond do
        is_nil(normalized_key) ->
          {:halt,
           {:error, %{"execution_policy" => ["keys must be strings, got #{inspect(key)}"]}}}

        Map.has_key?(acc, normalized_key) ->
          {:halt,
           {:error, %{normalized_key => ["is duplicated by both atom and string key forms"]}}}

        true ->
          {:cont, {:ok, Map.put(acc, normalized_key, value)}}
      end
    end)
  end

  defp reject_unknown_fields(policy) do
    case Map.keys(policy) -- @allowed_fields do
      [] ->
        :ok

      unknown ->
        {:error,
         Map.new(unknown, fn field ->
           {field, ["is not allowed in execution_policy version 1"]}
         end)}
    end
  end

  defp validate_version(%{"version" => @version}), do: :ok

  defp validate_version(%{"version" => other}),
    do: {:error, %{"version" => ["must be integer #{@version}, got #{inspect(other)}"]}}

  defp validate_version(_), do: {:error, %{"version" => ["is required and must be integer 1"]}}

  defp validate_string(policy, field, max_bytes) do
    case Map.get(policy, field) do
      nil ->
        :ok

      value when is_binary(value) ->
        trimmed = String.trim(value)

        cond do
          trimmed == "" ->
            {:error, %{field => ["must not be blank"]}}

          byte_size(trimmed) > max_bytes ->
            {:error, %{field => ["must be at most #{max_bytes} bytes"]}}

          true ->
            :ok
        end

      other ->
        {:error, %{field => ["must be a string when set, got #{inspect(other)}"]}}
    end
  end

  defp validate_enum(policy, field, allowed) do
    case Map.get(policy, field) do
      nil ->
        :ok

      value ->
        if value in allowed do
          :ok
        else
          {:error, %{field => ["must be one of #{inspect(allowed)}, got #{inspect(value)}"]}}
        end
    end
  end

  defp sanitize_values(policy) do
    policy
    |> Map.take(@allowed_fields)
    |> Map.new(fn
      {field, value} when field in ["agent_type", "model"] and is_binary(value) ->
        {field, String.trim(value)}

      pair ->
        pair
    end)
  end

  defp sanitize_sources(raw_sources) do
    raw_sources
    |> Enum.zip(@sources)
    |> Enum.reduce_while({:ok, []}, fn {policy, source}, {:ok, acc} ->
      case sanitize(policy) do
        {:ok, sanitized} -> {:cont, {:ok, [sanitized | acc]}}
        {:error, errors} -> {:halt, {:error, prefix_errors(errors, source)}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp prefix_errors(errors, source) do
    Map.new(errors, fn {field, messages} -> {"#{source}.#{field}", messages} end)
  end

  defp resolve_fields(policies) do
    Enum.reduce(@fields, {%{}, %{}, []}, fn field, {resolved, provenance, notices} ->
      candidates =
        policies
        |> Enum.zip(@sources)
        |> Enum.flat_map(fn
          {nil, _source} ->
            []

          {policy, source} ->
            if Map.has_key?(policy, field), do: [{source, policy[field]}], else: []
        end)

      case candidates do
        [] ->
          {resolved, provenance, notices}

        [{winner_source, value} | rest] ->
          shadowed = for {source, other} <- rest, other != value, do: source

          notice =
            if shadowed == [] do
              []
            else
              [
                %{
                  "type" => "execution_policy_override",
                  "field" => field,
                  "source" => winner_source,
                  "overrode" => shadowed
                }
              ]
            end

          {
            Map.put(resolved, field, value),
            Map.put(provenance, field, winner_source),
            notices ++ notice
          }
      end
    end)
  end
end
