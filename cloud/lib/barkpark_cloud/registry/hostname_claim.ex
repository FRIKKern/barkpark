defmodule BarkparkCloud.Registry.HostnameClaim do
  @moduledoc """
  One row per hostname a barkpark answers on — the table that lets the DATABASE
  refuse a url/custom_host collision (`dr-w24-bl-hostname-claims-table-backstop`).

  A barkparks row claims TWO hostnames: the host of its provisioning `url` and
  its `custom_host`. `barkparks_url_unique_idx` and
  `barkparks_custom_host_unique_idx` each produce one key per row from ONE
  column, so a collision between DIFFERENT columns of DIFFERENT rows (row A's
  url host == row B's custom_host) is invisible to both. Here each claimed host
  is its own row, and `hostname_claims_host_unique_idx` is UNIQUE over `host`
  alone — whichever column the host came from.

  `host` is stored NORMALISED by `Registry.normalize_claim_host/1`, the same
  function the provisioning-FQDN leg of `custom_host_taken?/2` compares with.
  `kind` records which column the claim came from (`"url"` or `"custom_host"`);
  it matters for exactly one thing: a `"url"` claim held by an ABANDONED row
  (see `Registry.provisioning_fqdn_claim/2`) may be taken over by an attach,
  the same carve-out the pre-check already applies. A `"custom_host"` claim is
  never taken over.

  Written only by `Registry` — on barkpark insert (the url host) and on
  `set_custom_host/2` (the custom host), in the same transaction as the
  barkparks write. Released by `on_delete: :delete_all` when the barkpark row
  goes, which is the same statement as the delete.

  SCOPE: barkparks only. Site `domains` are NOT in this table yet; the
  site ↔ custom_host pair is still serialised only by the advisory lock in
  `Registry.hostname_claimed?/2`.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(url custom_host)

  schema "hostname_claims" do
    field :host, :string
    field :kind, :string

    belongs_to :barkpark, BarkparkCloud.Registry.Barkpark

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def kinds, do: @kinds
end
