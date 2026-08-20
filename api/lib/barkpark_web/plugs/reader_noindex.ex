defmodule BarkparkWeb.Plugs.ReaderNoindex do
  @moduledoc """
  `x-robots-tag: noindex` on every public reader response (papers, sheets,
  quiz — the `:public_root` surface — plus the scoped paper reader).

  Papers are shareable, not searchable, out of the box (am-hg-ai-crawler-stance,
  user-ratified 2026-08-09): a public paper is reachable by anyone holding the
  link — and by user-initiated fetchers following one — but is not offered to
  search indexes. The header is the reliable de-indexing tool where robots.txt
  is not: a `Disallow` alone still permits link-only indexing AND hides this
  header from the crawler, so crawling stays allowed and the header does the
  refusing. Bulk-training crawlers are refused separately in robots.txt; the
  E2 limiter is the enforcement for impolite ones.

  Mounted BEFORE `PaperRevisionHeaders` in both reader pipelines so the header
  is already on the conn when the conditional 304 halts — the 304 then carries
  it (and RFC 9111 §3.2 merge semantics retain the stored 200's copy anyway).

  `noindex` only — no `nofollow`: link discovery through papers is harmless
  once the pages themselves are unindexed, and og/link previews are unaffected.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    put_resp_header(conn, "x-robots-tag", "noindex")
  end
end
