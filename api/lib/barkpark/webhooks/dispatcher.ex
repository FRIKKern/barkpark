defmodule Barkpark.Webhooks.Dispatcher do
  @moduledoc """
  Delivers webhook payloads asynchronously via Task.Supervisor.

  Called from `Barkpark.Content.tap_broadcast/5` after mutations commit.
  Each matching webhook gets its own supervised task so a slow or failing
  endpoint cannot block the caller or other deliveries.
  """

  require Logger
  alias Barkpark.Webhooks

  @doc """
  Finds all active webhooks matching `dataset`, `event`, and `type`,
  then spawns a supervised task for each delivery.
  """
  def dispatch_async(dataset, event, type, doc_id, document) do
    payload = build_payload(event, type, doc_id, document, dataset)
    body = Jason.encode!(payload)

    webhooks = Webhooks.active_webhooks_for(dataset, event, type)

    Enum.each(webhooks, fn wh ->
      Task.Supervisor.start_child(Barkpark.TaskSupervisor, fn ->
        deliver(wh, body)
      end)
    end)
  end

  @doc "Builds the JSON-serialisable payload map."
  def build_payload(event, type, doc_id, document, dataset) do
    %{
      event: event,
      type: type,
      doc_id: doc_id,
      document: document,
      dataset: dataset,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc "Returns an `sha256=<hex>` HMAC signature for the given body and secret."
  def sign_payload(body, secret) do
    sig = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
    "sha256=#{sig}"
  end

  defp deliver(webhook, body) do
    headers = [{"content-type", "application/json"}]

    headers =
      if webhook.secret do
        sig = sign_payload(body, webhook.secret)
        [{"x-webhook-signature", sig} | headers]
      else
        headers
      end

    case Req.post(webhook.url, body: body, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("Webhook #{webhook.name} delivered (#{status})")

      {:ok, %{status: status}} ->
        Logger.warning("Webhook #{webhook.name} failed (#{status})")

      {:error, reason} ->
        Logger.warning("Webhook #{webhook.name} error: #{inspect(reason)}")
    end
  end
end
