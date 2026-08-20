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

  # ── The TOOL-SESSION ticket (Connectors D69/D73) — the OTHER direction ──────
  #
  # A paste ticket authorizes ONE Studio connect and lives 600 s. A TOOL ticket
  # authorizes the runner's `claude` subprocess to fetch a workspace's sealed
  # tool credentials (a GitHub PAT) at MCP-connect, so it must outlive a paste
  # window: it is baked into the per-session `--mcp-config` file's `headersHelper`
  # and fired every time the subprocess (re)connects the tool MCP server, for the
  # whole chat session. It binds the RESERVED provider `tool-session` (never a
  # concrete tool provider) — one ticket lists ALL of a workspace's tool
  # connectors and opens each one; the concrete provider rides the ROUTE path on
  # the bridge, never the ticket. These two constants MIRROR the bridge's
  # `TOOL_TICKET_PROVIDER` / `TOOL_TICKET_TTL_MS` (connectors/src/connect/ticket.ts);
  # the bridge is the enforcer of the 8 h age — Elixir only signs.
  @tool_provider "tool-session"
  @tool_ttl_ms 28_800_000

  @uuid_re ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/
  @provider_re ~r/\A[a-z0-9_-]{1,64}\z/

  @doc "The ticket TTL the bridge enforces (ms). Exposed so tests pin ONE number."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc """
  The reserved provider a TOOL-SESSION ticket binds (connectors D69). MIRRORS
  the bridge's `TOOL_TICKET_PROVIDER`; a mismatch would 401 every tool fetch.
  """
  @spec tool_ticket_provider() :: String.t()
  def tool_ticket_provider, do: @tool_provider

  @doc """
  The TOOL-SESSION ticket age the bridge tolerates (ms, 8 h). MIRRORS the
  bridge's `TOOL_TICKET_TTL_MS`. Elixir does not enforce it (it only signs `t`);
  the bridge's `verifyToolTicket` is the enforcer.
  """
  @spec tool_ttl_ms() :: pos_integer()
  def tool_ttl_ms, do: @tool_ttl_ms

  @doc """
  Sign a TOOL-SESSION ticket for `workspace_id` (connectors D69/D73).

  A thin specialisation of `sign/3` that pins the reserved provider
  `tool-session` so a short paste ticket for a concrete provider can never be
  replayed at the bridge's tool routes. Same fail-closed input validation and
  same `{:error, :not_configured}` on an instance with no connect secret.

  Options mirror `sign/3` (`:secret`, `:nonce`, `:issued_at_ms`) — tests only.
  """
  @spec sign_tool(binary(), keyword()) ::
          {:ok, String.t()} | {:error, :not_configured | :invalid_workspace | :invalid_provider}
  def sign_tool(workspace_id, opts \\ []) do
    sign(workspace_id, @tool_provider, opts)
  end

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
