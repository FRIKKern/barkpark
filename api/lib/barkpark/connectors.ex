defmodule Barkpark.Connectors do
  @moduledoc """
  Barkpark Connectors — the Elixir side of the chat-bridge seam.

  Barkpark itself runs NO connector. The bridge (`connectors/`, a standalone
  Node service behind the `/connectors` Caddy path route) owns the adapters, the
  `chat_bridge` schema, and every provider credential. This context is the thin,
  honest edge Studio needs:

    * `Barkpark.Connectors.Catalog` — what a workspace can connect, and what it
      has (a read-only cross-schema query).
    * `Barkpark.Connectors.ConnectTicket` — the signed authorization for a
      Studio-initiated connect (D50).
    * `Barkpark.Connectors.Bridge` / `BridgeClient` — the three-route loopback
      seam that actually performs the connect (D51).

  ## The connect secret is OPTIONAL

  `connect_secret/0` returns `nil` on an instance where
  `CONNECTORS_CONNECT_SECRET` is unset. That is a supported state, not an error:
  the bridge does not mount the connect routes, and the Studio catalog renders
  READ-ONLY with a banner saying so. A missing secret must never raise at boot
  and must never produce an unauthenticated route — which is also what removes
  the merge-order hazard between the bridge slice and the deploy step.
  """

  @doc """
  The shared HMAC secret for connect tickets — the SAME value the bridge reads
  from `CONNECTORS_CONNECT_SECRET`. `nil` when this instance has no connect seam.
  """
  @spec connect_secret() :: String.t() | nil
  def connect_secret do
    case config()[:connect_secret] do
      s when is_binary(s) -> if String.trim(s) == "", do: nil, else: s
      _ -> nil
    end
  end

  @doc "True when this instance can perform a connect at all (the secret exists)."
  @spec connect_configured?() :: boolean()
  def connect_configured?, do: not is_nil(connect_secret())

  @doc "Base URL of the bridge's loopback seam (default `http://127.0.0.1:4020/connectors`)."
  @spec bridge_url() :: String.t()
  def bridge_url do
    case config()[:bridge_url] do
      url when is_binary(url) and url != "" -> url
      _ -> "http://127.0.0.1:4020/connectors"
    end
  end

  @doc "The `Barkpark.Connectors.Bridge` implementation (swapped in tests)."
  @spec bridge() :: module()
  def bridge, do: config()[:bridge] || Barkpark.Connectors.BridgeClient

  defp config, do: Application.get_env(:barkpark, __MODULE__, [])
end
