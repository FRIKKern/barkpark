defmodule Barkpark.StudioChat.Endpoints do
  @moduledoc """
  The ONE core-side seam for "where does this host answer HTTP?".

  Studio Chat spawns children that must call back into this node's API: the
  loopback `bp mcp serve` child (`Provider.Claude.mcp_api_url/0`) and the
  REMOTE runtime's MCP callback URL (`StudioChat.Runtime`). Both used to reach
  straight into `BarkparkWeb.Endpoint`, which inverted the layering — core
  called the web app for a value that is really just deployment configuration
  (task-ad931ba2e0d0bdf4).

  ## The seam is a CONFIG KEY, not a module reference

  `config :barkpark, :studio_chat, endpoint: BarkparkWeb.Endpoint` (config.exs)
  hands core the endpoint module as DATA. Core never names `BarkparkWeb`, so
  there is no compile-time or runtime dependency on the web layer: a detached
  or headless consumer simply leaves the key unset (or overrides
  `:endpoint_url` / `:endpoint_port`) and everything here still answers.

  This is the same pattern `StudioChat.Probe.claude_chat_binary/0` already uses
  to read the chat binary without depending on the web wrapper.

  ## Precedence

  `url/0`         — `:studio_chat[:endpoint_url]`  → `endpoint.url()`      → `@fallback_url`
  `http_port/0`   — `:studio_chat[:endpoint_port]` → endpoint's `:http` port → `@fallback_port`
  `loopback_url/0` — always `http://127.0.0.1:<http_port/0>`

  Every step is fenced: a missing key, an unloadable module, or a
  `{:system, …}`/`nil` port all degrade to the fallback rather than raising in
  a long-lived provider process.
  """

  @fallback_port 4000
  @fallback_url "http://127.0.0.1:#{@fallback_port}"

  @doc "The externally reachable base URL of this node's API."
  @spec url() :: String.t()
  def url do
    case config(:endpoint_url) do
      url when is_binary(url) and url != "" -> url
      _ -> endpoint_url() || @fallback_url
    end
  end

  @doc "The port this node's HTTP listener is bound to."
  @spec http_port() :: pos_integer()
  def http_port do
    case config(:endpoint_port) do
      port when is_integer(port) and port > 0 -> port
      _ -> endpoint_port() || @fallback_port
    end
  end

  @doc """
  The LOOPBACK API URL for a child running on this same host — it skips the
  public proxy and works before any DNS/TLS exists.
  """
  @spec loopback_url() :: String.t()
  def loopback_url, do: "http://127.0.0.1:#{http_port()}"

  @doc "The endpoint module handed to core as config data, or nil."
  @spec endpoint_module() :: module() | nil
  def endpoint_module do
    case config(:endpoint) do
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _ -> nil
    end
  end

  defp endpoint_url do
    with mod when not is_nil(mod) <- endpoint_module(),
         true <- Code.ensure_loaded?(mod),
         true <- function_exported?(mod, :url, 0),
         url when is_binary(url) and url != "" <- mod.url() do
      url
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp endpoint_port do
    with mod when not is_nil(mod) <- endpoint_module(),
         http when is_list(http) <-
           :barkpark |> Application.get_env(mod, []) |> Keyword.get(:http),
         port when is_integer(port) and port > 0 <- Keyword.get(http, :port) do
      port
    else
      _ -> nil
    end
  end

  defp config(key) do
    :barkpark
    |> Application.get_env(:studio_chat, [])
    |> Keyword.get(key)
  end
end
