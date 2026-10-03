defmodule BarkparkCloud.Registry.DomainVerification do
  @moduledoc """
  Owner ruling #29 (2026-10-03, "DNS TXT check"): one row per (team, domain)
  holding the token that team must publish to prove it controls the domain:

      _barkpark-verify.<domain>  TXT  "barkpark-verify=<token>"

  The proof works whether the domain's traffic points at a Barkpark box or at
  Cloudflare, because it reads a separate name. `verified_at` is stamped the
  first time the record is seen. A site may claim a domain only after its team
  has proven it (`Registry.add_site_domain_verified/2`), and a FRESH proof also
  lets the real owner reclaim a domain another site squatted before the ruling.

  The token is not a secret — it is published in public DNS by design — but it
  is unguessable, so one team cannot pre-publish another team's proof.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "domain_verifications" do
    field :domain, :string
    field :token, :string
    field :verified_at, :utc_datetime_usec
    belongs_to :team, BarkparkCloud.Accounts.Team

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @record_prefix "_barkpark-verify."
  @value_prefix "barkpark-verify="

  @doc "The DNS name the TXT record lives at."
  def record_name(domain), do: @record_prefix <> domain

  @doc "The exact TXT value that proves `token`."
  def record_value(token), do: @value_prefix <> token

  @doc "A fresh, unguessable token (32 url-safe chars)."
  def new_token, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:team_id, :domain, :token, :verified_at])
    |> validate_required([:team_id, :domain, :token])
    |> foreign_key_constraint(:team_id, name: :domain_verifications_team_id_fkey)
    |> unique_constraint([:team_id, :domain])
  end

  @doc "The challenge a client shows a person: where to put what."
  def challenge(%__MODULE__{domain: domain, token: token}) do
    %{
      domain: domain,
      txt_name: record_name(domain),
      txt_value: record_value(token)
    }
  end
end
