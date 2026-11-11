defmodule BarkparkWeb.Studio.Desk.Text do
  @moduledoc """
  Is this binary text the database takes? The desk's one guard for bytes
  that come in from a URL or the browser.

  Postgres refuses a `text` value that is not UTF-8, and one that holds a NUL
  (22021 either way). Such bytes cannot be sent to the page either.
  """

  @doc "UTF-8 with no NUL in it."
  def text?(binary) when is_binary(binary),
    do: String.valid?(binary) and not String.contains?(binary, <<0>>)

  @doc """
  The pane splat as text only.

  The pane reader percent-decodes the splat. One whose decoded bytes are not
  text (`x%FF` is not UTF-8; `x%00` is a NUL) is kept as the text it spells
  instead: its "%" signs are escaped, so the reader hands them back as they
  stand. The router has decoded once already, so the splat itself may carry
  such a byte: it is spelled back as its escape first.
  """
  def text_only(splat) when is_binary(splat) do
    splat = if text?(splat), do: splat, else: spell(splat)
    if text?(URI.decode(splat)), do: splat, else: String.replace(splat, "%", "%25")
  end

  @doc """
  `binary` with every byte that is not text written as its percent escape.

  One pass that appends: the time it takes grows with the length, not with
  its square (a splat of 60,000 NULs took 434 ms when each byte was put in
  front of the rest).
  """
  def spell(binary) when is_binary(binary), do: spell(binary, <<>>)

  defp spell(<<0, rest::binary>>, out), do: spell(rest, <<out::binary, "%00">>)

  defp spell(<<char::utf8, rest::binary>>, out),
    do: spell(rest, <<out::binary, char::utf8>>)

  defp spell(<<byte, rest::binary>>, out),
    do: spell(rest, <<out::binary, ?%, Base.encode16(<<byte>>)::binary>>)

  defp spell(<<>>, out), do: out
end
