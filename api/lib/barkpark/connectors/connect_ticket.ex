defmodule Barkpark.Connectors.ConnectTicket do
  @moduledoc """
  The signed CONNECT TICKET (Connectors D50) — the ONE thing that authorizes a
  Studio-initiated connect against the bridge's loopback seam.

  ## The wire, byte-exact

      payload = {"w":"<workspace uuid>","p":"<provider>","n":"<nonce>","t":<issued_at_ms>}
      ticket  = base64url(payload) "." base64url(HMAC-SHA256(secret, base64url(payload)))

  No padding. **EXACT key order `w,p,n,t`, no spaces.** The payload string is
  BUILT, not `Jason.encode`d — map key order is an implementation detail of the
  encoder and the bridge signs the bytes, not the map. Two languages, one string.

  ## The golden vector

  The bridge (`connectors/src/connect/ticket.ts`) pins the SAME vector. A
  cross-language mismatch would 401 every connect attempt and NOTHING else would
  catch it — the Elixir suite would be green, the bridge suite would be green,
  and the product would be broken. Hence:

      secret "golden-connect-secret", w "11111111-2222-3333-4444-555555555555",
      p "telegram", n "0123456789abcdef", t 1752480000000
      => eyJ3IjoiMTExMTExMTEtMjIyMi0zMzMzLTQ0NDQtNTU1NTU1NTU1NTU1IiwicCI6InRlbGVncmFtIiwibiI6IjAxMjM0NTY3ODlhYmNkZWYiLCJ0IjoxNzUyNDgwMDAwMDAwfQ.lKEgXtxTstQoQlBxCdvvPhY23Cq0reI9BHzzPzpdxO0

  Asserted in `test/barkpark/connectors/connect_ticket_test.exs`.

  ## What the ticket is NOT

  It is not a secret container. The payload is base64url JSON and DELIBERATELY
  readable — it carries a workspace id the operator already knows. The raw chat
  token and the pasted provider credential ride the POST BODY over LOOPBACK
  (`127.0.0.1`, same box as the BEAM), never the ticket, never a URL, never an
  OAuth `state`.

  ## Fail-closed inputs

  `sign/3` refuses anything that is not a UUID workspace id or a
  `[a-z0-9_-]+` provider id. The payload is hand-assembled, so an unvalidated
  input would be a JSON-injection seam; there is no escaping path here, only a
  refusal.
  """

  @ttl_ms 600_000

  @uuid_re ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @provider_re ~r/\A[a-z0-9_-]{1,64}\z/

  @doc "The ticket TTL the bridge enforces (ms). Exposed so tests pin ONE number."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc """
  Sign a connect ticket for `workspace_id` + `provider`.

  Options (tests only — production passes none):

    * `:secret` — override the configured `CONNECTORS_CONNECT_SECRET`.
    * `:nonce` — override the random nonce.
    * `:issued_at_ms` — override the clock.

  Returns `{:ok, ticket}` or `{:error, :not_configured | :invalid_workspace |
  :invalid_provider}`. A missing secret is NOT a crash: the instance simply has
  no connect seam, and the catalog renders read-only.
  """
  @spec sign(binary(), binary(), keyword()) ::
          {:ok, String.t()} | {:error, :not_configured | :invalid_workspace | :invalid_provider}
  def sign(workspace_id, provider, opts \\ []) do
    secret = Keyword.get(opts, :secret) || Barkpark.Connectors.connect_secret()

    cond do
      not is_binary(secret) or secret == "" ->
        {:error, :not_configured}

      not (is_binary(workspace_id) and Regex.match?(@uuid_re, workspace_id)) ->
        {:error, :invalid_workspace}

      not (is_binary(provider) and Regex.match?(@provider_re, provider)) ->
        {:error, :invalid_provider}

      true ->
        nonce = Keyword.get(opts, :nonce) || random_nonce()
        issued_at = Keyword.get(opts, :issued_at_ms) || System.system_time(:millisecond)
        {:ok, build(secret, workspace_id, provider, nonce, issued_at)}
    end
  end

  # The payload is CONCATENATED, never encoded from a map: the bridge verifies a
  # signature over these exact bytes, and Jason gives no key-order guarantee.
  defp build(secret, workspace_id, provider, nonce, issued_at_ms) do
    json =
      ~s({"w":") <>
        workspace_id <>
        ~s(","p":") <>
        provider <>
        ~s(","n":") <>
        nonce <>
        ~s(","t":) <> Integer.to_string(issued_at_ms) <> "}"

    body = Base.url_encode64(json, padding: false)

    sig =
      :crypto.mac(:hmac, :sha256, secret, body)
      |> Base.url_encode64(padding: false)

    body <> "." <> sig
  end

  defp random_nonce, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
