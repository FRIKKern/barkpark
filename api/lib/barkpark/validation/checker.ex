defmodule Barkpark.Validation.Checker do
  @moduledoc """
  Behaviour for value checkers consumed by the
  `Barkpark.Content.Validation.Ops` `{:matches, name}` op.

  Implementations are pure: they take a value and an args term and return
  `:ok` or `{:error, code}`. The `code` is surfaced verbatim by the
  evaluator into the violation `code` field for WI2's error envelope.

  Built-in checkers live under `Barkpark.Validation.Checkers.*`. Plugins
  register their own via the `Barkpark.Plugin` `checkers/0` callback —
  they are looked up under the namespaced name `plugin:<name>:<checker>`.
  """

  @typedoc "Stable error reason returned by a checker on failure."
  @type reason :: atom() | String.t()

  @typedoc "Checker-specific parameters resolved from rule DSL frontmatter."
  @type params :: map()

  @callback check(value :: term(), args :: term()) :: :ok | {:error, reason()}
end
