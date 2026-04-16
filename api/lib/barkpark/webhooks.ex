defmodule Barkpark.Webhooks do
  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Webhooks.Webhook

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
end
