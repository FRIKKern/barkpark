defmodule BarkparkCloud.Notifications.Channels.Pushover do
  @moduledoc """
  Pushover shaper — the analog of Coolify's
  `app/Notifications/Channels/PushoverChannel`. Posts to the fixed Pushover
  messages endpoint with the app `api_token` + the user/group `user_key` from the
  team's credentials. Pushover takes form-encoded params, not JSON.
  """
  alias BarkparkCloud.Notifications.Render

  @endpoint "https://api.pushover.net/1/messages.json"

  @spec shape(map(), String.t(), map()) ::
          {:ok, String.t(), iodata(), [{String.t(), String.t()}]} | {:error, term()}
  def shape(%{"user_key" => user, "api_token" => token}, event, payload)
      when is_binary(user) and user != "" and is_binary(token) and token != "" do
    {title, body, severity} = Render.render(event, payload)

    form =
      URI.encode_query(%{
        "token" => token,
        "user" => user,
        "title" => title,
        "message" => body,
        # Pushover priority: 1 (high) for errors, 0 (normal) otherwise.
        "priority" => if(severity == :error, do: "1", else: "0")
      })

    {:ok, @endpoint, form, [{"content-type", "application/x-www-form-urlencoded"}]}
  end

  def shape(_creds, _event, _payload), do: {:error, :missing_credentials}
end
