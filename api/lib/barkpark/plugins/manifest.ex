defmodule Barkpark.Plugins.Manifest do
  @moduledoc """
  Compile-time + runtime validator for plugin manifests (`plugin.json`).

  Honors decision D7: this module never executes manifest content. It only
  inspects structure against the canonical JSON Schema at
  `priv/plugin_manifest_schema.json`.

  The schema is loaded once at module compile time and embedded as a module
  attribute, so `validate!/1` does no I/O on the hot path. This is critical
  because `Barkpark.Plugin`'s `__using__/1` macro (WI1) calls `validate!/1`
  during plugin module compilation.
  """

  alias ExJsonSchema.Validator

  defmodule InvalidError do
    @moduledoc "Raised when a plugin manifest fails schema validation."
    defexception [:message, :errors, :manifest]

    @impl true
    def exception(opts) do
      errors = Keyword.fetch!(opts, :errors)
      manifest = Keyword.get(opts, :manifest)
      message = Keyword.get(opts, :message) || format_message(errors)
      %__MODULE__{message: message, errors: errors, manifest: manifest}
    end

    defp format_message(errors) do
      lines =
        errors
        |> Enum.map(fn %{path: path, message: msg} ->
          "  - #{path}: #{msg}"
        end)

      "invalid plugin manifest:\n" <> Enum.join(lines, "\n")
    end
  end

  @schema_path Path.expand(
                 Path.join([__DIR__, "..", "..", "..", "priv", "plugin_manifest_schema.json"])
               )
  @external_resource @schema_path

  @raw_schema File.read!(@schema_path)
  @resolved_schema @raw_schema |> Jason.decode!() |> ExJsonSchema.Schema.resolve()
  @schema_map Jason.decode!(@raw_schema)

  @doc "Returns the JSON Schema as a map (decoded once at compile time)."
  @spec schema() :: map()
  def schema, do: @schema_map

  @doc """
  Validates a parsed manifest map. Returns the manifest unchanged on success.
  Raises `Barkpark.Plugins.Manifest.InvalidError` on failure.
  """
  @spec validate!(map()) :: map()
  def validate!(manifest) when is_map(manifest) do
    case validate(manifest) do
      {:ok, ^manifest} ->
        manifest

      {:error, errors} ->
        raise InvalidError, errors: errors, manifest: manifest
    end
  end

  @doc """
  Non-raising variant. Returns `{:ok, manifest}` or `{:error, errors}` where
  each error is `%{path: String.t(), message: String.t()}`.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, [%{path: String.t(), message: String.t()}]}
  def validate(manifest) when is_map(manifest) do
    case Validator.validate(@resolved_schema, manifest) do
      :ok ->
        {:ok, manifest}

      {:error, errors} ->
        {:error, normalize_errors(errors)}
    end
  end

  @doc """
  Reads, decodes, and validates a manifest file at `path`.
  Raises on JSON decode failure or validation failure.
  """
  @spec parse_and_validate!(Path.t()) :: map()
  # `File.read!/1` reads `path`. THIS FUNCTION HAS NO CALLER IN `lib/` — measured
  # 2026-09-22, the only call sites are test/barkpark/plugins/manifest_test.exs
  # :200 and :209, which pass a tmp path they wrote themselves. (Control: the
  # same grep finds the sibling `validate!/1` called at lib/barkpark/plugin.ex
  # :1027, so the absence is real, not a broken search.) `validate!/1` takes an
  # already-decoded map and does no file I/O, so no production path reaches this
  # `File.read!`. The waiver is therefore about the ONLY input this function can
  # receive today, and a future production caller must re-reason it: it is safe
  # only while `path` is engine-derived (a plugin dir from
  # `Discovery.plugin_dirs_in/1`), never request input.
  # Inline rather than a line-pinned `.sobelow-skips` row: the fingerprint is
  # `type,file:line,HASH` and shifts on any edit above the call.
  # sobelow_skip ["Traversal.FileModule"]
  def parse_and_validate!(path) when is_binary(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> validate!()
  end

  defp normalize_errors(errors) do
    Enum.map(errors, fn
      %{error: error, path: path} ->
        %{path: to_string(path), message: format_error(error)}

      {message, path} when is_binary(message) ->
        %{path: to_string(path), message: message}

      other ->
        %{path: "#", message: inspect(other)}
    end)
  end

  defp format_error(%{__struct__: struct} = error) do
    case struct |> Module.split() |> List.last() do
      "Required" ->
        missing = Map.get(error, :missing) || []
        "missing required field(s): #{Enum.join(missing, ", ")}"

      "Pattern" ->
        "value does not match pattern #{inspect(Map.get(error, :expected))}"

      "Enum" ->
        "value is not one of #{inspect(Map.get(error, :enum))}"

      "Type" ->
        "expected type #{inspect(Map.get(error, :expected))}, got #{inspect(Map.get(error, :actual))}"

      "AdditionalProperties" ->
        "additional properties not allowed"

      _ ->
        inspect(error)
    end
  end

  defp format_error(other), do: inspect(other)
end
