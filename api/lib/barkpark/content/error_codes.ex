defmodule Barkpark.Content.ErrorCodes do
  @moduledoc """
  Compile-time registry of validation error codes used by the Phase 3
  cross-field rule evaluator (WI1) and the v2 error envelope (WI2).

  Each registered code carries:

  * `:message_template` — human-readable default message (with `%{var}`
    interpolation slots that callers may fill via `render/2`).
  * `:default_severity` — `:error`, `:warning`, or `:info`.
  * `:since_version` — minor version when the code was introduced. Used by
    SDK clients that want to gracefully degrade on unknown codes.
  """

  @registry %{
    required: %{
      message_template: "Required",
      default_severity: :error,
      since_version: "0.3.0"
    },
    nilable_violation: %{
      message_template: "Value cannot be null",
      default_severity: :error,
      since_version: "0.3.0"
    },
    one_of: %{
      message_template: "Must match exactly one of the allowed shapes",
      default_severity: :error,
      since_version: "0.3.0"
    },
    in_violation: %{
      message_template: "Value not in allowed set",
      default_severity: :error,
      since_version: "0.3.0"
    },
    nonempty_violation: %{
      message_template: "Must not be empty",
      default_severity: :error,
      since_version: "0.3.0"
    },
    max_items: %{
      message_template: "Too many items (max %{max})",
      default_severity: :error,
      since_version: "0.3.0"
    },
    checker_failed: %{
      message_template: "Checker %{name} failed",
      default_severity: :error,
      since_version: "0.3.0"
    },
    type_mismatch: %{
      message_template: "Expected %{expected}",
      default_severity: :error,
      since_version: "0.3.0"
    },
    codelist_unknown: %{
      message_template: "Unknown codelist value",
      default_severity: :error,
      since_version: "0.3.0"
    },
    codelist_version_mismatch: %{
      message_template: "Codelist value not in pinned issue %{issue}",
      default_severity: :error,
      since_version: "0.3.0"
    },
    unknown_field: %{
      message_template: "Unknown field",
      default_severity: :warning,
      since_version: "0.3.0"
    }
  }

  @codes Map.keys(@registry)

  @spec all() :: [atom()]
  def all, do: @codes

  @spec lookup(atom()) :: {:ok, map()} | :error
  def lookup(code) when is_atom(code) do
    case Map.fetch(@registry, code) do
      {:ok, entry} -> {:ok, entry}
      :error -> :error
    end
  end

  def lookup(_), do: :error

  @doc """
  Render a registered code's message template with the supplied bindings.
  Unrecognised codes fall back to `to_string(code)`.
  """
  @spec render(atom(), map()) :: String.t()
  def render(code, bindings \\ %{})

  def render(code, bindings) when is_atom(code) and is_map(bindings) do
    case lookup(code) do
      {:ok, %{message_template: tmpl}} -> interpolate(tmpl, bindings)
      :error -> to_string(code)
    end
  end

  defp interpolate(tmpl, bindings) when is_binary(tmpl) do
    Enum.reduce(bindings, tmpl, fn {k, v}, acc ->
      String.replace(acc, "%{#{k}}", to_string(v))
    end)
  end
end
