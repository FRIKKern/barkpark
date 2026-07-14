defmodule Barkpark.Connectors.BridgeClient do
  @moduledoc """
  The real `Barkpark.Connectors.Bridge` — Req over LOOPBACK to the connectors
  bridge (D50).

  `CONNECTORS_BRIDGE_URL` defaults to `http://127.0.0.1:4020/connectors`: the
  bridge binds loopback on the SAME box as the BEAM (`CONNECTORS_HTTP_ADDR`,
  set by `deploy/instance-deploy.sh`), and the connect routes 404 opaquely on
  any request carrying `x-forwarded-*` — so the public `/connectors` path route
  can never reach them, and the raw chat token never leaves the box.

  ## Failure shapes are the product

  Every failure is TYPED and rendered honestly. There is no branch anywhere in
  this module that turns a failure into a success:

    * `{:error, :unreachable}` — the bridge is not running / the socket refused.
      The operator sees "the connectors bridge is not answering", not "Connected".
    * `{:error, {:refused, reason}}` — the bridge said no (a 4xx with a reason:
      an invalid bot token, an already-claimed install, a cross-tenant
      disconnect). The operator sees the bridge's own reason.
    * `{:error, {:http, status}}` — anything else.

  `retry: false` is deliberate: `/connect` WRITES (an install row + a live mount).
  A blind retry of a half-applied write is how you end up with two installs and
  one revoked token.
  """

  @behaviour Barkpark.Connectors.Bridge

  require Logger

  alias Barkpark.Connectors

  # A paste-mode validate calls out to Telegram/Discord, so the bridge's own
  # round trip dominates. Generous, but bounded — a hung bridge must not hold a
  # LiveView process forever.
  @receive_timeout 20_000

  @impl true
  def validate(ticket, credential) do
    case post("/connect/validate", %{ticket: ticket, credential: credential}) do
      {:ok, %{"install_key" => key, "display_name" => name}}
      when is_binary(key) and is_binary(name) ->
        {:ok, %{install_key: key, display_name: name}}

      {:ok, body} ->
        {:error,
         {:refused, reason_from(body, "the bridge accepted the ticket but returned no install")}}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def connect(ticket, credential, chat_token) do
    # The raw chat token rides THIS body, over loopback, once. It is never
    # logged, never assigned to a socket, never returned.
    case post("/connect", %{ticket: ticket, credential: credential, chat_token: chat_token}) do
      {:ok, %{"ok" => true, "install_key" => key} = body} when is_binary(key) ->
        {:ok, %{install_key: key, mounted: body["mounted"] == true}}

      {:ok, body} ->
        {:error, {:refused, reason_from(body, "the bridge refused the install")}}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def disconnect(ticket, install_key) do
    case post("/disconnect", %{ticket: ticket, install_key: install_key}) do
      {:ok, %{"ok" => true} = body} ->
        {:ok, %{removed: body["removed"] == true}}

      {:ok, body} ->
        {:error, {:refused, reason_from(body, "the bridge refused the disconnect")}}

      {:error, _} = err ->
        err
    end
  end

  defp post(path, body) do
    case Connectors.bridge_url() do
      url when is_binary(url) and url != "" ->
        do_post(String.trim_trailing(url, "/") <> path, body)

      _ ->
        {:error, :not_configured}
    end
  end

  defp do_post(url, body) do
    req =
      Req.new(
        url: url,
        json: body,
        method: :post,
        retry: false,
        receive_timeout: @receive_timeout,
        connect_options: [timeout: 5_000]
      )

    case Req.request(req) do
      {:ok, %Req.Response{status: status, body: resp}} when status in 200..299 ->
        {:ok, normalize(resp)}

      {:ok, %Req.Response{status: status, body: resp}} when status in 400..499 ->
        {:error,
         {:refused, reason_from(normalize(resp), "the bridge rejected the request (#{status})")}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        # Log the transport failure (never the body — it holds the credential).
        Logger.warning("connectors bridge unreachable at #{url}: #{inspect(reason)}")
        {:error, :unreachable}
    end
  end

  defp normalize(body) when is_map(body), do: body
  defp normalize(_), do: %{}

  defp reason_from(%{"reason" => reason}, _default) when is_binary(reason) and reason != "",
    do: reason

  defp reason_from(%{"error" => %{"message" => msg}}, _default) when is_binary(msg) and msg != "",
    do: msg

  defp reason_from(%{"error" => err}, _default) when is_binary(err) and err != "", do: err
  defp reason_from(_body, default), do: default
end
