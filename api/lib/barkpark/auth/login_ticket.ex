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
    # cloud-identity-studio-handoff: non-nil makes this a USER-shaped ticket —
    # consuming it JIT-provisions this email (Default-workspace owner) and
    # mints a user_session. Only an admin-permission bearer may mint one.
    field :user_email, :string
    field :expires_at, :utc_datetime_usec
    field :used_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  # BYTE-IDENTICAL to `Barkpark.Accounts.User`'s `@email_format` (a private
  # module attribute there, so it cannot be imported across the boundary).
  # Keep the two in lockstep: the mint must refuse EXACTLY what registration
  # would refuse, or a ticket mints for an address that can never be
  # provisioned. See the note on `user_email` below.
  @email_format ~r/^[^\s@]+@[^\s@]+$/

  @doc """
  The one seat every mint passes through (`Auth.mint_login_ticket/2` is the
  sole caller). `user_email` is validated HERE, not at the consume, because
  `Auth.consume_login_ticket/1` burns the single-use row BEFORE the caller
  provisions the account: an address `Accounts.register_user` rejects made
  `Sso.find_or_create_user/1` raise (500) with the ticket already spent. A
  changeset error surfaces as the mint's existing `{:error, :unauthorized}` —
  the same no-oracle shape the controller already renders. `validate_format`
  is a no-op when `user_email` is absent (a token-shaped ticket).
  """
  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [:ticket_hash, :api_token, :user_email, :expires_at, :used_at])
    |> validate_required([:ticket_hash, :api_token, :expires_at])
    |> validate_format(:user_email, @email_format, message: "must have the @ sign and no spaces")
    |> unique_constraint(:ticket_hash)
  end
end
