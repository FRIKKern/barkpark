defmodule BarkparkCloud.Notifications.Channels.Webhook do
  @moduledoc """
  Generic raw-JSON webhook shaper — the analog of Coolify's user-supplied webhook
  notification. POSTs a flat JSON envelope (`event`, `team_id`, `payload`,
  `timestamp`) to an OPERATOR-SUPPLIED URL (`creds["url"]`).

  Because the URL is arbitrary, it is gated by
  `BarkparkCloud.Notifications.SafeUrl` — re-checked HERE at send time (not just at
  `put_channel` validation), the defense-in-depth Coolify applies in
  `SendWebhookJob`. A URL that passed validation but now resolves to a private
  address (DNS rebinding) is blocked at the last moment. This is no longer the ONE
  gated channel: `Notifications.do_deliver_chat/4` runs the same check on every
  credential carrying a `"url"`, so Slack and Discord are covered too. The check
  here is kept as belt-and-braces for this shaper's own contract.
  """
  alias BarkparkCloud.Notifications.{Render, SafeUrl}

  @spec shape(map(), String.t(), map(), keyword()) ::
          {:ok, String.t(), iodata(), [{String.t(), String.t()}]}
          | {:error, term()}
  def shape(creds, event, payload, opts \\ [])

  def shape(%{"url" => url}, event, payload, opts)
      when is_binary(url) and url != "" do
    case SafeUrl.check(url) do
      :ok ->
        {title, body, _severity} = Render.render(event, payload)

        json =
          Jason.encode!(%{
            event: event,
            team_id: Keyword.get(opts, :team_id),
            title: title,
            message: body,
            payload: payload,
            timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
          })

        {:ok, url, json, [{"content-type", "application/json"}]}

      {:error, _} = err ->
        err
    end
  end

  def shape(_creds, _event, _payload, _opts), do: {:error, :missing_url}
end
