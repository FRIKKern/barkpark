defmodule Barkpark.Plugins.Github.Signature do
  @moduledoc """
  Pure verifier for GitHub's `X-Hub-Signature-256` webhook header.

  GitHub signs each webhook delivery with an HMAC-SHA256 of the RAW request body
  keyed by the App's configured webhook secret, and sends it as:

      X-Hub-Signature-256: sha256=<lower-hex HMAC>

  This module is the inverse of the signing GitHub does — the same primitive the
  outbound `Barkpark.Webhooks.Dispatcher` uses (`:crypto.mac(:hmac, :sha256, …)`),
  read the other direction. It mounts NO route and NO plug: wave 3 wires the
  raw-body plug + webhook controller and calls `verify/3`. Keeping it pure keeps
  it trivially test-covered and free of request plumbing.

  ## Byte-exactness matters

  The HMAC is over the RAW bytes GitHub sent. The verifier MUST be handed those
  exact bytes — any re-encode (a JSON round-trip, a whitespace change) yields a
  different MAC and fails. Comparison is constant-time
  (`Plug.Crypto.secure_compare/2`) so a caller can't time-oracle the secret.

  ## Fail closed

  A `nil`/blank secret, a malformed header, or a non-binary body returns
  `{:error, :bad_signature}` — never a raise, never an accept. An empty-key HMAC
  is deterministic and forgeable by anyone, so a blank secret is treated as
  "cannot verify" rather than a match. "Blank" means blank AFTER trimming
  (matching `Barkpark.Webhooks.Dispatcher.blank_secret?/1`): a whitespace-only
  secret is a misconfiguration, not a usable key, so it also fails closed. The
  trim gates the blank DECISION only — a non-blank secret is HMAC'd with its
  exact bytes (leading/trailing whitespace included) so it matches whatever
  GitHub signed with.
  """

  @prefix "sha256="

  @doc """
  Sign `raw_body` the way GitHub does: `"sha256=" <> lower-hex HMAC-SHA256`.

  Exposed for test fixtures (and any caller that needs the canonical header value
  for a body it controls). Requires a non-blank binary secret.
  """
  @spec sign(binary(), binary()) :: String.t()
  def sign(raw_body, secret)
      when is_binary(raw_body) and is_binary(secret) and secret != "" do
    @prefix <> (:crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower))
  end

  @doc """
  Verify a GitHub `X-Hub-Signature-256` header against `raw_body` + `secret`.

  Returns `:ok` on an exact, constant-time match, else `{:error, :bad_signature}`.
  A tampered body, a wrong secret, a whitespace-different body, a malformed
  header, or a nil/blank/whitespace-only secret all fail closed.
  """
  @spec verify(binary(), String.t(), binary()) :: :ok | {:error, :bad_signature}
  def verify(raw_body, header, secret)
      when is_binary(raw_body) and is_binary(header) and is_binary(secret) do
    cond do
      # Blank AFTER trimming — a whitespace-only secret is a misconfiguration,
      # not a key. Gate the blank DECISION here, but HMAC below with the exact
      # (untrimmed) secret so a legitimately whitespace-bearing key still matches
      # GitHub's own signing bytes.
      String.trim(secret) == "" ->
        {:error, :bad_signature}

      Plug.Crypto.secure_compare(sign(raw_body, secret), header) ->
        :ok

      true ->
        {:error, :bad_signature}
    end
  end

  def verify(_raw_body, _header, _secret), do: {:error, :bad_signature}
end
