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

    belongs_to :workspace, Barkpark.Tenancy.Workspace, type: :binary_id
    belongs_to :project, Barkpark.Tenancy.Project, type: :binary_id

    # W2 additive seam. `:dataset_entity` — the legacy `dataset` STRING field
    # still owns `:dataset` (dual presence). FK column is `dataset_id`.
    belongs_to :dataset_entity, Barkpark.Tenancy.Dataset,
      foreign_key: :dataset_id,
      type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @valid_events ~w(create update publish unpublish delete discardDraft patch)

  def changeset(webhook, attrs) do
    webhook
    # NOTE: :previous_secret / :previous_secret_expires_at are intentionally NOT
    # castable — the previous-secret rotation window is established ONLY by
    # Webhooks.rotate_secret/3, never from client-supplied attrs (which could
    # reinstate a stale secret with a far-future TTL and defeat rotation).
    # :workspace_id / :project_id ARE cast here (the publish/inherit paths and
    # the scope-stamp in Webhooks.create_webhook set them from server-resolved
    # opts), but Webhooks.create_webhook/update_webhook strip any CLIENT-supplied
    # scope keys before this runs — the tenant is never chosen by request body.
    |> cast(attrs, [
      :name,
      :url,
      :dataset,
      :events,
      :types,
      :secret,
      :active,
      :workspace_id,
      :project_id
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
