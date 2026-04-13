defmodule Barkpark.Media.MediaFile do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "media_files" do
    field :filename, :string
    field :original_name, :string
    field :path, :string
    field :mime_type, :string
    field :size, :integer
    field :dataset, :string, default: "production"

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(media_file, attrs) do
    media_file
    |> cast(attrs, [:filename, :original_name, :path, :mime_type, :size, :dataset])
    |> validate_required([:filename, :original_name, :path])
    |> unique_constraint([:path, :dataset])
  end
end
