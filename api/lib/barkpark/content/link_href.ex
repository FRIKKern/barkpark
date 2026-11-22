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
  """

  alias Barkpark.PortableDoc.Render.Util

  @doc "Whether a link may carry `href`."
  @spec allowed?(term()) :: boolean()
  def allowed?(href) when is_binary(href),
    do:
      Util.safe_url(href) != "#" or
        Regex.match?(~r/^[\x{00}-\x{20}\x{7F}-\x{9F}]*#[\x{00}-\x{1F}\x{7F}-\x{9F}]*$/u, href)

  def allowed?(_href), do: false
end
