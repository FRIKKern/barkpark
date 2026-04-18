defmodule Barkpark.Webhooks.Webhook do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "webhooks" do
    field :name, :string
    field :url, :string
    field :dataset, :string, default: "production"
    field :events, {:array, :string}, default: []
    field :types, {:array, :string}, default: []
    field :secret, :string
    field :previous_secret, :string
    field :previous_secret_expires_at, :utc_datetime_usec
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @valid_events ~w(create update publish unpublish delete discardDraft patch)

  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [
      :name,
      :url,
      :dataset,
      :events,
      :types,
      :secret,
      :previous_secret,
      :previous_secret_expires_at,
      :active
    ])
    |> validate_required([:name, :url])
    |> validate_format(:url, ~r/^https?:\/\//)
    |> validate_subset(:events, @valid_events)
  end

  @doc """
  Returns the list of secrets that should be considered valid right now.
  Always includes the primary `secret` (when set). Includes `previous_secret`
  if it exists and `previous_secret_expires_at` is in the future.
  """
  def effective_secrets(%__MODULE__{} = wh, now \\ DateTime.utc_now()) do
    primary = if is_binary(wh.secret) and wh.secret != "", do: [wh.secret], else: []

    previous =
      cond do
        not is_binary(wh.previous_secret) or wh.previous_secret == "" -> []
        is_nil(wh.previous_secret_expires_at) -> []
        DateTime.compare(wh.previous_secret_expires_at, now) == :gt -> [wh.previous_secret]
        true -> []
      end

    primary ++ previous
  end
end
