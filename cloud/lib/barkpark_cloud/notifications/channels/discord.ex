defmodule BarkparkCloud.Notifications.Channels.Discord do
  @moduledoc """
  Discord incoming-webhook shaper — the analog of Coolify's
  `app/Notifications/Channels/DiscordChannel` + `Dto/DiscordMessage`. Posts a
  single rich embed whose colour reflects event severity (red/amber/green), to the
  team's own incoming-webhook URL (`creds["url"]`).
  """
  alias BarkparkCloud.Notifications.Channels.Idempotency
  alias BarkparkCloud.Notifications.Render

  # Discord embed colours (decimal): red / amber / green by severity.
  @colors %{error: 15_158_332, warning: 16_761_095, info: 3_066_993}

  @doc """
  Build `{:ok, url, json_body, headers}` for a Discord delivery, or
  `{:error, reason}` when the webhook URL is missing.
  """
  @spec shape(map(), String.t(), map(), keyword()) ::
          {:ok, String.t(), iodata(), [{String.t(), String.t()}]} | {:error, term()}
  def shape(creds, event, payload, opts \\ [])

  def shape(%{"url" => url}, event, payload, opts) when is_binary(url) and url != "" do
    {title, body, severity} = Render.render(event, payload)

    json =
      Jason.encode!(%{
        embeds: [
          %{
            title: title,
            description: body,
            color: Map.get(@colors, severity, @colors.info)
          }
        ]
      })

    headers =
      [{"content-type", "application/json"}]
      |> Idempotency.put_headers(Idempotency.from_opts(opts))

    {:ok, url, json, headers}
  end

  def shape(_creds, _event, _payload, _opts), do: {:error, :missing_url}
end
