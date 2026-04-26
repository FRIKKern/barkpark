defmodule Barkpark.Content.Validation.Rule do
  @moduledoc """
  Compiled cross-field validation rule. Produced by
  `Barkpark.Content.Validation.Rules.compile/1` from raw JSON; consumed by
  `Barkpark.Content.Validation.Evaluator.run/3`.

  Decision D7 from `.doey/plans/masterplan-20260425-085425.md` is LOCKED:
  rules are an interpreted AST. There is NO `Code.eval_*`, no
  `Code.string_to_quoted` + `eval`, no macro evaluation. The struct fields
  below are plain data; the evaluator is a recursive interpreter.
  """

  defmodule Expr do
    @moduledoc """
    Path/Op/Value triple — the leaf node of a validation rule.

      * `path`  — JSON-Pointer-ish string with `/foo`, `/foo/0`, `/foo/*/bar`
                  resolved by `Barkpark.Content.Validation.Path.resolve/2`.
      * `op`    — atom (`:eq`, `:in`, `:nonempty`, `:contains_all`,
                  `:starts_with`) or `{:matches, checker_name}`.
      * `value` — RHS of the comparison, or args passed to a checker.
    """

    @enforce_keys [:path, :op]
    defstruct [:path, :op, :value]

    @type op ::
            :eq
            | :in
            | :nonempty
            | :contains_all
            | :starts_with
            | {:matches, String.t()}

    @type t :: %__MODULE__{
            path: String.t(),
            op: op(),
            value: term()
          }
  end

  @enforce_keys [:name, :severity, :when, :then]
  defstruct [:name, :severity, :message, :when, :then, :tags]

  @type severity :: :error | :warning | :info

  @type t :: %__MODULE__{
          name: String.t(),
          severity: severity(),
          message: String.t() | nil,
          when: Expr.t(),
          then: Expr.t(),
          tags: MapSet.t()
        }
end
