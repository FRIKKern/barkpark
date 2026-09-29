defmodule BarkparkCloud.Notifications.Channels.Telegram do
  @moduledoc """
  Telegram Bot API shaper — the analog of Coolify's
  `app/Notifications/Channels/TelegramChannel`. Unlike the webhook channels the
  URL is DERIVED from the bot token (`https://api.telegram.org/bot<token>/sendMessage`)
  rather than supplied; the destination is `creds["chat_id"]`, with an optional
  `creds["thread_id"]` (or a per-event `payload.thread_id`) for forum topics.
  """
  alias BarkparkCloud.Notifications.Channels.Idempotency
  alias BarkparkCloud.Notifications.Render

  @spec shape(map(), String.t(), map(), keyword()) ::
          {:ok, String.t(), iodata(), [{String.t(), String.t()}]} | {:error, term()}
  def shape(creds, event, payload, opts \\ [])

  def shape(%{"token" => token, "chat_id" => chat_id} = creds, event, payload, opts)
      when is_binary(token) and token != "" and is_binary(chat_id) and chat_id != "" do
    {title, body, _severity} = Render.render(event, payload)

    thread = payload[:thread_id] || payload["thread_id"] || creds["thread_id"]

    msg =
      %{chat_id: chat_id, text: "#{title}\n#{body}"}
      |> maybe_thread(thread)

    url = "https://api.telegram.org/bot#{token}/sendMessage"

    headers =
      [{"content-type", "application/json"}]
      |> Idempotency.put_headers(Idempotency.from_opts(opts))

    {:ok, url, Jason.encode!(msg), headers}
  end

  def shape(%{"token" => _}, _event, _payload, _opts), do: {:error, :missing_chat_id}
  def shape(_creds, _event, _payload, _opts), do: {:error, :missing_credentials}

  defp maybe_thread(base, nil), do: base
  defp maybe_thread(base, ""), do: base
  defp maybe_thread(base, thread), do: Map.put(base, :message_thread_id, thread)
end
