defmodule BarkparkWeb.ParamCoercion do
  @moduledoc """
  The single, shared query-param coercion seam for the HTTP controllers.

  Phoenix's `Plug.Conn.Query` parser turns `?q[]=a&q[]=b` into a LIST and
  `?q[k]=v` into a MAP. A controller that then pattern-matches or casts that
  value assuming it is a binary — `String.split/2`, an Ecto `d.type == ^type`,
  a `<<_>>`-headed function clause — raises `FunctionClauseError` /
  `Ecto.CastError`, and the request 500s instead of returning a clean 4xx.
  (Same family as the `binary_id` CastError guard on `Repo.get`.)

  `bin/1` collapses every non-binary shape to `nil` — the "param absent"
  sentinel that every downstream param builder already handles — so a hostile
  or malformed query degrades to the missing-param path rather than crashing.

  It is the one owner of this coercion: the `defp bin/1` copies that had begun
  to accrete per-controller (`SearchController`, `FederatedSearchController`)
  are replaced by an import of this module. A new controller that needs to read
  a scalar query param imports `bin/1` here rather than re-hand-rolling it, so
  the guard can never silently drift or be forgotten at a fresh call site.
  """

  @doc """
  Coerce a raw query-param value to a binary, or `nil` for any non-binary
  shape (list, map, integer, …). `nil` is the universal "absent" sentinel the
  downstream param builders already treat as "no value".

      iex> BarkparkWeb.ParamCoercion.bin("post")
      "post"
      iex> BarkparkWeb.ParamCoercion.bin(["a", "b"])
      nil
      iex> BarkparkWeb.ParamCoercion.bin(%{"k" => "v"})
      nil
      iex> BarkparkWeb.ParamCoercion.bin(nil)
      nil
      iex> BarkparkWeb.ParamCoercion.bin(42)
      nil
  """
  @spec bin(term()) :: binary() | nil
  def bin(v) when is_binary(v), do: v
  def bin(_), do: nil
end
