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
end
