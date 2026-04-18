defmodule Barkpark.Webhooks do
  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Webhooks.{Webhook, Delivery}

  def list_webhooks(dataset) do
    Webhook
    |> where([w], w.dataset == ^dataset)
    |> order_by([w], asc: w.name)
    |> Repo.all()
  end

  def get_webhook(id) do
    case Repo.get(Webhook, id) do
      nil -> {:error, :not_found}
      webhook -> {:ok, webhook}
    end
  end

  def create_webhook(attrs) do
    %Webhook{}
    |> Webhook.changeset(attrs)
    |> Repo.insert()
  end

  def update_webhook(%Webhook{} = webhook, attrs) do
    webhook
    |> Webhook.changeset(attrs)
    |> Repo.update()
  end

  def delete_webhook(%Webhook{} = webhook) do
    Repo.delete(webhook)
  end

  def active_webhooks_for(dataset, event, type) do
    Webhook
    |> where([w], w.dataset == ^dataset and w.active == true)
    |> where([w], fragment("? = '{}' OR ? @> ARRAY[?]::varchar[]", w.events, w.events, ^event))
    |> where([w], fragment("? = '{}' OR ? @> ARRAY[?]::varchar[]", w.types, w.types, ^type))
    |> Repo.all()
  end

  @doc """
  Rotate the primary secret. The old secret moves to `previous_secret` and
  remains valid for `ttl_seconds` (default 86400 = 24h). Existing receivers
  can keep verifying with the old secret until it expires.
  """
  def rotate_secret(%Webhook{} = webhook, new_secret, ttl_seconds \\ 86_400)
      when is_binary(new_secret) do
    expires_at = DateTime.utc_now() |> DateTime.add(ttl_seconds, :second)

    webhook
    |> Webhook.changeset(%{
      "secret" => new_secret,
      "previous_secret" => webhook.secret,
      "previous_secret_expires_at" => expires_at
    })
    |> Repo.update()
  end

  @doc """
  Claim an (endpoint_id, event_id) delivery slot. Returns
  `{:ok, delivery}` if this is the first claim, or
  `{:error, :already_delivered}` if a row already exists for this pair.
  Uses the UNIQUE(endpoint_id, event_id) constraint for atomicity.
  """
  def claim_delivery(endpoint_id, event_id) when is_integer(event_id) do
    case Repo.insert(
           Delivery.changeset(%Delivery{}, %{
             endpoint_id: endpoint_id,
             event_id: event_id,
             status: "pending"
           }),
           on_conflict: :nothing,
           conflict_target: [:endpoint_id, :event_id]
         ) do
      {:ok, %Delivery{id: nil}} -> {:error, :already_delivered}
      {:ok, %Delivery{} = d} -> {:ok, d}
      {:error, _} = err -> err
    end
  end

  def mark_delivered(%Delivery{} = d, status_code, attempts) do
    d
    |> Delivery.changeset(%{
      status: "ok",
      last_status_code: status_code,
      attempts: attempts
    })
    |> Repo.update()
  end

  def mark_giveup(%Delivery{} = d, status_code, reason, attempts) do
    d
    |> Delivery.changeset(%{
      status: "failed_giveup",
      last_status_code: status_code,
      last_error_text: reason,
      attempts: attempts
    })
    |> Repo.update()
  end

  def get_delivery(endpoint_id, event_id) do
    Delivery
    |> where([d], d.endpoint_id == ^endpoint_id and d.event_id == ^event_id)
    |> Repo.one()
  end
end
