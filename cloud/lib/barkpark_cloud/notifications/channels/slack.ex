defmodule BarkparkCloud.Notifications.Channels.Slack do
  @moduledoc """
  Slack incoming-webhook shaper — the analog of Coolify's
  `app/Notifications/Channels/SlackChannel` + `Dto/SlackMessage`. Posts a Block
  Kit message (header + section) to the team's own incoming-webhook URL
  (`creds["url"]`), with a `text` fallback for notification previews.
  """
  alias BarkparkCloud.Notifications.Channels.Idempotency
  alias BarkparkCloud.Notifications.Render

  @spec shape(map(), String.t(), map(), keyword()) ::
          {:ok, String.t(), iodata(), [{String.t(), String.t()}]} | {:error, term()}
  def shape(creds, event, payload, opts \\ [])

  def shape(%{"url" => url}, event, payload, opts) when is_binary(url) and url != "" do
    {title, body, _severity} = Render.render(event, payload)

    json =
      Jason.encode!(%{
        text: "#{title}: #{body}",
        blocks: [
          %{type: "header", text: %{type: "plain_text", text: title}},
          %{type: "section", text: %{type: "mrkdwn", text: body}}
        ]
      })

    headers =
      [{"content-type", "application/json"}]
      |> Idempotency.put_headers(Idempotency.from_opts(opts))

    {:ok, url, json, headers}
  end

  def shape(_creds, _event, _payload, _opts), do: {:error, :missing_url}
end
