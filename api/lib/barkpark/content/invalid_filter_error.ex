defmodule Barkpark.Content.InvalidFilterError do
  @moduledoc """
  The query builder's ONE typed refusal: this filter clause has no SQL arm.

  It lives beside `Barkpark.Content.Errors` because the refusal and the envelope
  it becomes are one fact — `Errors.build/1` carries the matching
  `%{code: "invalid_filter", status: 400}` clause a few hundred lines up.

  ## Why it exists

  `Barkpark.Content.Query.apply_field_op/4` used to end in a catch-all that
  returned the query UNCHANGED, and `hasStrong`'s parser had an `:error -> query`
  arm doing the same. Both made an unsupported or malformed clause VANISH, so the
  caller got the UNFILTERED set while believing it had filtered — the silent
  over-return class (Gyldendal field report #2b). One HTTP door
  (`QueryController`'s `invalid_filter_op/1` guard) checked for it up front; every
  other door — Studio's PaneBuilder, structure/plugin desk filters, internal
  reads — had no guard at all.

  The refusal now lives at the CHOKEPOINT (`Query.apply_filter_map/2`, which every
  read reaches through `base_query/4`), so a door added later inherits the
  refusal instead of inheriting the silence by omission.

  ## The field name is deliberately NOT in the user-facing envelope

  `QueryController` runs `forbidden_query_field/4` — the field-visibility gate —
  BEFORE the query is built. A refusal raised from INSIDE the builder does not
  inherit that ordering: it can fire for a field the gate would have rejected, and
  at internal doors the gate never ran at all. Rather than re-derive that ordering
  at every door, this envelope names the OP (which is what the caller must fix)
  plus the accepted operator vocabulary, and never echoes the FIELD. The field is
  retained on the struct for logs and for callers that shape their own message
  behind an authorization boundary (`SchemaDefinition`'s desk-group validation,
  an admin write path).

  The `Plug.Exception` implementation is the backstop for a door that does not
  rescue: an unsupported filter is a 400, never a 500 — it is never a server fault.
  """

  defexception [:field, :op, :message]

  @type t :: %__MODULE__{field: term(), op: term(), message: String.t()}

  @doc """
  Build the refusal for `op` on `field`. `field` rides on the struct but never
  reaches the message (see the moduledoc).
  """
  @spec new(term(), term()) :: t()
  def new(field, op) do
    %__MODULE__{
      field: field,
      op: op,
      message:
        "unsupported filter operator #{inspect(op)}; valid operators: " <>
          "eq, neq, in, nin, has, hasStrong, contains, startsWith, endsWith, " <>
          "gt, gte, lt, lte, is"
    }
  end
end

defimpl Plug.Exception, for: Barkpark.Content.InvalidFilterError do
  def status(_e), do: 400
  def actions(_e), do: []
end
