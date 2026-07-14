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

  @callback connect(ticket :: String.t(), credential :: String.t(), chat_token :: String.t()) ::
              {:ok, %{install_key: String.t(), mounted: boolean()}} | {:error, reason()}

  @callback disconnect(ticket :: String.t(), install_key :: String.t()) ::
              {:ok, %{removed: boolean()}} | {:error, reason()}
end
