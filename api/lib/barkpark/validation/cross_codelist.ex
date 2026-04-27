defmodule Barkpark.Validation.CrossCodelist do
  @moduledoc """
  Cross-field codelist consistency helper.

  Some validation rules involve TWO codelist-pinned fields where the value of
  one (the *driver*) constrains the allowed values of the other (the
  *dependent*). Canonical example from ONIX:

      ProductFormCode "BB" (Hardback) ⇒ requires PageCount > 0
      ProductFormCode "EA" (Digital)  ⇒ permits PageCount == 0

  Mappings are data-driven so Phase 4 (OnixEdit) can ship them as a flat
  table without changing the engine. v1 accepts an in-memory map; later
  iterations can swap in a `mappings` table behind the same API.

  ## Mapping shape

      %{
        driver_value => dependent_predicate
      }

  where `dependent_predicate` is one of:

    * `{:in, [allowed_value, …]}` — dependent value must be in the list
    * `{:not_in, [forbidden_value, …]}`
    * `{:gt, n}` / `{:gte, n}` / `{:lt, n}` / `{:lte, n}` — numeric guards
    * `{:any, [predicate, …]}` — at least one predicate must hold
    * `{:all, [predicate, …]}` — every predicate must hold
    * `:any` — any dependent value is allowed (acts as documentation)

  Driver values not present in the mapping are considered unconstrained and
  return `true` (no opinion). Use `{:in, ...}` with a closed enumeration of
  driver values if you want strict whitelisting; the rule DSL’s
  `codelist_ref` checker is the right place to enforce that, not this
  helper.
  """

  @typedoc "Dotted field path: e.g. `\"product.formCode\"` or `[\"product\", \"formCode\"]`."
  @type field_path :: String.t() | [String.t()]

  @typedoc "Predicate the dependent value must satisfy when the driver matches."
  @type predicate ::
          :any
          | {:in, [term()]}
          | {:not_in, [term()]}
          | {:gt, number()}
          | {:gte, number()}
          | {:lt, number()}
          | {:lte, number()}
          | {:any, [predicate()]}
          | {:all, [predicate()]}

  @typedoc "Driver-value to dependent-predicate map."
  @type mapping :: %{optional(term()) => predicate()}

  @typedoc "Spec passed to `consistent?/2`."
  @type spec :: %{
          required(:driver_field) => field_path(),
          required(:dependent_field) => field_path(),
          required(:mapping) => mapping()
        }

  @doc """
  Returns `true` when the dependent field is consistent with the driver
  field under the supplied mapping, `false` otherwise.

  Missing fields (nil at either end) and driver values absent from the
  mapping are treated as consistent — surface presence as a separate rule.
  """
  @spec consistent?(map(), spec()) :: boolean()
  def consistent?(doc, %{
        driver_field: driver_path,
        dependent_field: dependent_path,
        mapping: mapping
      })
      when is_map(doc) and is_map(mapping) do
    driver = fetch_field(doc, driver_path)
    dependent = fetch_field(doc, dependent_path)

    cond do
      is_nil(driver) -> true
      is_nil(dependent) -> true
      not Map.has_key?(mapping, driver) -> true
      true -> matches?(dependent, Map.fetch!(mapping, driver))
    end
  end

  # ── Field lookup ───────────────────────────────────────────────────────

  defp fetch_field(doc, path) when is_binary(path) do
    fetch_field(doc, String.split(path, "."))
  end

  defp fetch_field(doc, []), do: doc

  defp fetch_field(doc, [head | rest]) when is_map(doc) do
    case Map.get(doc, head) do
      nil -> nil
      next -> fetch_field(next, rest)
    end
  end

  defp fetch_field(_other, _path), do: nil

  # ── Predicates ─────────────────────────────────────────────────────────

  defp matches?(_value, :any), do: true
  defp matches?(value, {:in, list}) when is_list(list), do: value in list
  defp matches?(value, {:not_in, list}) when is_list(list), do: value not in list

  defp matches?(value, {:gt, n}) when is_number(value) and is_number(n), do: value > n
  defp matches?(value, {:gte, n}) when is_number(value) and is_number(n), do: value >= n
  defp matches?(value, {:lt, n}) when is_number(value) and is_number(n), do: value < n
  defp matches?(value, {:lte, n}) when is_number(value) and is_number(n), do: value <= n

  defp matches?(value, {:any, preds}) when is_list(preds),
    do: Enum.any?(preds, &matches?(value, &1))

  defp matches?(value, {:all, preds}) when is_list(preds),
    do: Enum.all?(preds, &matches?(value, &1))

  defp matches?(_value, _predicate), do: false
end
