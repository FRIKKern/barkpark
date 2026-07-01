defmodule Barkpark.Auth.LoginTicket do
  @moduledoc """
  A single-use, short-TTL login handoff ticket (dwb-7 "Studio one-click entry").

  Minted from a valid api_token by `POST /v1/auth/login-tickets` and consumed
  exactly once by `GET /login/ticket/:ticket`, which drops the bound raw
  api_token into the browser session (same effect as `POST /login`, no paste).

  Hygiene mirrors `Barkpark.Auth.ApiToken`: the opaque ticket is stored only as
  its SHA-256 hash (`ticket_hash`), never raw. The bound `api_token` is the RAW
  bearer value — LiveAuth verifies the raw token — held encrypted-at-rest via
  `Barkpark.EncryptedBinary` (Cloak AES-GCM) for the ticket's 60s life, then the
  row is spent (`used_at`). Single-use is enforced by an atomic
  `UPDATE ... WHERE used_at IS NULL` claim, not a read-then-write.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "login_tickets" do
    field :ticket_hash, :string
    field :api_token, Barkpark.EncryptedBinary
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:ticket_hash, :api_token, :expires_at, :used_at])
    |> validate_required([:ticket_hash, :api_token, :expires_at])
    |> unique_constraint(:ticket_hash)
  end
end
