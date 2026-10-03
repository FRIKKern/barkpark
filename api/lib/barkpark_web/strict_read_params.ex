defmodule BarkparkWeb.StrictReadParams do
  @moduledoc """
  Refuses malformed `?limit`, `?offset` and `?expand` on the document read
  routes — `GET /v1/data/query/…`, `GET /v1/data/doc/…` and
  `GET /v1/data/history/…` — with the §9 `malformed` 400 that names the
  parameter (owner ruling #53, 2026-10-03; task-cf3ace9b87b9f98d and
  task-e47dff813dab414f).

  Before this, `?limit=abc` answered 200 with the default page (100 on query,
  50 on history), `?offset=abc` read as the first page, and `?expand=bogus`
  answered 200 with nothing expanded. A typo looked like it had worked (D75),
  while `?perspective` and `?order` on the same routes already refused junk.

  WHAT STAYS LENIENT, ON PURPOSE. An integer outside the documented range is
  still CLAMPED, as api-v1 §4 and the history contract say: `limit=0` reads as
  1, `limit=5000` as the route maximum, `offset=-5` as 0. Those requests are
  well-formed and the clamp is visible in the echoed `limit`/`offset`. Only a
  value that is not an integer at all is refused.

  The envelope matches `BarkparkWeb.ReadPerspective.refuse/4`:
  `details: %{parameter: …, received: …}` plus what the route accepts.
  """

  alias BarkparkWeb.ErrorResponse

  @int_re ~r/\A[+-]?\d+\z/

  @expand_hint "Name only fields listed in details.expandable, send ?expand=true for all of them, or leave ?expand out."

  @doc """
  The first of `keys` whose value is present but not an integer, as
  `{key, value}`, or `nil`. A list- or map-shaped value (`?limit[]=1`) counts
  as not an integer.
  """
  @spec malformed_int(map(), [String.t()]) :: nil | {String.t(), term()}
  def malformed_int(params, keys) when is_map(params) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(params, key) do
        nil ->
          nil

        value when is_integer(value) ->
          nil

        value when is_binary(value) ->
          if Regex.match?(@int_re, value), do: nil, else: {key, value}

        other ->
          {key, other}
      end
    end)
  end

  @doc "Emit the 400 for a non-integer `?limit` / `?offset`."
  @spec refuse_int(Plug.Conn.t(), {String.t(), term()}) :: Plug.Conn.t()
  def refuse_int(conn, {key, value}) do
    ErrorResponse.emit_custom(
      conn,
      400,
      "malformed",
      "?#{key}= must be a whole number; received #{inspect(value)}",
      %{parameter: key, received: value, expected: "integer"},
      "Send ?#{key}= as a whole number (out-of-range values are clamped), or leave it out for the default."
    )
  end

  @doc """
  Emit the 400 for `?expand` naming fields that are not reference fields on
  the type (`unknown`), or for a list/map-shaped `?expand` (`unknown == nil`).
  `expandable` lists the reference fields the type does have, so the caller
  can fix the typo in one hop.
  """
  @spec refuse_expand(Plug.Conn.t(), term(), [String.t()] | nil, [String.t()]) :: Plug.Conn.t()
  def refuse_expand(conn, received, nil, expandable) do
    ErrorResponse.emit_custom(
      conn,
      400,
      "malformed",
      "?expand= must be true, false, or a comma-separated list of reference fields; " <>
        "received #{inspect(received)}",
      %{parameter: "expand", received: received, expandable: expandable},
      @expand_hint
    )
  end

  def refuse_expand(conn, received, unknown, expandable) when is_list(unknown) do
    ErrorResponse.emit_custom(
      conn,
      400,
      "malformed",
      "?expand= names #{Enum.map_join(unknown, ", ", &inspect/1)}, which " <>
        if(length(unknown) == 1, do: "is not a reference field", else: "are not reference fields") <>
        " on this type. " <>
        case expandable do
          [] -> "This type has no reference fields to expand."
          fields -> "Expandable fields: #{Enum.join(fields, ", ")}."
        end,
      %{parameter: "expand", received: received, unknown: unknown, expandable: expandable},
      @expand_hint
    )
  end
end
