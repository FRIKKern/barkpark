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
    * `{:error, {:refused, reason}}` — the bridge said no, and `reason` is always
      a SENTENCE. When the bridge explains itself (`invalid_credential` quoting
      Telegram, `install_owned_elsewhere`, a 502 `mount_failed`) that explanation
      is passed through verbatim. When it answers with one of its deliberately
      OPAQUE codes (`not_found` is byte-identical for four different refusals, so
      that it is not an enumeration oracle) the code is translated HERE — a wire
      token must never surface as UI copy ("Could not disconnect: not_found").
    * `{:error, {:http, status}}` — a non-2xx below 400, which this bridge does
      not emit. Kept as the honest catch-all rather than a `raise`.

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
  def stage_pending(ticket, chat_token) do
    # The raw chat token rides THIS body, over loopback, once — sealed by the
    # bridge into the pending_connect row and never returned. `retry: false` (in
    # `do_post`) keeps a half-applied stage from being replayed.
    case post("/connect/pending", %{ticket: ticket, chat_token: chat_token}) do
      {:ok, %{"ok" => true} = body} ->
        {:ok, body}

      {:ok, body} ->
        {:error, {:refused, reason_from(body, "the bridge refused to stage the connect")}}

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

  @impl true
  def fetch_tool_descriptors(ticket) do
    # A READ, not a write — the tool-descriptors route lists a workspace's tool
    # connectors and mints no state. `retry: false` still holds (via `do_post`);
    # a transient failure is fail-soft at the caller (no tool servers this
    # session), never a fabricated list.
    case post("/connect/tool-descriptors", %{ticket: ticket}) do
      {:ok, %{"descriptors" => descriptors}} when is_list(descriptors) ->
        {:ok, descriptors}

      {:ok, _body} ->
        # A 200 with no descriptors array is an empty toolset, not an error —
        # the bridge answers `{descriptors: []}` for a workspace that has
        # connected nothing, and a defensive shape mismatch degrades the same.
        {:ok, []}

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

      # EVERY failing status, not just 4xx. A `502 mount_failed` carries the one
      # sentence the operator most needs ("the credential was accepted by the
      # provider but the adapter refused to mount it — nothing was installed"),
      # and routing 5xx to `{:http, status}` threw it away and showed them
      # "The bridge returned HTTP 502." instead.
      {:ok, %Req.Response{status: status, body: resp}} when status >= 400 ->
        {:error, {:refused, reason_from(normalize(resp), status)}}

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

  # The bridge speaks TWO kinds of failure body, and only one of them is for a
  # human:
  #
  #   * `{"error": "<code>", "reason": "<sentence>"}` — a refusal it can explain
  #     (invalid_credential, install_owned_elsewhere, mount_failed). The sentence
  #     IS the message; it is written for the operator and often quotes the
  #     provider ("Unauthorized", straight from Telegram).
  #   * `{"error": "<code>"}` alone — the seam's OPAQUE refusals. `not_found` is
  #     deliberately byte-identical for an unknown route, an unmounted connect
  #     seam, an unconnectable provider and a cross-tenant disconnect, precisely
  #     so it is not an enumeration oracle — which makes it a machine token, and
  #     "Could not disconnect: not_found" is not a sentence anyone should read in
  #     a product. Translate it here, where the wire is owned, rather than let a
  #     wire code become UI copy.
  defp reason_from(%{"reason" => reason}, _status) when is_binary(reason) and reason != "",
    do: reason

  defp reason_from(%{"error" => %{"message" => msg}}, _status) when is_binary(msg) and msg != "",
    do: msg

  defp reason_from(%{"error" => code}, status) when is_binary(code) and code != "",
    do: humanize(code, status)

  defp reason_from(_body, status), do: humanize(nil, status)

  defp humanize("not_found", _status),
    do:
      "The bridge did not recognise that request. Either its connect routes are not " <>
        "mounted on this instance, or the install no longer exists."

  defp humanize("unauthorized", _status),
    do: "The bridge rejected the connect ticket — it may have expired. Close this and try again."

  defp humanize("bad_request", _status), do: "The bridge could not read the request."

  defp humanize("payload_too_large", _status), do: "That credential is too large for the bridge."

  defp humanize("internal_error", _status),
    do: "The bridge hit an internal error. Nothing was connected — check its journal."

  defp humanize(nil, status), do: "The bridge refused the request (HTTP #{status})."
  defp humanize(code, status), do: "The bridge refused the request (#{code}, HTTP #{status})."
end
