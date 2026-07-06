defmodule Barkpark.SelfUpdate.Client do
  @moduledoc """
  Behaviour for the self-update upstream client — the seam between the
  `Barkpark.SelfUpdate.Checker` and the outside world. The real
  implementation is `Barkpark.SelfUpdate.Client.GitHub` (Req against the
  GitHub REST API); tests swap in `Barkpark.SelfUpdate.Client.Fake` via
  config.exs/test.exs `client:` (mirroring the `:webhook_http_adapter`
  seam). Implementations MUST return `{:error, reason}` on any failure —
  never raise.
  """

  @doc """
  The latest upstream release: the numerically-largest `vA.B.C` tag on the
  repo, returned as `%{release: "A.B.C", tag: "vA.B.C"}`.
  """
  @callback latest_release(repo :: String.t()) ::
              {:ok, %{release: String.t(), tag: String.t()}} | {:error, term()}

  @doc """
  Commit digest between two tags — the first line of each commit message
  from `from_tag` (exclusive) to `to_tag` (inclusive), capped.
  """
  @callback digest(repo :: String.t(), from_tag :: String.t(), to_tag :: String.t()) ::
              {:ok, [String.t()]} | {:error, term()}

  @doc """
  Curated release notes for a tag (isu-w2): the human-authored release
  body plus its canonical URL, when a Release exists for `tag`. This is
  the CURATED counterpart to `digest/3`'s raw commit subjects — the
  release author (or the W3 curation agent) writes it. A tag with no
  Release is NOT an error: return `{:ok, %{body: nil, url: nil}}` so the
  caller cleanly falls back to the digest. MUST never raise.
  """
  @callback release_notes(repo :: String.t(), tag :: String.t()) ::
              {:ok, %{body: String.t() | nil, url: String.t() | nil}} | {:error, term()}
end
