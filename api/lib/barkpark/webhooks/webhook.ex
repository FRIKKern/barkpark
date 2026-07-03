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

    # Auto-disable substrate (server-managed; NEVER client-castable). The
    # dispatcher increments `consecutive_failures` on a TRUE terminal give-up and
    # resets it to 0 on any successful delivery; when it crosses the configured
    # threshold the row is auto-disabled (`active=false`) and stamped here. The
    # console panel renders these; a PUT `{active: true}` clears them via
    # `Webhooks.update_webhook/2`'s re-enable fold (D55). Writes go through
    # `Webhooks` (raw update_all / change), never the public changeset — so a
    # client can never forge or clear the disable state directly.
    field :consecutive_failures, :integer, default: 0
    field :auto_disabled_at, :utc_datetime
    field :disable_reason, :string

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
    |> validate_change(:url, &validate_outbound_url/2)
    |> validate_subset(:events, @valid_events)
  end

  # Defense-in-depth shape check: require an http(s) URL with a host and no
  # userinfo. This is NOT the SSRF fix — the runtime guard
  # (`Barkpark.Net.SafeOutbound`) owns host resolution and rebind protection;
  # we deliberately do not DNS-resolve at changeset time.
  defp validate_outbound_url(:url, url) do
    case URI.new(url) do
      {:ok, %URI{scheme: s, host: h, userinfo: nil}}
      when s in ["http", "https"] and is_binary(h) and h != "" ->
        []

      {:ok, %URI{userinfo: ui}} when not is_nil(ui) ->
        [url: "must not contain userinfo"]

      _ ->
        [url: "must be an http(s) URL with a host"]
    end
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
