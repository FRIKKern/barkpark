defmodule Barkpark.Content.LinkHref do
  @moduledoc """
  The addresses a link in a rich text field may carry (task-e1584dc1f1516991):
  http, https, mailto, tel, a root-relative, `./` or `../` path, a `?` query,
  and an in-document `#` address (`#internal:<id>` too). Anything else (a
  `javascript:`, `vbscript:` or `data:` address in any case or spacing, a
  protocol-relative `//host`, a bare word) is refused.

  It is the reader's allowlist, `Barkpark.PortableDoc.Render.Util.safe_url/1`,
  so the Studio's rich text and the Paper reader refuse the same addresses.
  TanStack's rich text field does the same (`app/src/lib/link-href.ts`): a
  refused address is never linked, and a stored one is drawn as its words.

  The check reads the address as a browser would: control characters are
  removed from the whole string first (a browser drops a tab or a newline
  anywhere in a URL, so `jav<TAB>ascript:` is `javascript:`).

  On a write the rule is narrower (`write_refused?/1`, task-b923a915151d2038
  r2): only an address that can run script, `javascript:`, `vbscript:` or
  `data:`, is refused. Anything else is stored as given (no scheme, blank,
  `sms:`, `ftp:`), and drawing still takes only the allowlist above. Both
  read the address through `normalise/1`.
  """

  alias Barkpark.PortableDoc.Render.Util

  @write_refused ~w(javascript: vbscript: data:)

  @doc "Whether a link may carry `href`."
  @spec allowed?(term()) :: boolean()
  def allowed?(href) when is_binary(href),
    do:
      not write_refused?(href) and
        (Util.safe_url(href) != "#" or
           Regex.match?(~r/^[\x{00}-\x{20}\x{7F}-\x{9F}]*#[\x{00}-\x{1F}\x{7F}-\x{9F}]*$/u, href))

  def allowed?(_href), do: false

  @doc """
  Whether a write may not store `href` in a link: its scheme, read through
  `normalise/1`, is `javascript:`, `vbscript:` or `data:`.
  """
  @spec write_refused?(term()) :: boolean()
  def write_refused?(href) when is_binary(href),
    do: String.starts_with?(normalise(href), @write_refused)

  def write_refused?(_href), do: false

  @doc """
  The address as its scheme is read: HTML character references decoded
  (`&#106;`, `&#x6A;`, `&colon;`, `&Tab;`, `&NewLine;`), every control
  character and whitespace removed, lower-cased.
  """
  @spec normalise(String.t()) :: String.t()
  def normalise(href) when is_binary(href) do
    href
    |> decode_refs()
    |> String.replace(~r/[\x{00}-\x{20}\x{7F}-\x{9F}\s]/u, "")
    |> String.downcase()
  end

  defp decode_refs(s) do
    Regex.replace(~r/&(#[xX][0-9a-fA-F]+|#[0-9]+|colon|tab|newline);?/i, s, fn whole, ref ->
      case String.downcase(ref) do
        "colon" -> ":"
        "tab" -> "\t"
        "newline" -> "\n"
        "#x" <> hex -> char(Integer.parse(hex, 16), whole)
        "#" <> dec -> char(Integer.parse(dec), whole)
      end
    end)
  end

  defp char({n, ""}, _whole) when n in 0..0x10FFFF and n not in 0xD800..0xDFFF, do: <<n::utf8>>
  defp char(_parsed, whole), do: whole
end
