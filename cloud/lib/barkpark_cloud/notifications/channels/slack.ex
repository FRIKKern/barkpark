defmodule BarkparkCloud.Notifications.Channels.Slack do
  @moduledoc """
  Slack incoming-webhook shaper — the analog of Coolify's
  `app/Notifications/Channels/SlackChannel` + `Dto/SlackMessage`. Posts a Block
  Kit message (header + section) to the team's own incoming-webhook URL
  (`creds["url"]`), with a `text` fallback for notification previews.
  """
  alias BarkparkCloud.Notifications.Render

  @spec shape(map(), String.t(), map()) ::
          {:ok, String.t(), iodata(), [{String.t(), String.t()}]} | {:error, term()}
  def shape(%{"url" => url}, event, payload) when is_binary(url) and url != "" do
    {title, body, _severity} = Render.render(event, payload)

    json =
      Jason.encode!(%{
        text: "#{title}: #{body}",
        blocks: [
          %{type: "header", text: %{type: "plain_text", text: title}},
          %{type: "section", text: %{type: "mrkdwn", text: body}}
        ]
      })

    {:ok, url, json, [{"content-type", "application/json"}]}
  end

  def shape(_creds, _event, _payload), do: {:error, :missing_url}
end
