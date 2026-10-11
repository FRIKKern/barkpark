defmodule BarkparkWeb.AcceptLanguage do
  @moduledoc """
  The browser's language, for public pages that have no workspace of their own
  (lead ruling, run 8: the sign-in pages and the finder speak nb when the
  browser asks for it, English otherwise, never the Default workspace's
  locale).

  `locale/1` reads `Accept-Language` and answers the highest-q tag the Studio
  speaks (`nb`, `no`, `nn` → `"nb-NO"`; `en*` → `"en"`), ties in header order,
  `q=0` ignored, or `nil`. As a plug (`put_locale/2`) on a LiveView route: it
  puts that locale (or English) on the request for the static render and
  `<html lang>`, and stores it in the session as `"accept_locale"`, because a
  LiveView's connected mount cannot read request headers.
  """
  import Plug.Conn

  @session_key "accept_locale"

  @spec locale(Plug.Conn.t()) :: String.t() | nil
  def locale(conn) do
    conn
    |> get_req_header("accept-language")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.with_index()
    |> Enum.map(fn {part, i} ->
      [tag | params] = part |> String.trim() |> String.split(";")
      q = Enum.find_value(params, 1.0, &q_value/1)
      {tag |> String.trim() |> String.downcase(), q, i}
    end)
    |> Enum.sort_by(fn {_tag, q, i} -> {-q, i} end)
    |> Enum.find_value(fn {tag, q, _i} -> q > 0 and supported(tag) end)
  end

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts), do: put_locale(conn, opts)

  @doc "Put the browser's locale (or English) and remember it for the LiveView."
  def put_locale(conn, _opts) do
    locale = locale(conn) || Barkpark.Tenancy.default_locale()
    BarkparkWeb.StudioLocale.put_named(locale)
    put_session(conn, @session_key, locale)
  end

  @doc "The locale `put_locale/2` stored, for a LiveView's mount; English when absent."
  @spec from_session(map()) :: String.t()
  def from_session(session) when is_map(session),
    do: Map.get(session, @session_key) || Barkpark.Tenancy.default_locale()

  defp q_value(param) do
    with ["q", value] <- param |> String.trim() |> String.split("=", parts: 2),
         {q, _} <- Float.parse(value) do
      q
    else
      _ -> nil
    end
  end

  defp supported(tag) do
    cond do
      Regex.match?(~r/^(nb|no|nn)(-|$)/, tag) -> "nb-NO"
      Regex.match?(~r/^en(-|$)/, tag) -> "en"
      true -> nil
    end
  end
end
