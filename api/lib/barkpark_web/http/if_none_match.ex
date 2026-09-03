defmodule BarkparkWeb.Http.IfNoneMatch do
  @moduledoc """
  The one `If-None-Match` matcher (charter D11).

  RFC 9110 §13.1.2 in one place: fold EVERY `if-none-match` header line, split
  each on commas, trim, drop empty entries, honour the `*` wildcard, and compare
  every remaining entry to the validator we are about to serve using the WEAK
  comparison function — `W/` stripped on both sides, then byte-equal on what is
  left, quotes INCLUDED.

  Four call sites used to carry three different semantics:

    * `CapabilitiesController` / `OpenApiController` — exact compare, first line
      only. Both emit `W/"…"`, so a client sending the strong form `"caps-…"`
      got a spurious 200.
    * `QueryController` — first line only, and it stripped `W/` AND the quotes
      off the CLIENT entry before comparing it to an UNQUOTED validator. That
      made a bare, unquoted token match a quoted ETag we never emitted.
    * `PaperRevisionHeaders` — already D11-correct; this module is its
      extraction.

  Direction of every unification: toward RFC conformance. A 304 may only be
  granted on a validator this server emitted (weak-or-strong equal); a mismatch
  can only cost a re-render (200), never serve stale bytes.

  Pass the etag EXACTLY as it goes onto the wire — including its surrounding
  quotes. `IfNoneMatch.match?(conn, ~s("\#{validator}"))`, never the bare
  validator: the entity-tag is the quoted string, and a comparison that ignores
  the quotes accepts tokens the server never sent.
  """

  alias Plug.Conn

  @doc """
  True when the request's `If-None-Match` selects `etag` (or carries `*`).

  `etag` is the exact header value being served, quotes and any `W/` prefix
  included.
  """
  # @canonical capability:if-none-match-compare aka:etag_matches,if_none_match,inm,conditional 304,weak compare
  def match?(%Conn{} = conn, etag) when is_binary(etag) do
    conn
    |> Conn.get_req_header("if-none-match")
    |> candidates()
    |> Enum.any?(fn candidate ->
      candidate == "*" or strip_weak(candidate) == strip_weak(etag)
    end)
  end

  @doc """
  The parsed entity-tag list carried by the given raw header values.

  Exposed for callers that already hold the header lines (and for the unit
  suite); `match?/2` is the normal entry point.
  """
  def candidates(values) when is_list(values) do
    values
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_weak("W/" <> opaque_tag), do: opaque_tag
  defp strip_weak(opaque_tag), do: opaque_tag
end
