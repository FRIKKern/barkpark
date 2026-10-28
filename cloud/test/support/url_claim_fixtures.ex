defmodule BarkparkCloud.UrlClaimFixtures do
  @moduledoc """
  Give a test row the url claim that provisioning writes.

  `Registry.reveal_admin_token/1` decrypts only for a row that holds a
  `hostname_claims` row for its url host. Provisioning writes that claim in the
  same transaction as the insert (`Registry.insert_barkpark/2`). Many fixtures
  instead register a bare row and then set `url:` with `Ecto.Changeset.change/2`,
  which writes no claim. Pipe such a fixture through `claim_url_host!/1` to put
  it in the shape a provisioned row has.

  Accepts a `%Barkpark{}` or `{:ok, %Barkpark{}}` and returns the same shape. A
  row with no url, or a host another row already holds, is left unclaimed.
  """

  alias BarkparkCloud.Registry
  alias BarkparkCloud.Registry.{Barkpark, HostnameClaim}
  alias BarkparkCloud.Repo

  @spec claim_url_host!(Barkpark.t() | {:ok, Barkpark.t()}) ::
          Barkpark.t() | {:ok, Barkpark.t()}
  def claim_url_host!({:ok, %Barkpark{} = bp}), do: {:ok, claim_url_host!(bp)}

  def claim_url_host!(%Barkpark{id: id, url: url} = bp) do
    case Registry.hostname_claim_key(url) do
      nil ->
        bp

      host ->
        now = DateTime.utc_now()

        Repo.insert_all(
          HostnameClaim,
          [
            %{
              id: Ecto.UUID.generate(),
              host: host,
              kind: "url",
              barkpark_id: id,
              inserted_at: now,
              updated_at: now
            }
          ],
          on_conflict: :nothing,
          conflict_target: :host
        )

        bp
    end
  end

  def claim_url_host!(other), do: other
end
