defmodule BarkparkWeb.ScimPatch do
  @moduledoc """
  One reader for a SCIM 2.0 `PATCH` body's `Operations` array (RFC 7644 §3.5.2).

  Both `ScimUsersController` and `ScimGroupsController` used to walk
  `params["Operations"]` themselves, and both only ever looked at operations
  that carried a `path`. Azure AD does not always send one: it pushes a
  **path-less `replace`** whose `value` is the WHOLE resource —

      {"schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
       "Operations": [{"op": "replace",
                       "value": {"active": false, "displayName": "Admins"}}]}

  — which every path-keyed reader silently dropped, answering `200 OK` for a
  mutation it never performed. RFC 7644 §3.5.2.3 defines exactly this shape:
  "If 'path' is omitted, the target location is assumed to be the resource
  itself. The 'value' parameter SHALL contain a list of attributes to be
  replaced." §3.5.2.2 says the mirror thing about `add`, so both are folded into
  the same whole-resource map here.

  `classify/1` splits an `Operations` array into

    * `:whole_resource` — the merged attribute map of every path-less
      `add`/`replace` (nil when there is none), and
    * `:ops` — every remaining operation, untouched, for the caller's existing
      path-keyed handling.

  ## What stays permissive on purpose

  A non-list `Operations`, or a scalar element inside it, is DROPPED, not
  refused — `scim_{users,groups}_controller_test.exs` pin that as `200`
  (element-shape class: the old readers raised `FunctionClauseError` in
  `Access.get/3` and returned a generic 500, and the fix was to drop, not to
  reject). This module only refuses shapes that were previously a silent no-op
  and that RFC 7644 declares invalid outright:

    * a path-less `add`/`replace` whose `value` is missing or is not an object
      → `invalidSyntax` (there is no attribute map to apply);
    * a path-less `remove` → `noTarget` (§3.5.2.2: `path` is REQUIRED for
      `remove`).

  Both are decided BEFORE the caller writes anything, so a refused PATCH leaves
  no partial write behind.
  """

  @type op :: map()
  @type patch :: %{whole_resource: map() | nil, ops: [op()]}

  @doc """
  Split a PATCH body's `Operations` into a whole-resource attribute map plus the
  path-keyed operations the caller still handles itself.

  Returns `{:ok, %{whole_resource: map | nil, ops: [map]}}`, or
  `{:error, scim_type, detail}` where `scim_type` is the RFC 7644 §3.12 keyword
  the caller renders into a SCIM Error (`"invalidSyntax"` / `"noTarget"`).

  A body with no `Operations` at all (a `PUT`, or a bare-field `PATCH`) is
  `{:ok, %{whole_resource: nil, ops: []}}` — never an error.
  """
  @spec classify(map()) :: {:ok, patch()} | {:error, String.t(), String.t()}
  def classify(%{"Operations" => ops}) when is_list(ops) do
    ops
    |> Enum.filter(&is_map/1)
    |> Enum.reduce_while({nil, []}, fn op, {whole, rest} ->
      case pathless(op) do
        :no -> {:cont, {whole, rest ++ [op]}}
        {:ok, value} -> {:cont, {Map.merge(whole || %{}, value), rest}}
        {:error, _, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:error, _, _} = err -> err
      {whole, rest} -> {:ok, %{whole_resource: whole, ops: rest}}
    end
  end

  def classify(_params), do: {:ok, %{whole_resource: nil, ops: []}}

  # `:no` — the operation carries a usable `path`, or an `op` verb this module
  # has no opinion about; the caller's own path-keyed reader owns it.
  defp pathless(op) do
    if targeted?(op["path"]) do
      :no
    else
      case verb(op) do
        v when v in ["replace", "add"] -> value_object(op, v)
        "remove" -> {:error, "noTarget", "a path-less `remove` operation has no target"}
        _ -> :no
      end
    end
  end

  # A `path` is a target only when it is a non-blank string. Anything else
  # (absent, null, a number, a list) is "no target given" — the same reading the
  # old `String.downcase(to_string(op["path"] || ""))` comparisons produced.
  defp targeted?(path) when is_binary(path), do: String.trim(path) != ""
  defp targeted?(_), do: false

  # `op["op"]` is IdP-supplied: a non-string verb must not reach `to_string/1`
  # (a map or list raises Protocol.UndefinedError → a 500 instead of an answer).
  defp verb(op) do
    case op["op"] do
      v when is_binary(v) -> v |> String.trim() |> String.downcase()
      _ -> ""
    end
  end

  defp value_object(op, verb) do
    case Map.fetch(op, "value") do
      {:ok, value} when is_map(value) ->
        {:ok, value}

      _ ->
        {:error, "invalidSyntax",
         "a path-less `#{verb}` operation requires an object `value` naming the attributes to set"}
    end
  end
end
