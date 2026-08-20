defmodule Barkpark.Connectors.Bridge do
  @moduledoc """
  The BEHAVIOUR of the connectors bridge's loopback connect seam (D50/D51).

  Three routes, fixed at the wave's Decide so the Elixir half and the Node half
  could be built in parallel without renegotiating anything:

      POST {bridge}/connect/validate  {ticket, credential}              -> {install_key, display_name}
      POST {bridge}/connect           {ticket, credential, chat_token}  -> {ok, install_key, mounted}
      POST {bridge}/disconnect        {ticket, install_key}             -> {ok, removed}

  Two-step by design (D51): VALIDATE writes nothing and tells Studio the
  `install_key` (Telegram's `getMe`, Discord's `GET /users/@me`) — which is what
  lets the chat token be minted with the label `connector:<provider>:<install_key>`
  BEFORE the install exists. That label is the only handle disconnect has on the
  token afterwards.

  The default implementation is `Barkpark.Connectors.BridgeClient` (Req over
  `127.0.0.1`). Tests swap it via
  `config :barkpark, Barkpark.Connectors, bridge: MyStub` — the seam exists so
  the LiveView's connect/disconnect/revoke logic is testable WITHOUT a running
  Node process, and so a stubbed bridge can return the failure shapes (unreachable,
  refused) that must never become a fake "Connected".
  """

  @type reason ::
          :not_configured
          | :unreachable
          | {:refused, String.t()}
          | {:http, integer()}

  @callback validate(ticket :: String.t(), credential :: String.t()) ::
              {:ok, %{install_key: String.t(), display_name: String.t()}} | {:error, reason()}

  # `chat_token` is `nil` for a TOOL connect (github/linear — D101): a tool install
  # seals ONLY the pasted credential, its `chat_token_ref` stays NULL, and no
  # workspace chat token is minted. Channel connects pass a real minted token.
  @callback connect(
              ticket :: String.t(),
              credential :: String.t(),
              chat_token :: String.t() | nil
            ) ::
              {:ok, %{install_key: String.t(), mounted: boolean()}} | {:error, reason()}

  @callback disconnect(ticket :: String.t(), install_key :: String.t()) ::
              {:ok, %{removed: boolean()}} | {:error, reason()}

  @doc """
  STAGE a pending-connect row for the Add-to-Slack OAuth flow (D63).

  Slack's OAuth install crosses a browser redirect, so the chat token (which only
  Studio can mint) cannot ride the OAuth `state` — it is handed to the bridge over
  LOOPBACK, ahead of the redirect, keyed by the ticket's nonce. The public OAuth
  callback later JOINS it by that nonce and writes the install once. The raw chat
  token rides THIS body over loopback, never a URL.

  `POST {bridge}/connect/pending {ticket, chat_token}` -> `{ok}`.
  """
  @callback stage_pending(ticket :: String.t(), chat_token :: String.t()) ::
              {:ok, map()} | {:error, reason()}

  @doc """
  FETCH the workspace's TOOL descriptors for the runner (connectors D69/D73) —
  the OTHER direction. This is the outbound-tool mirror of the connect routes:
  the runner (`claude_chat.ex` `setup_mcp`) mints a session-length tool ticket
  and asks the bridge which MCP servers this workspace's agent may connect to.

  The bridge answers a list of NON-SECRET descriptors (`%{"provider", "type",
  "url", "headersHelper"}`) — one per tool connector the workspace has an install
  of. The PAT is NEVER in this answer (D38): the subprocess fetches it at
  MCP-connect via the `headersHelper` command, over the bridge's loopback
  `tool-headers` route, and Elixir never holds plaintext.

  `POST {bridge}/connect/tool-descriptors {ticket}` -> `{descriptors: [...]}`.

  OPTIONAL: a stub bridge that does not implement it is treated as "no tool
  servers" by the runner — a session simply gets the loopback server alone.
  """
  @callback fetch_tool_descriptors(ticket :: String.t()) ::
              {:ok, [map()]} | {:error, reason()}

  @optional_callbacks fetch_tool_descriptors: 1
end
