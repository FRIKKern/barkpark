defmodule Barkpark.Accounts.UserEmailToken do
  @moduledoc """
  A single-use, hashed email token for `"confirm"` (email verification),
  `"reset"` (password reset), and `"login"` (passwordless magic-link sign-in).
  Only the SHA-256 hash is stored; the plaintext travels in the emailed link.
  `sent_to` pins the token to the address it was mailed to; `expires_at` bounds
  validity. Rows are deleted on successful use.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @contexts ~w(confirm reset login)
  # Confirmation links live a day; reset and magic-login links are short-lived.
  @validity %{"confirm" => 60 * 60 * 24, "reset" => 60 * 60, "login" => 60 * 15}

  schema "user_email_tokens" do
    field :token_hash, :string
    field :context, :string
    field :sent_to, :string

    field :expires_at, :utc_datetime_usec

    belongs_to :user, Barkpark.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "Allowed contexts."
  def contexts, do: @contexts

  @doc "Validity window (seconds) for a context."
  def validity_seconds(context), do: Map.fetch!(@validity, context)

  @doc false
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token_hash, :context, :sent_to, :expires_at, :user_id])
    |> validate_required([:token_hash, :context, :sent_to, :expires_at, :user_id])
    |> validate_inclusion(:context, @contexts)
    |> assoc_constraint(:user)
    |> unique_constraint(:token_hash)
  end

  @doc "Hash a raw token for storage / lookup (SHA-256, lowercase hex)."
  @spec hash_token(binary()) :: String.t()
  def hash_token(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end
end
