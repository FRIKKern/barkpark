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

  # ── Request-body list ceilings ─────────────────────────────────────────────
  #
  # The PATCH `Operations` array and the `/Groups` `members` array were bounded
  # at NEITHER end while the numeric query parameters next door were bounded at
  # both. Each element of either list is walked individually — an `Operations`
  # element by `classify/1` and again by `ScimUsersController.deactivating?/1`,
  # a `members` element by `Barkpark.Scim.add_group_member/3` — so the request
  # body alone chose how much work one authenticated SCIM bearer could buy.
  #
  # WHY 1_000, AND WHAT IT IS DERIVED FROM. The honest answer is that no IdP
  # documents a per-request ceiling for what it SENDS, so the bound is derived
  # from the largest legitimate request the ecosystem's own documents sanction,
  # then set well above it:
  #
  #   * Okta's SCIM 2.0 guide explicitly sanctions a FULL-membership push —
  #     `{"op":"replace","path":"members","value":[…]}`, "This operation
  #     replaces all the group members with the supplied object values" — and
  #     states no maximum member count anywhere. Its LIST paging, by contrast,
  #     is documented at `count=100`. That is the only documented number Okta
  #     gives for a batch of SCIM resources.
  #     https://developer.okta.com/docs/api/openapi/okta-scim/guides/scim-20/
  #   * Microsoft Entra ID does NOT document how many members its provisioning
  #     service sends per outbound PATCH. The one member ceiling Microsoft does
  #     publish runs the OPPOSITE direction — Entra acting as the service
  #     PROVIDER caps a client at "up to only 20 members" per add — so it is
  #     evidence of the order of magnitude the ecosystem treats as normal, not
  #     a claim about what Entra sends us.
  #     https://learn.microsoft.com/en-us/entra/identity/app-provisioning/entra-id-scim-api-reference
  #   * RFC 7644 §3.12 Table 8's own worked 413 row carries the literal
  #     `{"maxOperations": 1000, "maxPayloadSize": 1048576}` — the spec's own
  #     illustrative operation ceiling for a batched request.
  #   * This server already advertises `@max_page` = 200 (RFC 7644 §3.4.2.4) as
  #     the largest set of resources it will hand back in one response.
  #
  # 1_000 is 10x Okta's documented batch, 50x Entra's published member cap, 5x
  # this server's own page ceiling, and equal to the RFC's illustrative
  # `maxOperations`. THE TRADE-OFF, recorded rather than hidden: an Okta
  # full-membership replace of a group with more than 1_000 members WILL now be
  # refused, with a 400 naming the ceiling, where before it was accepted. That
  # is the intended behaviour — such a group must be reconciled in pages — and
  # it is why the refusal names the limit instead of failing opaquely.
  @max_operations 1_000
  @max_members 1_000

  @doc """
  The ceiling on a PATCH body's `Operations` array. Exposed so a route-driven
  test can name the bound instead of hard-coding a magic number.
  """
  def max_operations, do: @max_operations

  @doc """
  The ceiling on the TOTAL number of `members` entries in one `/Groups` request.
  Exposed so a route-driven test can name the bound.
  """
  def max_members, do: @max_members

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
  def classify(%{"Operations" => ops}) when is_list(ops) and length(ops) > @max_operations do
    {:error, "invalidValue",
     "the Operations array carries #{length(ops)} operations; this server accepts at most " <>
       "#{@max_operations} in one request"}
  end

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

  @doc """
  Refuse a `/Groups` write whose TOTAL member count exceeds `max_members/0`.

  The ceiling is on the REQUEST, not on one operation. Every `members` entry in
  a body — a top-level array on POST/PUT, a path-less whole-resource replace's
  `members`, and each path-keyed member operation's `value` — is resolved one id
  at a time by `Barkpark.Scim.add_group_member/3`, so a PER-OPERATION bound
  would be defeated by splitting the same list across two operations and would
  buy the caller exactly the work the bound exists to refuse.

  Returns `:ok`, or the same `{:error, scim_type, detail}` shape `classify/1`
  returns, so a caller renders both refusals through one clause.
  """
  @spec check_member_total(non_neg_integer()) :: :ok | {:error, String.t(), String.t()}
  def check_member_total(n) when is_integer(n) and n > @max_members do
    {:error, "invalidValue",
     "the request carries #{n} members entries; this server accepts at most " <>
       "#{@max_members} in one request"}
  end

  def check_member_total(n) when is_integer(n), do: :ok

  @doc """
  The number of entries in a SCIM `members` value. A non-list (absent, null, a
  scalar) carries no members — the same reading `member_ids/1` gives it.
  """
  @spec member_count(term()) :: non_neg_integer()
  def member_count(members) when is_list(members), do: length(members)
  def member_count(_), do: 0
end
